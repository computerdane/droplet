//! The on-disk volume format Godot reads (format_version 1):
//! `<root>/<ICAO>_<YYYYMMDD_HHMMSS>/volume.json` + one `sNN_<FIELD>.bin` per sweep/field,
//! each little-endian float16 `[azimuth_bin][gate]`. `write_volume` also adds DVEL
//! (dealiased VEL) next to every VEL sweep and the VAD wind profile / storm motion.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

#[cfg(not(target_arch = "wasm32"))]
use rayon::prelude::*;
use serde::{Deserialize, Serialize};

use crate::grid::Grid;
use crate::level2::{MISSING, RANGE_FOLDED, Volume};
use crate::time::Utc;
use crate::{Error, Result, cells, dealias, fields, hca, products, round_to, vad};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct FieldMeta {
    pub file: String,
    pub n_gates: usize,
    pub first_gate_m: i32,
    pub gate_spacing_m: u32,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct SweepMeta {
    pub index: usize,
    pub elevation_number: u8,
    pub elevation_deg: f64,
    pub azimuth_step_deg: f64,
    pub n_azimuth_bins: usize,
    pub n_radials: usize,
    pub time: String,
    pub nyquist_ms: Option<f64>,
    pub unambiguous_range_km: Option<f64>,
    pub fields: BTreeMap<String, FieldMeta>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct VolumeMeta {
    pub format_version: u32,
    pub icao: String,
    pub time: String,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub height_m: Option<f64>,
    pub vcp: Option<u16>,
    pub complete: bool,
    /// Archive preview awaiting chronological temporal finalization; never a prior.
    #[serde(default, skip_serializing_if = "is_false")]
    pub provisional: bool,
    pub dtype: String,
    pub layout: String,
    pub missing: f64,
    pub range_folded: f64,
    #[serde(default)]
    pub wind_profile: Option<vad::WindProfile>,
    #[serde(default)]
    pub storm_motion: Option<vad::StormMotion>,
    /// Column products (CREF, ET, VIL) on a ground-range grid, see `products`.
    #[serde(default)]
    pub products: Option<products::ProductsMeta>,
    /// Storm cells (see `cells`), strongest first.
    #[serde(default)]
    pub cells: Option<Vec<cells::Cell>>,
    /// Melting layer the hydrometeor classification used (see `hca`).
    #[serde(default)]
    pub melting_layer: Option<hca::MeltingLayer>,
    pub sweeps: Vec<SweepMeta>,
}

/// One sweep's grids by field name.
pub type Fields = BTreeMap<String, Grid>;

/// Grids of every sweep and their metadata, before writing.
pub struct Decoded {
    pub sweeps: Vec<SweepMeta>,
    pub grids: Vec<Fields>,
}

/// Bins each sweep's radials onto the regular azimuth grid: bin `floor(az / step)`, later
/// radials overwriting earlier ones in the same bin, `MISSING` where no radial landed.
pub fn rasterise(vol: &Volume) -> Decoded {
    let mut sweeps = Vec::new();
    let mut grids = Vec::new();
    for (i, radials) in vol.sweeps().iter().enumerate() {
        let step = if radials[0].azimuth_resolution == 1 { 0.5 } else { 1.0 };
        let n_bins = (360.0 / step as f64).round() as usize;
        let mut fields = BTreeMap::new();
        let mut fields_meta = BTreeMap::new();
        let names: std::collections::BTreeSet<&str> = radials.iter().flat_map(|r| r.moments.iter().map(|m| m.name.as_str())).collect();
        for name in names {
            let moments: Vec<_> = radials.iter().filter_map(|r| r.moment(name)).collect();
            let n_gates = moments.iter().map(|m| m.n_gates).max().unwrap_or(0);
            let mut grid = Grid::filled(n_bins, n_gates, MISSING);
            for r in radials {
                if let Some(m) = r.moment(name) {
                    let b = (r.azimuth / step) as usize % n_bins;
                    grid.row_mut(b)[..m.n_gates].copy_from_slice(&m.values[..m.n_gates]);
                }
            }
            fields.insert(name.to_string(), grid);
            fields_meta.insert(
                name.to_string(),
                FieldMeta {
                    file: format!("s{i:02}_{name}.bin"),
                    n_gates,
                    first_gate_m: moments[0].first_gate_m,
                    gate_spacing_m: moments[0].gate_spacing_m,
                },
            );
        }
        let mean_elev = radials.iter().map(|r| r.elevation as f64).sum::<f64>() / radials.len() as f64;
        sweeps.push(SweepMeta {
            index: i,
            elevation_number: radials[0].elevation_number,
            elevation_deg: round_to(mean_elev, 3),
            azimuth_step_deg: step as f64,
            n_azimuth_bins: n_bins,
            n_radials: radials.len(),
            time: radials[0].time.isoformat(),
            nyquist_ms: radials[0].nyquist_ms,
            unambiguous_range_km: radials[0].unambiguous_range_km,
            fields: fields_meta,
        });
        grids.push(fields);
    }
    Decoded { sweeps, grids }
}

/// One tilt of the previous volume's dealiased velocity: a temporal dealiasing reference.
pub struct PriorTilt {
    pub elevation_deg: f64,
    pub first_gate_m: f64,
    pub gate_spacing_m: f64,
    pub dvel: Grid,
}

/// A prior volume is used only if it started at most this long before (VCP 31/32 take 10 min).
pub const PRIOR_MAX_AGE_S: f64 = 900.0;
/// A prior tilt stands in for a tilt within this much elevation.
pub const PRIOR_MAX_ELEVATION_DIFF_DEG: f64 = 0.25;

/// The prior tilt nearest in elevation to `sw`, resampled onto its grid (NaN where it has no data).
fn prior_reference(sw: &dealias::SweepIn, prior: &[PriorTilt]) -> Option<Vec<f64>> {
    let diff = |p: &PriorTilt| (p.elevation_deg - sw.elevation_deg).abs();
    let p = prior.iter().filter(|p| diff(p) <= PRIOR_MAX_ELEVATION_DIFF_DEG).min_by(|a, b| diff(a).total_cmp(&diff(b)))?;
    let pin = dealias::SweepIn {
        vel: &p.dvel,
        nyquist: 0.0,
        elevation_deg: p.elevation_deg,
        first_gate_m: p.first_gate_m,
        gate_spacing_m: p.gate_spacing_m,
    };
    Some(dealias::resample(sw, &pin, &p.dvel))
}

/// Adds a DVEL field (dealiased VEL, same geometry) to every sweep that has VEL. Two passes:
/// the second gives components the tilt below cannot place (isolated echoes, often aloft in
/// strong winds) the fold the first pass's VAD profile predicts, when that is decisive. Before
/// the VAD, such components take the fold of the `prior` volume's DVEL on the same tilt (a few
/// minutes earlier) when that is decisive: far echoes on the lowest tilt, beyond the profile.
pub fn add_dealiased(d: &mut Decoded, prior: &[PriorTilt]) {
    let have: Vec<usize> =
        (0..d.grids.len()).filter(|&i| d.grids[i].contains_key("VEL") && d.sweeps[i].nyquist_ms.is_some_and(|n| n != 0.0)).collect();
    let inputs: Vec<dealias::SweepIn> = have
        .iter()
        .map(|&i| {
            let f = &d.sweeps[i].fields["VEL"];
            dealias::SweepIn {
                vel: &d.grids[i]["VEL"],
                nyquist: d.sweeps[i].nyquist_ms.unwrap(),
                elevation_deg: d.sweeps[i].elevation_deg,
                first_gate_m: f.first_gate_m as f64,
                gate_spacing_m: f.gate_spacing_m as f64,
            }
        })
        .collect();
    let temporal: Vec<Vec<Vec<f64>>> = inputs.iter().map(|s| prior_reference(s, prior).into_iter().collect()).collect();
    let mut out = dealias::dealias_volume_with(&inputs, &temporal);
    let first: Vec<vad::SweepIn> = inputs
        .iter()
        .zip(&out)
        .map(|(s, dvel)| vad::SweepIn {
            dvel,
            vel: Some(s.vel),
            nyquist: s.nyquist,
            elevation_deg: s.elevation_deg,
            first_gate_m: s.first_gate_m,
            gate_spacing_m: s.gate_spacing_m,
        })
        .collect();
    if let Some(profile) = vad::wind_profile(&first) {
        let fallbacks: Vec<Vec<Vec<f64>>> = inputs
            .iter()
            .zip(temporal)
            .map(|(s, mut t)| {
                t.push(vad::radial_reference(&profile, s));
                t
            })
            .collect();
        out = dealias::dealias_volume_with(&inputs, &fallbacks);
    }
    for (&i, dvel) in have.iter().zip(out) {
        let mut meta = d.sweeps[i].fields["VEL"].clone();
        meta.file = format!("s{i:02}_DVEL.bin");
        d.sweeps[i].fields.insert("DVEL".into(), meta);
        d.grids[i].insert("DVEL".into(), dvel);
    }
}

/// The DVEL tilts of a decoded volume's metadata, each read by `read(file)` (float16 bytes), as
/// a prior for the next volume; empty unless the volume is complete.
pub fn prior_tilts(meta: &VolumeMeta, mut read: impl FnMut(&str) -> Option<Vec<u8>>) -> Vec<PriorTilt> {
    if !meta.complete || meta.provisional {
        return Vec::new();
    }
    products::tilts(&meta.sweeps, "DVEL")
        .into_iter()
        .filter_map(|i| {
            let sw = &meta.sweeps[i];
            let f = &sw.fields["DVEL"];
            let dvel = Grid::from_f16_le(sw.n_azimuth_bins, f.n_gates, &read(&f.file)?)?;
            Some(PriorTilt {
                elevation_deg: sw.elevation_deg,
                first_gate_m: f.first_gate_m as f64,
                gate_spacing_m: f.gate_spacing_m as f64,
                dvel,
            })
        })
        .collect()
}

/// Whether a volume of `icao` at `time` takes one of `prior_icao` at `prior_time` as its prior.
pub fn is_prior(icao: &str, time: Utc, prior_icao: &str, prior_time: Utc) -> bool {
    let age = time.secs_since(prior_time);
    icao == prior_icao && age > 0.0 && age <= PRIOR_MAX_AGE_S
}

/// The prior for a volume of `icao` at `time` written under `root`: the latest complete volume
/// of the site that started less than PRIOR_MAX_AGE_S before it (none if there is none).
pub fn find_prior(root: &Path, icao: &str, time: Utc) -> Vec<PriorTilt> {
    find_prior_excluding(root, icao, time, &[])
}

/// Like `find_prior`, but ignores names currently being published as provisional backfill.
pub(crate) fn find_prior_excluding(root: &Path, icao: &str, time: Utc, excluded: &[String]) -> Vec<PriorTilt> {
    let Ok(entries) = std::fs::read_dir(root) else { return Vec::new() };
    let prefix = format!("{icao}_");
    let mut candidates: Vec<_> = entries
        .filter_map(|e| {
            let name = e.ok()?.file_name().into_string().ok()?;
            if excluded.contains(&name) {
                return None;
            }
            let t = Utc::parse_compact(name.strip_prefix(&prefix)?)?;
            is_prior(icao, time, icao, t).then_some((t, name))
        })
        .collect();
    candidates.sort_unstable();
    for (_, name) in candidates.into_iter().rev() {
        let dir = root.join(name);
        match read_meta(&dir) {
            Ok(meta) if meta.provisional => continue,
            Ok(meta) => return prior_tilts(&meta, |file| std::fs::read(dir.join(file)).ok()),
            Err(_) => return Vec::new(),
        }
    }
    Vec::new()
}

/// Adds AZSHR next to every DVEL and KDP next to every PHI that has RHO on the same sweep
/// (see `fields`), with the geometry of the field they come from. Sweeps run in parallel
/// natively.
pub fn add_derived_fields(d: &mut Decoded) {
    let derive = |(sw, g): (&SweepMeta, &Fields)| -> Vec<(String, FieldMeta, Grid)> {
        let mut out = Vec::new();
        if let Some(dvel) = g.get("DVEL") {
            let mut meta = sw.fields["DVEL"].clone();
            let shear = fields::azimuthal_shear(dvel, meta.first_gate_m as f64, meta.gate_spacing_m as f64);
            meta.file = format!("s{:02}_AZSHR.bin", sw.index);
            out.push(("AZSHR".to_string(), meta, shear));
        }
        if let (Some(phi), Some(rho)) = (g.get("PHI"), g.get("RHO")) {
            let mut meta = sw.fields["PHI"].clone();
            let k = fields::kdp(phi, rho, g.get("REF"), meta.gate_spacing_m as f64);
            meta.file = format!("s{:02}_KDP.bin", sw.index);
            out.push(("KDP".to_string(), meta, k));
        }
        out
    };
    #[cfg(not(target_arch = "wasm32"))]
    let results: Vec<_> = d.sweeps.par_iter().zip(d.grids.par_iter()).map(derive).collect();
    #[cfg(target_arch = "wasm32")]
    let results: Vec<_> = d.sweeps.iter().zip(d.grids.iter()).map(derive).collect();
    for ((sw, g), fs) in d.sweeps.iter_mut().zip(d.grids.iter_mut()).zip(results) {
        for (name, meta, grid) in fs {
            sw.fields.insert(name.clone(), meta);
            g.insert(name, grid);
        }
    }
}

/// Adds HCA (hydrometeor class, see `hca`) next to the ZDR of every sweep that has REF, ZDR
/// and RHO, returning the melting layer it used: this volume's bright band if it shows one,
/// else the climatology for the site's latitude (none without a latitude). Run after
/// `add_derived_fields` (it reads KDP).
pub fn add_hca(d: &mut Decoded, latitude: Option<f64>, height_m: Option<f64>, time: Utc) -> Option<hca::MeltingLayer> {
    let have: Vec<usize> = (0..d.grids.len()).filter(|&i| ["REF", "ZDR", "RHO"].iter().all(|n| d.grids[i].contains_key(*n))).collect();
    if have.is_empty() {
        return None;
    }
    let moment = |i: usize, name: &str| {
        let f = &d.sweeps[i].fields.get(name)?;
        Some(hca::Moment { grid: &d.grids[i][name], first_gate_m: f.first_gate_m as f64, gate_spacing_m: f.gate_spacing_m as f64 })
    };
    let inputs: Vec<hca::SweepIn> = have
        .iter()
        .map(|&i| hca::SweepIn {
            elevation_deg: d.sweeps[i].elevation_deg,
            refl: moment(i, "REF").unwrap(),
            zdr: moment(i, "ZDR").unwrap(),
            rho: moment(i, "RHO").unwrap(),
            phi: moment(i, "PHI"),
            kdp: moment(i, "KDP"),
        })
        .collect();
    let ml = hca::detect_melting_layer(&inputs)
        .or_else(|| latitude.map(|lat| hca::climatological_melting_layer(lat, time, height_m.unwrap_or(0.0))))?;
    #[cfg(not(target_arch = "wasm32"))]
    let grids: Vec<Grid> = inputs.par_iter().map(|s| hca::classify(s, &ml)).collect();
    #[cfg(target_arch = "wasm32")]
    let grids: Vec<Grid> = inputs.iter().map(|s| hca::classify(s, &ml)).collect();
    drop(inputs);
    for (&i, grid) in have.iter().zip(grids) {
        let mut meta = d.sweeps[i].fields["ZDR"].clone();
        meta.file = format!("s{i:02}_HCA.bin");
        d.sweeps[i].fields.insert("HCA".into(), meta);
        d.grids[i].insert("HCA".into(), grid);
    }
    Some(ml)
}

/// Storm cells (see `cells`) from the product grids of `volume_products` and the lowest tilt
/// that has REF, RHO and ZDR.
pub fn volume_cells(sweeps: &[SweepMeta], grids: &[Fields], meta: &products::ProductsMeta, prods: &[Grid]) -> Vec<cells::Cell> {
    let get = |name: &str| &prods[products::NAMES.iter().position(|n| *n == name).unwrap()];
    let f = &meta.fields["CREF"];
    let p = cells::ProductGrids {
        cref: get("CREF"),
        echo_top: get("ET"),
        vil: get("VIL"),
        rot: get("ROT"),
        first_gate_m: f.first_gate_m as f64,
        gate_spacing_m: f.gate_spacing_m as f64,
    };
    let dual = products::tilts(sweeps, "RHO").into_iter().find(|&i| ["REF", "ZDR"].iter().all(|n| grids[i].contains_key(*n))).map(|i| {
        let rf = &sweeps[i].fields["REF"];
        cells::DualPol {
            refl: &grids[i]["REF"],
            rho: &grids[i]["RHO"],
            zdr: &grids[i]["ZDR"],
            elevation_deg: sweeps[i].elevation_deg,
            first_gate_m: rf.first_gate_m as f64,
            gate_spacing_m: rf.gate_spacing_m as f64,
        }
    });
    cells::find_cells(&p, dual.as_ref())
}

/// VAD wind profile from every sweep with DVEL (see `vad`).
pub fn wind_profile(sweeps: &[SweepMeta], grids: &[Fields]) -> Option<vad::WindProfile> {
    let inputs: Vec<vad::SweepIn> = sweeps
        .iter()
        .zip(grids)
        .filter_map(|(sw, g)| {
            let dvel = g.get("DVEL")?;
            let f = &sw.fields["DVEL"];
            Some(vad::SweepIn {
                dvel,
                vel: g.get("VEL"),
                nyquist: sw.nyquist_ms.unwrap_or(0.0),
                elevation_deg: sw.elevation_deg,
                first_gate_m: f.first_gate_m as f64,
                gate_spacing_m: f.gate_spacing_m as f64,
            })
        })
        .collect();
    vad::wind_profile(&inputs)
}

pub fn volume_dir_name(icao: &str, time: Utc) -> String {
    format!("{icao}_{}", time.compact())
}

/// A volume in the Godot-facing format, in memory: its metadata and each sweep file's
/// float16 bytes keyed by file name (`sNN_<FIELD>.bin`).
pub struct Encoded {
    pub meta: VolumeMeta,
    pub files: Vec<(String, Vec<u8>)>,
}

/// Rasterises, dealiases and computes VAD winds: everything `write_volume` does short of
/// touching the disk (the wasm build returns this to the browser).
pub fn encode_volume(vol: &Volume) -> Encoded {
    encode_volume_with(vol, &[])
}

/// `encode_volume` with the previous volume's DVEL as a temporal dealiasing reference (see
/// `add_dealiased`, `find_prior`, `Encoded::prior`).
pub fn encode_volume_with(vol: &Volume, prior: &[PriorTilt]) -> Encoded {
    let mut d = rasterise(vol);
    add_dealiased(&mut d, prior);
    add_derived_fields(&mut d);
    let melting_layer = add_hca(&mut d, vol.latitude, vol.height_m, vol.time);
    let profile = wind_profile(&d.sweeps, &d.grids);
    let mut files = Vec::new();
    for (sw, fields) in d.sweeps.iter().zip(&d.grids) {
        for (name, grid) in fields {
            files.push((sw.fields[name].file.clone(), grid.to_f16_le()));
        }
    }
    let prods = products::volume_products(&d.sweeps, &d.grids);
    if let Some((meta, grids)) = &prods {
        for (name, grid) in products::NAMES.iter().zip(grids) {
            files.push((meta.fields[*name].file.clone(), grid.to_f16_le()));
        }
    }
    let cells = prods.as_ref().map(|(m, g)| volume_cells(&d.sweeps, &d.grids, m, g));
    let storm_motion = vad::bunkers(profile.as_ref());
    let meta = VolumeMeta {
        format_version: 1,
        icao: vol.icao.clone(),
        time: vol.time.isoformat(),
        latitude: vol.latitude,
        longitude: vol.longitude,
        height_m: vol.height_m,
        vcp: vol.vcp,
        complete: vol.complete,
        provisional: false,
        dtype: "float16-le".into(),
        layout: "row-major [azimuth_bin][gate]; bin b covers [b*step, (b+1)*step) degrees clockwise from north".into(),
        missing: MISSING as f64,
        range_folded: RANGE_FOLDED as f64,
        wind_profile: profile,
        storm_motion,
        products: prods.map(|(m, _)| m),
        cells,
        melting_layer,
        sweeps: d.sweeps,
    };
    Encoded { meta, files }
}

impl Encoded {
    /// This volume as the prior of the next one (empty unless complete).
    pub fn prior(&self) -> Vec<PriorTilt> {
        prior_tilts(&self.meta, |file| self.file(file).map(<[u8]>::to_vec))
    }

    pub fn file(&self, name: &str) -> Option<&[u8]> {
        self.files.iter().find(|(n, _)| n == name).map(|(_, b)| b.as_slice())
    }

    /// One field of every sweep read back from the files (sweeps without it get none).
    fn grids(&self, names: &[&str]) -> Vec<Fields> {
        self.meta
            .sweeps
            .iter()
            .map(|sw| {
                let mut g = Fields::new();
                for name in names {
                    let grid = sw.fields.get(*name).and_then(|f| Grid::from_f16_le(sw.n_azimuth_bins, f.n_gates, self.file(&f.file)?));
                    if let Some(grid) = grid {
                        g.insert(name.to_string(), grid);
                    }
                }
                g
            })
            .collect()
    }

    fn put(&mut self, name: &str, bytes: Vec<u8>) {
        match self.files.iter_mut().find(|(n, _)| n == name) {
            Some(f) => f.1 = bytes,
            None => self.files.push((name.to_string(), bytes)),
        }
    }

    /// Dealiases this volume again with `prior` as the temporal reference, from its own VEL
    /// files (VEL is exact in float16, so this is what `encode_volume_with` would have given),
    /// for volumes decoded without their predecessor at hand (the browser decodes a range in
    /// parallel). Where DVEL changes, AZSHR, the winds, the products and the cells are computed
    /// again from the files, as `nexrad derive` does. Returns the files that changed (volume.json
    /// aside); none if DVEL came out the same.
    pub fn redealias(&mut self, prior: &[PriorTilt]) -> Vec<String> {
        let mut d = Decoded { sweeps: self.meta.sweeps.clone(), grids: self.grids(&["VEL"]) };
        add_dealiased(&mut d, prior);
        let mut changed = Vec::new();
        for (sw, g) in d.sweeps.iter().zip(&d.grids) {
            if let Some(dvel) = g.get("DVEL") {
                let file = &sw.fields["DVEL"].file;
                let bytes = dvel.to_f16_le();
                if self.file(file) != Some(bytes.as_slice()) {
                    changed.push(file.clone());
                    self.put(file, bytes);
                }
            }
        }
        if changed.is_empty() {
            return changed;
        }
        let mut grids = self.grids(&["VEL", "REF", "RHO", "ZDR"]);
        for (g, new) in grids.iter_mut().zip(d.grids) {
            if let Some(dvel) = new.get("DVEL") {
                g.insert("DVEL".into(), dvel.clone());
            }
        }
        let sweeps = self.meta.sweeps.clone();
        for (sw, g) in sweeps.iter().zip(grids.iter_mut()) {
            if let (Some(dvel), Some(f)) = (g.get("DVEL"), sw.fields.get("AZSHR")) {
                let shear = fields::azimuthal_shear(dvel, f.first_gate_m as f64, f.gate_spacing_m as f64);
                changed.push(f.file.clone());
                self.put(&f.file, shear.to_f16_le());
                g.insert("AZSHR".into(), shear);
            }
        }
        self.meta.wind_profile = wind_profile(&sweeps, &grids);
        self.meta.storm_motion = vad::bunkers(self.meta.wind_profile.as_ref());
        let prods = products::volume_products(&sweeps, &grids);
        if let Some((pm, pg)) = &prods {
            for (name, grid) in products::NAMES.iter().zip(pg) {
                changed.push(pm.fields[*name].file.clone());
                self.put(&pm.fields[*name].file, grid.to_f16_le());
            }
        }
        self.meta.cells = prods.as_ref().map(|(m, g)| volume_cells(&sweeps, &grids, m, g));
        self.meta.products = prods.map(|(m, _)| m);
        changed
    }
}

/// Writes a decoded volume to `<root>/<ICAO>_<time>/` in the Godot-facing layout,
/// returning that directory. The site's previous volume there, if recent, is the temporal
/// dealiasing reference.
pub fn write_volume(vol: &Volume, root: &Path) -> Result<PathBuf> {
    let enc = encode_volume_with(vol, &find_prior(root, &vol.icao, vol.time));
    write_encoded(&enc, root)
}

/// Publishes an already encoded volume, with metadata written last.
pub fn write_encoded(enc: &Encoded, root: &Path) -> Result<PathBuf> {
    let time = Utc::parse_iso(&enc.meta.time)?;
    let out = root.join(volume_dir_name(&enc.meta.icao, time));
    std::fs::create_dir_all(&out).map_err(|e| Error::from(format!("{}: {e}", out.display())))?;
    // A killed preview rewrite must not leave old canonical metadata labeling new files.
    // New directories remain invisible until the final metadata write below.
    if enc.meta.provisional
        && let Ok(mut previous) = read_meta(&out)
    {
        previous.provisional = true;
        write_meta(&out, &previous)?;
    }
    for (name, bytes) in &enc.files {
        write_atomic(&out.join(name), bytes)?;
    }
    write_meta(&out, &enc.meta)?;
    Ok(out)
}

/// Written via a temporary file and rename, so Godot never reads a torn file.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let tmp = path.with_file_name(format!("{}.tmp", path.file_name().and_then(|n| n.to_str()).unwrap_or("file")));
    std::fs::write(&tmp, bytes).and_then(|_| std::fs::rename(&tmp, path)).map_err(|e| Error::from(format!("{}: {e}", path.display())))
}

/// `volume.json` text, exactly as written to disk.
pub fn meta_json(meta: &VolumeMeta) -> Result<String> {
    Ok(serde_json::to_string_pretty(meta)?)
}

fn is_false(value: &bool) -> bool {
    !*value
}

pub fn write_meta(out: &Path, meta: &VolumeMeta) -> Result<()> {
    write_atomic(&out.join("volume.json"), meta_json(meta)?.as_bytes())
}

/// `volume.json` text back to its metadata.
pub fn parse_meta(text: &str) -> Result<VolumeMeta> {
    Ok(serde_json::from_str(text)?)
}

pub fn read_meta(out: &Path) -> Result<VolumeMeta> {
    let path = out.join("volume.json");
    let text = std::fs::read_to_string(&path).map_err(|e| Error::from(format!("{}: {e}", path.display())))?;
    serde_json::from_str(&text).map_err(|e| Error::from(format!("{}: {e}", path.display())))
}

/// Reads one field of one sweep back from its `.bin` file.
pub fn read_field(out: &Path, sw: &SweepMeta, name: &str) -> Result<Option<Grid>> {
    let Some(f) = sw.fields.get(name) else { return Ok(None) };
    let bytes = std::fs::read(out.join(&f.file)).map_err(|e| Error::from(format!("{}: {e}", f.file)))?;
    Grid::from_f16_le(sw.n_azimuth_bins, f.n_gates, &bytes).map(Some).ok_or_else(|| format!("{}: wrong size", f.file).into())
}

/// Recomputes the derived per-gate fields (AZSHR, KDP, HCA), the column products and the cells of an already
/// decoded volume from its REF, DVEL, PHI, RHO and ZDR files. False if it has no REF (no products).
pub fn add_derived(out: &Path) -> Result<bool> {
    let mut meta = read_meta(out)?;
    let mut d = Decoded { sweeps: meta.sweeps.clone(), grids: Vec::new() };
    for sw in &meta.sweeps {
        let mut g = Fields::new();
        for name in ["REF", "DVEL", "PHI", "RHO", "ZDR"] {
            if let Some(grid) = read_field(out, sw, name)? {
                g.insert(name.into(), grid);
            }
        }
        d.grids.push(g);
    }
    add_derived_fields(&mut d);
    let time = crate::time::Utc::parse_iso(&meta.time)?;
    meta.melting_layer = add_hca(&mut d, meta.latitude, meta.height_m, time);
    for (sw, g) in d.sweeps.iter().zip(&d.grids) {
        for name in ["AZSHR", "KDP", "HCA"] {
            if let Some(grid) = g.get(name) {
                write_atomic(&out.join(&sw.fields[name].file), &grid.to_f16_le())?;
            }
        }
    }
    let prods = products::volume_products(&d.sweeps, &d.grids);
    if let Some((pm, pg)) = &prods {
        for (name, grid) in products::NAMES.iter().zip(pg) {
            write_atomic(&out.join(&pm.fields[*name].file), &grid.to_f16_le())?;
        }
    }
    meta.cells = prods.as_ref().map(|(m, g)| volume_cells(&d.sweeps, &d.grids, m, g));
    meta.sweeps = d.sweeps;
    meta.products = prods.map(|(m, _)| m);
    write_meta(out, &meta)?;
    Ok(meta.products.is_some())
}

/// Recomputes `wind_profile` / `storm_motion` of an already decoded volume from its files.
pub fn add_winds(out: &Path) -> Result<Option<vad::StormMotion>> {
    let mut meta = read_meta(out)?;
    let mut grids: Vec<Fields> = Vec::new();
    for sw in &meta.sweeps {
        let mut g = Fields::new();
        for name in ["VEL", "DVEL"] {
            if let Some(grid) = read_field(out, sw, name)? {
                g.insert(name.into(), grid);
            }
        }
        grids.push(g);
    }
    meta.wind_profile = wind_profile(&meta.sweeps, &grids);
    meta.storm_motion = vad::bunkers(meta.wind_profile.as_ref());
    write_meta(out, &meta)?;
    Ok(meta.storm_motion)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::level2::read_volume;
    use crate::synth::{self, Layout};

    #[test]
    fn interrupted_preview_rewrite_cannot_keep_canonical_metadata() {
        let vol = synth::small_volume();
        let mut enc = encode_volume(&vol);
        let root = tempdir::Dir::new("preview-rewrite");
        let out = write_encoded(&enc, root.path()).unwrap();
        assert!(!meta_json(&enc.meta).unwrap().contains("provisional"));
        enc.meta.provisional = true;
        // Failure at the first sweep write, after the existing metadata was marked.
        enc.files.insert(0, ("absent-directory/field.bin".into(), vec![0, 0]));
        assert!(write_encoded(&enc, root.path()).is_err());
        assert!(read_meta(&out).unwrap().provisional);
        assert!(enc.prior().is_empty());
        assert!(find_prior(root.path(), &vol.icao, vol.time.add_secs(300.0)).is_empty());
    }

    #[test]
    fn prior_from_the_previous_volume() {
        // The site's latest complete volume up to PRIOR_MAX_AGE_S earlier is the prior, the same
        // tilts `Encoded::prior` gives in memory; later, older, other sites and partial volumes are not.
        let vol = &synth::fixture_volumes()[0];
        let dir = tempdir::Dir::new("prior");
        let out = write_volume(vol, dir.path()).unwrap();
        let t = vol.time;
        let on_disk = find_prior(dir.path(), "KTST", t.add_secs(300.0));
        let meta = read_meta(&out).unwrap();
        assert_eq!(on_disk.len(), products::tilts(&meta.sweeps, "DVEL").len());
        let in_memory = encode_volume(vol).prior();
        assert_eq!(in_memory.len(), on_disk.len());
        for (a, b) in on_disk.iter().zip(&in_memory) {
            assert_eq!((a.elevation_deg, a.first_gate_m, &a.dvel), (b.elevation_deg, b.first_gate_m, &b.dvel));
        }
        assert!(find_prior(dir.path(), "KTST", t).is_empty(), "itself");
        assert!(find_prior(dir.path(), "KTST", t.add_secs(-60.0)).is_empty(), "a later volume");
        assert!(find_prior(dir.path(), "KTST", t.add_secs(PRIOR_MAX_AGE_S + 1.0)).is_empty(), "too old");
        assert!(find_prior(dir.path(), "KTSU", t.add_secs(300.0)).is_empty(), "another site");
        let mut partial = meta.clone();
        partial.complete = false;
        write_meta(&out, &partial).unwrap();
        assert!(find_prior(dir.path(), "KTST", t.add_secs(300.0)).is_empty(), "partial");
    }

    #[test]
    fn redealias_in_memory_matches_encoding_with_the_prior() {
        // Volume 1 decoded alone, then dealiased again with volume 0 as the prior, must equal
        // volume 1 encoded with that prior. The real prior changes nothing here (the scene
        // dealiases cleanly); one shifted by a whole period on every gate moves the lowest tilt's
        // echo, which has nothing else to go by.
        let vols = synth::fixture_volumes();
        let prior = encode_volume(&vols[0]).prior();
        let mut plain = encode_volume(&vols[1]);
        assert!(plain.redealias(&prior).is_empty(), "a good prior agrees");
        let shifted: Vec<PriorTilt> = prior
            .iter()
            .map(|p| {
                let period = 2.0 * synth::fixture_scene().nyquist_ms as f32;
                let mut dvel = p.dvel.clone();
                dvel.data.iter_mut().filter(|v| **v > -900.0).for_each(|v| *v += period);
                PriorTilt { dvel, ..*p }
            })
            .collect();
        let want = encode_volume_with(&vols[1], &shifted);
        let changed = plain.redealias(&shifted);
        assert!(changed.iter().any(|f| f.ends_with("_DVEL.bin")) && changed.iter().any(|f| f.starts_with("p_")), "{changed:?}");
        for f in &changed {
            assert!(plain.file(f) == want.file(f), "{f} differs");
        }
        assert_eq!(plain.meta.wind_profile, want.meta.wind_profile);
        assert_eq!(plain.meta.storm_motion, want.meta.storm_motion);
        assert_eq!(plain.meta.products, want.meta.products);
    }

    fn written() -> (Volume, tempdir::Dir, PathBuf) {
        let vol = read_volume(&synth::encode_archive(&synth::small_volume(), Layout::Bz2)).unwrap();
        let dir = tempdir::Dir::new("volumes");
        let out = write_volume(&vol, dir.path()).unwrap();
        (vol, dir, out)
    }

    #[test]
    fn layout() {
        let (_vol, _dir, out) = written();
        assert_eq!(out.file_name().unwrap(), "KTST_20240501_220000");
        let meta = read_meta(&out).unwrap();
        assert_eq!(meta.format_version, 1);
        assert_eq!((meta.icao.as_str(), meta.vcp, meta.complete), ("KTST", Some(212), true));
        assert_eq!(meta.time, "2024-05-01T22:00:00+00:00");
        assert_eq!((meta.missing, meta.range_folded, meta.dtype.as_str()), (-1000.0, -2000.0, "float16-le"));
        assert_eq!(meta.sweeps.iter().map(|s| s.index).collect::<Vec<_>>(), [0, 1, 2]);
        assert_eq!(meta.sweeps.iter().map(|s| s.azimuth_step_deg).collect::<Vec<_>>(), [0.5, 0.5, 1.0]);
        assert_eq!(meta.sweeps.iter().map(|s| s.n_azimuth_bins).collect::<Vec<_>>(), [720, 720, 360]);
        assert_eq!(meta.sweeps[1].fields.keys().collect::<Vec<_>>(), ["AZSHR", "DVEL", "REF", "SW", "VEL"]);
        assert_eq!(meta.sweeps[0].fields.keys().collect::<Vec<_>>(), ["HCA", "KDP", "PHI", "REF", "RHO", "ZDR"]);
        let files: std::collections::BTreeSet<String> =
            std::fs::read_dir(&out).unwrap().map(|e| e.unwrap().file_name().into_string().unwrap()).collect();
        assert!(!files.iter().any(|f| f.ends_with(".tmp")));
        let mut expected = std::collections::BTreeSet::from(["volume.json".to_string()]);
        for sw in &meta.sweeps {
            assert!((sw.nyquist_ms.unwrap() - 20.0).abs() < 1e-9);
            for (name, f) in &sw.fields {
                assert_eq!(f.file, format!("s{:02}_{name}.bin", sw.index));
                assert_eq!(std::fs::metadata(out.join(&f.file)).unwrap().len() as usize, sw.n_azimuth_bins * f.n_gates * 2);
                expected.insert(f.file.clone());
            }
            if let (Some(v), Some(dv)) = (sw.fields.get("VEL"), sw.fields.get("DVEL")) {
                assert_eq!((v.n_gates, v.first_gate_m, v.gate_spacing_m), (dv.n_gates, dv.first_gate_m, dv.gate_spacing_m));
            }
        }
        let prods = meta.products.as_ref().expect("column products");
        assert_eq!(prods.fields.keys().collect::<Vec<_>>(), ["CREF", "ET", "ROT", "VIL"]);
        let low = &meta.sweeps[0].fields["REF"];
        for (name, f) in &prods.fields {
            assert_eq!(f.file, format!("p_{name}.bin"));
            assert_eq!((f.n_gates, f.first_gate_m, f.gate_spacing_m), (low.n_gates, low.first_gate_m, low.gate_spacing_m));
            assert_eq!(std::fs::metadata(out.join(&f.file)).unwrap().len() as usize, prods.n_azimuth_bins * f.n_gates * 2);
            expected.insert(f.file.clone());
        }
        assert_eq!(files, expected);
        // The JSON keeps the field order Godot and the docs expect.
        let text = std::fs::read_to_string(out.join("volume.json")).unwrap();
        assert!(text.find("\"format_version\"").unwrap() < text.find("\"icao\"").unwrap());
        assert!(text.find("\"wind_profile\"").unwrap() < text.find("\"sweeps\"").unwrap());
    }

    #[test]
    fn values() {
        // Each radial lands in bin floor(azimuth / step), as float16, sentinels kept exact.
        let (vol, _dir, out) = written();
        let meta = read_meta(&out).unwrap();
        for (sw, radials) in meta.sweeps.iter().zip(vol.sweeps()) {
            let step = sw.azimuth_step_deg as f32;
            for name in sw.fields.keys() {
                if ["DVEL", "AZSHR", "KDP", "HCA"].contains(&name.as_str()) {
                    continue;
                }
                let grid = read_field(&out, sw, name).unwrap().unwrap();
                for r in radials.iter().step_by(37) {
                    let want: Vec<f32> = r.moment(name).unwrap().values.iter().map(|&v| half::f16::from_f32(v).to_f32()).collect();
                    assert_eq!(grid.row((r.azimuth / step) as usize), &want[..], "{} {name} {}", sw.index, r.azimuth);
                }
                assert!(grid.data.iter().all(|&v| v >= -900.0 || v == MISSING || v == RANGE_FOLDED));
            }
        }
    }

    #[test]
    fn dealiased_and_winds() {
        let (_vol, _dir, out) = written();
        let meta = read_meta(&out).unwrap();
        let sw = &meta.sweeps[2];
        let vel = read_field(&out, sw, "VEL").unwrap().unwrap();
        let dvel = read_field(&out, sw, "DVEL").unwrap().unwrap();
        let nyq = sw.nyquist_ms.unwrap() as f32;
        let mut unfolded = false;
        for (&v, &d) in vel.data.iter().zip(&dvel.data) {
            assert_eq!(v < -900.0, d < -900.0);
            if v > -900.0 {
                let folds = (d - v) / (2.0 * nyq);
                assert!((folds - folds.round()).abs() < 0.01, "DVEL = VEL + whole folds");
                unfolded |= d.abs() > nyq;
            }
        }
        assert!(unfolded, "the scene aliases; something was unfolded");
        assert!(meta.wind_profile.is_some());
    }

    #[test]
    fn column_products_of_the_scene() {
        // The full fixture scan (0.5 to 11 degrees), so the storm has a top.
        let dir = tempdir::Dir::new("products");
        let out = write_volume(&synth::fixture_volumes()[0], dir.path()).unwrap();
        let meta = read_meta(&out).unwrap();
        let prods = meta.products.clone().unwrap();
        let as_sweep = SweepMeta {
            index: 0,
            elevation_number: 0,
            elevation_deg: 0.0,
            azimuth_step_deg: prods.azimuth_step_deg,
            n_azimuth_bins: prods.n_azimuth_bins,
            n_radials: 0,
            time: String::new(),
            nyquist_ms: None,
            unambiguous_range_km: None,
            fields: prods.fields.clone(),
        };
        let get = |n: &str| read_field(&out, &as_sweep, n).unwrap().unwrap();
        let (cref, et, vil) = (get("CREF"), get("ET"), get("VIL"));
        // Low-level rotation peaks at the couplet (12.5e-3 /s near the ground, less once smoothed).
        let rot = get("ROT");
        let peak = rot.data.iter().copied().fold(f32::MIN, f32::max);
        assert!((8.0..14.0).contains(&peak), "ROT peak {peak}");
        let low = read_field(&out, &meta.sweeps[products::tilts(&meta.sweeps, "REF")[0]], "REF").unwrap().unwrap();
        // At short range the lowest beam is nearly at the ground point: CREF is at least it.
        let mut stormy = 0;
        for row in 0..720 {
            for g in 0..cref.n_gates {
                let (l, c) = (low.at(row * low.n_az / 720, g), cref.at(row, g));
                if l > -900.0 {
                    assert!(c >= l - 0.1, "row {row} gate {g}: CREF {c} < REF {l}");
                }
                if c >= 45.0 {
                    stormy += 1;
                    assert!(et.at(row, g) > 3.0, "a 45 dBZ column tops out above 3 km");
                    assert!(vil.at(row, g) > 1.0);
                }
                if c < 18.0 {
                    assert_eq!(et.at(row, g), MISSING);
                }
            }
        }
        assert!(stormy > 20, "the scene has a core");
        // Recomputing from the files (`nexrad derive`) gives the same products and fields.
        let derived: Vec<String> = prods
            .fields
            .values()
            .map(|f| f.file.clone())
            .chain(meta.sweeps.iter().flat_map(|s| ["AZSHR", "KDP"].into_iter().filter_map(|n| s.fields.get(n).map(|f| f.file.clone()))))
            .collect();
        assert!(derived.len() > 5);
        let before: Vec<Vec<u8>> = derived.iter().map(|f| std::fs::read(out.join(f)).unwrap()).collect();
        for f in &derived {
            std::fs::remove_file(out.join(f)).unwrap();
        }
        let mut stripped = read_meta(&out).unwrap();
        stripped.products = None;
        stripped.melting_layer = None;
        for s in &mut stripped.sweeps {
            s.fields.retain(|n, _| n != "AZSHR" && n != "KDP" && n != "HCA");
        }
        write_meta(&out, &stripped).unwrap();
        assert!(add_derived(&out).unwrap());
        assert_eq!(read_meta(&out).unwrap(), meta);
        let after: Vec<Vec<u8>> = derived.iter().map(|f| std::fs::read(out.join(f)).unwrap()).collect();
        // DVEL and PHI come back from float16 files, so the fields match to within rounding.
        let f16s = |b: &Vec<u8>| b.chunks(2).map(|c| half::f16::from_le_bytes([c[0], c[1]]).to_f32()).collect::<Vec<f32>>();
        for ((f, b), a) in derived.iter().zip(&before).zip(&after) {
            let worst = f16s(b)
                .iter()
                .zip(f16s(a))
                .map(|(x, y)| if (*x < -900.0) == (y < -900.0) { (x - y).abs() } else { 1e9 })
                .fold(0.0, f32::max);
            assert!(worst < 0.1, "{f}: recomputed values differ by up to {worst}");
        }
    }

    #[test]
    fn derived_fields_of_the_scene() {
        // The fixture storm's rotation couplet and rain core share a centre: find it as the REF
        // maximum of the lowest tilt, then check AZSHR (solid-body rotation of 25 m/s at 2 km,
        // so 12.5e-3 /s shrinking with height) and KDP (the scene's PHI rises 0.05 deg/km per
        // dBZ above 30, so KDP = 0.025 * (REF - 30)) around it.
        let dir = tempdir::Dir::new("derived");
        let out = write_volume(&synth::fixture_volumes()[0], dir.path()).unwrap();
        let meta = read_meta(&out).unwrap();
        let xy = |sw: &SweepMeta, f: &FieldMeta, a: usize, g: usize| {
            let r = (f.first_gate_m as f64 + g as f64 * f.gate_spacing_m as f64) / 1000.0 * sw.elevation_deg.to_radians().cos();
            let az = ((a as f64 + 0.5) * sw.azimuth_step_deg).to_radians();
            (r * az.sin(), r * az.cos())
        };
        let s0 = &meta.sweeps[0];
        let refl = read_field(&out, s0, "REF").unwrap().unwrap();
        let top = (0..refl.data.len()).max_by(|&i, &j| refl.data[i].total_cmp(&refl.data[j])).unwrap();
        let centre = xy(s0, &s0.fields["REF"], top / refl.n_gates, top % refl.n_gates);
        let near = |p: (f64, f64), km: f64| (p.0 - centre.0).hypot(p.1 - centre.1) < km;

        let s1 = &meta.sweeps[1];
        let shear = read_field(&out, s1, "AZSHR").unwrap().unwrap();
        let f = &s1.fields["AZSHR"];
        let (mut peak, mut far) = (f32::MIN, Vec::new());
        for a in 0..shear.n_az {
            for g in 0..shear.n_gates {
                let v = shear.at(a, g);
                if v > -900.0 {
                    let p = xy(s1, f, a, g);
                    if near(p, 2.0) {
                        peak = peak.max(v);
                    } else if !near(p, 6.0) {
                        far.push(v.abs());
                    }
                }
            }
        }
        assert!((8.0..14.0).contains(&peak), "AZSHR peak {peak} at the couplet");
        far.sort_by(f32::total_cmp);
        let p99 = far[far.len() * 99 / 100];
        assert!(p99 < 4.0, "AZSHR away from the couplet (noise, the vortex's 1/r tail): 99th percentile {p99}");

        let k = read_field(&out, s0, "KDP").unwrap().unwrap();
        let mut core: Vec<f32> = Vec::new();
        for a in 0..k.n_az {
            for g in 0..k.n_gates {
                if k.at(a, g) > -900.0 && near(xy(s0, &s0.fields["KDP"], a, g), 2.0) {
                    core.push(k.at(a, g));
                }
            }
        }
        core.sort_by(f32::total_cmp);
        let median = core[core.len() / 2];
        let want = 0.025 * (refl.data[top] - 30.0 - 2.0); // REF's max includes noise
        assert!((median - want).abs() < 0.3, "KDP in the core {median}, want ~{want}");

        // HCA: the scan has no dual-pol tilt high enough for a bright band, so the melting layer
        // is climatological (above the storm's lowest tilts); the core is rain, the debris spot
        // at its centre (RHO ~0.75, ZDR ~0) is not.
        let ml = meta.melting_layer.as_ref().expect("melting layer");
        assert_eq!(ml.source, "climatology");
        assert!((2000.0..3500.0).contains(&ml.top_m), "{ml:?}");
        let h = read_field(&out, s0, "HCA").unwrap().unwrap();
        let (mut rain, mut ring, mut debris) = (0, 0, Vec::new());
        for a in 0..h.n_az {
            for g in 0..h.n_gates {
                let c = h.at(a, g);
                if c < -900.0 {
                    continue;
                }
                let name = hca::CLASSES[c as usize - 1];
                let p = xy(s0, &s0.fields["HCA"], a, g);
                if near(p, 0.7) {
                    debris.push(name);
                } else if near(p, 6.0) && !near(p, 3.0) {
                    ring += 1;
                    rain += ["RA", "HR", "RH", "BD"].contains(&name) as usize;
                }
            }
        }
        assert!(ring > 20 && rain * 10 >= ring * 9, "rain classes on {rain} of {ring} core gates");
        assert!(!debris.is_empty() && debris.iter().all(|c| !["RA", "HR"].contains(c)), "debris classed {debris:?}");
    }

    #[test]
    fn cells_of_the_scene() {
        // The fixture storm is one cell at the couplet, rotating, with debris (low RHO and ZDR)
        // on the lowest tilt; the neighbouring radar's small scan sees the same storm.
        let vols = synth::fixture_volumes();
        let dir = tempdir::Dir::new("cells");
        let out = write_volume(&vols[0], dir.path()).unwrap();
        let meta = read_meta(&out).unwrap();
        let cells = meta.cells.as_ref().expect("cells");
        assert_eq!(cells.len(), 1, "{cells:?}");
        let c = &cells[0];
        assert!(c.max_dbz > 55.0 && c.area_km2 > 50.0 && c.vil > 20.0 && c.top_km > 3.0, "{c:?}");
        assert!(c.rot >= 8.0 && c.tds, "rotation and debris: {c:?}");
        // Its centroid is where the REF core is.
        let s0 = &meta.sweeps[products::tilts(&meta.sweeps, "REF")[0]];
        let refl = read_field(&out, s0, "REF").unwrap().unwrap();
        let top = (0..refl.data.len()).max_by(|&i, &j| refl.data[i].total_cmp(&refl.data[j])).unwrap();
        let az = ((top / refl.n_gates) as f64 + 0.5) * s0.azimuth_step_deg;
        let f = &s0.fields["REF"];
        let r = (f.first_gate_m as f64 + (top % refl.n_gates) as f64 * f.gate_spacing_m as f64) / 1000.0;
        let (x, y) = (r * az.to_radians().sin(), r * az.to_radians().cos());
        assert!((c.x_km - x).hypot(c.y_km - y) < 3.0, "centroid ({}, {}) vs core ({x:.1}, {y:.1})", c.x_km, c.y_km);
    }

    #[test]
    fn add_winds_recomputes() {
        let (_vol, _dir, out) = written();
        let mut meta = read_meta(&out).unwrap();
        let before = (meta.wind_profile.clone(), meta.storm_motion.clone());
        meta.wind_profile = None;
        meta.storm_motion = None;
        write_meta(&out, &meta).unwrap();
        add_winds(&out).unwrap();
        let after = read_meta(&out).unwrap();
        assert_eq!((after.wind_profile, after.storm_motion), before);
    }
}

/// A throwaway directory under the system temp dir, removed on drop (tests only).
#[cfg(test)]
pub mod tempdir {
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};

    static N: AtomicU64 = AtomicU64::new(0);

    pub struct Dir(PathBuf);

    impl Dir {
        pub fn new(tag: &str) -> Dir {
            let n = N.fetch_add(1, Ordering::Relaxed);
            let p = std::env::temp_dir().join(format!("nexrad-test-{}-{tag}-{n}", std::process::id()));
            std::fs::create_dir_all(&p).unwrap();
            Dir(p)
        }
        pub fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}

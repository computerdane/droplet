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
use crate::{Error, Result, dealias, fields, products, round_to, vad};

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

/// Adds a DVEL field (dealiased VEL, same geometry) to every sweep that has VEL.
pub fn add_dealiased(d: &mut Decoded) {
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
    let out = dealias::dealias_volume(&inputs);
    for (&i, dvel) in have.iter().zip(out) {
        let mut meta = d.sweeps[i].fields["VEL"].clone();
        meta.file = format!("s{i:02}_DVEL.bin");
        d.sweeps[i].fields.insert("DVEL".into(), meta);
        d.grids[i].insert("DVEL".into(), dvel);
    }
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
    let mut d = rasterise(vol);
    add_dealiased(&mut d);
    add_derived_fields(&mut d);
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
        dtype: "float16-le".into(),
        layout: "row-major [azimuth_bin][gate]; bin b covers [b*step, (b+1)*step) degrees clockwise from north".into(),
        missing: MISSING as f64,
        range_folded: RANGE_FOLDED as f64,
        wind_profile: profile,
        storm_motion,
        products: prods.map(|(m, _)| m),
        sweeps: d.sweeps,
    };
    Encoded { meta, files }
}

/// Writes a decoded volume to `<root>/<ICAO>_<time>/` in the Godot-facing layout,
/// returning that directory.
pub fn write_volume(vol: &Volume, root: &Path) -> Result<PathBuf> {
    let out = root.join(volume_dir_name(&vol.icao, vol.time));
    std::fs::create_dir_all(&out).map_err(|e| Error::from(format!("{}: {e}", out.display())))?;
    let enc = encode_volume(vol);
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

pub fn write_meta(out: &Path, meta: &VolumeMeta) -> Result<()> {
    write_atomic(&out.join("volume.json"), meta_json(meta)?.as_bytes())
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

/// Recomputes the derived per-gate fields (AZSHR, KDP) and the column products of an already
/// decoded volume from its REF, DVEL, PHI and RHO files. False if it has no REF (no products).
pub fn add_derived(out: &Path) -> Result<bool> {
    let mut meta = read_meta(out)?;
    let mut d = Decoded { sweeps: meta.sweeps.clone(), grids: Vec::new() };
    for sw in &meta.sweeps {
        let mut g = Fields::new();
        for name in ["REF", "DVEL", "PHI", "RHO"] {
            if let Some(grid) = read_field(out, sw, name)? {
                g.insert(name.into(), grid);
            }
        }
        d.grids.push(g);
    }
    add_derived_fields(&mut d);
    for (sw, g) in d.sweeps.iter().zip(&d.grids) {
        for name in ["AZSHR", "KDP"] {
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
        assert_eq!(meta.sweeps[0].fields.keys().collect::<Vec<_>>(), ["KDP", "PHI", "REF", "RHO", "ZDR"]);
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
        assert_eq!(prods.fields.keys().collect::<Vec<_>>(), ["CREF", "ET", "VIL"]);
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
                if ["DVEL", "AZSHR", "KDP"].contains(&name.as_str()) {
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
        for s in &mut stripped.sweeps {
            s.fields.retain(|n, _| n != "AZSHR" && n != "KDP");
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

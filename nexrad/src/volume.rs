//! The on-disk volume format Godot reads (format_version 1):
//! `<root>/<ICAO>_<YYYYMMDD_HHMMSS>/volume.json` + one `sNN_<FIELD>.bin` per sweep/field,
//! each little-endian float16 `[azimuth_bin][gate]`. `write_volume` also adds DVEL
//! (dealiased VEL) next to every VEL sweep and the VAD wind profile / storm motion.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::grid::Grid;
use crate::level2::{MISSING, RANGE_FOLDED, Volume};
use crate::time::Utc;
use crate::{Error, Result, dealias, round_to, vad};

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

/// Writes a decoded volume to `<root>/<ICAO>_<time>/` in the Godot-facing layout,
/// returning that directory.
pub fn write_volume(vol: &Volume, root: &Path) -> Result<PathBuf> {
    let out = root.join(volume_dir_name(&vol.icao, vol.time));
    std::fs::create_dir_all(&out).map_err(|e| Error::from(format!("{}: {e}", out.display())))?;

    let mut d = rasterise(vol);
    add_dealiased(&mut d);
    let profile = wind_profile(&d.sweeps, &d.grids);
    for (sw, fields) in d.sweeps.iter().zip(&d.grids) {
        for (name, grid) in fields {
            write_atomic(&out.join(&sw.fields[name].file), &grid.to_f16_le())?;
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
        sweeps: d.sweeps,
    };
    write_meta(&out, &meta)?;
    Ok(out)
}

/// Written via a temporary file and rename, so Godot never reads a torn file.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let tmp = path.with_file_name(format!("{}.tmp", path.file_name().and_then(|n| n.to_str()).unwrap_or("file")));
    std::fs::write(&tmp, bytes).and_then(|_| std::fs::rename(&tmp, path)).map_err(|e| Error::from(format!("{}: {e}", path.display())))
}

pub fn write_meta(out: &Path, meta: &VolumeMeta) -> Result<()> {
    let text = serde_json::to_string_pretty(meta)?;
    write_atomic(&out.join("volume.json"), text.as_bytes())
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
        assert_eq!(meta.sweeps[1].fields.keys().collect::<Vec<_>>(), ["DVEL", "REF", "SW", "VEL"]);
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
                if name == "DVEL" {
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

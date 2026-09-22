//! Minimal NEXRAD Level II (Archive2, Message 31) decoder.
//!
//! Handles the modern Build 12+ format: a 24-byte volume header followed by
//! bzip2-compressed LDM records containing metadata messages (fixed 2432 bytes) and
//! Message 31 radials (variable size). Older archives (roughly pre-2016, distributed as
//! `.gz`) hold the message stream uncompressed right after the header, gzip-wrapped.
//!
//! Reference: NWS ICD 2620010 (RDA/RPG Interface Control Document).

use std::collections::BTreeMap;
use std::io::Read;

#[cfg(not(target_arch = "wasm32"))]
use rayon::prelude::*;

use crate::time::Utc;
use crate::{Error, Result};

pub const CTM_HEADER_SIZE: usize = 12;
pub const MSG_HEADER_SIZE: usize = 16;
/// CTM + header + 2404 bytes of data for non-31 messages.
pub const FIXED_MSG_SIZE: usize = 2432;
pub const MSG31_OVERFLOW: u16 = 65535;
pub const VOLUME_HEADER_SIZE: usize = 24;

/// Sentinels stored in output arrays (float16-exact).
pub const MISSING: f32 = -1000.0;
pub const RANGE_FOLDED: f32 = -2000.0;

#[derive(Clone, Debug, PartialEq)]
pub struct Moment {
    pub name: String,
    pub n_gates: usize,
    /// Range to the centre of the first gate, metres.
    pub first_gate_m: i32,
    pub gate_spacing_m: u32,
    /// One value per gate, `MISSING` / `RANGE_FOLDED` sentinels.
    pub values: Vec<f32>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Radial {
    pub azimuth: f32,
    pub elevation: f32,
    pub elevation_number: u8,
    /// 1 = 0.5 deg, 2 = 1.0 deg.
    pub azimuth_resolution: u8,
    pub time: Utc,
    pub nyquist_ms: Option<f64>,
    pub unambiguous_range_km: Option<f64>,
    /// In block-pointer order, as the RDA wrote them.
    pub moments: Vec<Moment>,
}

impl Radial {
    pub fn moment(&self, name: &str) -> Option<&Moment> {
        self.moments.iter().find(|m| m.name == name)
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Volume {
    pub icao: String,
    pub time: Utc,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub height_m: Option<f64>,
    pub vcp: Option<u16>,
    pub radials: Vec<Radial>,
    pub complete: bool,
}

impl Volume {
    /// Radials grouped by elevation number, in scan order.
    pub fn sweeps(&self) -> Vec<Vec<&Radial>> {
        let mut groups: BTreeMap<u8, Vec<&Radial>> = BTreeMap::new();
        for r in &self.radials {
            groups.entry(r.elevation_number).or_default().push(r);
        }
        groups.into_values().collect()
    }
}

/// Bounds-checked big-endian field reads; `None` past the end of the buffer.
struct Cur<'a>(&'a [u8]);

impl Cur<'_> {
    fn bytes(&self, at: usize, n: usize) -> Option<&[u8]> {
        self.0.get(at..at.checked_add(n)?)
    }
    fn u8(&self, at: usize) -> Option<u8> {
        self.0.get(at).copied()
    }
    fn u16(&self, at: usize) -> Option<u16> {
        self.bytes(at, 2).map(|b| u16::from_be_bytes([b[0], b[1]]))
    }
    fn i16(&self, at: usize) -> Option<i16> {
        self.u16(at).map(|v| v as i16)
    }
    fn u32(&self, at: usize) -> Option<u32> {
        self.bytes(at, 4).map(|b| u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
    }
    fn i32(&self, at: usize) -> Option<i32> {
        self.u32(at).map(|v| v as i32)
    }
    fn f32(&self, at: usize) -> Option<f32> {
        self.u32(at).map(f32::from_bits)
    }
}

/// Site and scan facts carried by the RVOL block of every radial.
#[derive(Clone, Copy, Debug)]
struct VolInfo {
    latitude: f32,
    longitude: f32,
    height_m: i16,
    vcp: u16,
}

/// The compressed LDM records of an archive (or the single uncompressed stream of the
/// old layout), as slices of `raw` after the volume header.
fn records(raw: &[u8]) -> Vec<&[u8]> {
    if raw.get(28..31) != Some(b"BZh") {
        return vec![&raw[VOLUME_HEADER_SIZE.min(raw.len())..]];
    }
    let cur = Cur(raw);
    let mut out = Vec::new();
    let mut pos = VOLUME_HEADER_SIZE;
    while let Some(size) = cur.i32(pos) {
        pos += 4;
        let size = size.unsigned_abs() as usize;
        if size == 0 {
            break;
        }
        let end = (pos + size).min(raw.len());
        if end == pos {
            break;
        }
        out.push(&raw[pos..end]);
        pos = end;
    }
    out
}

/// Decompresses one bzip2 LDM record. A torn record (as a live chunk in flight might be)
/// yields whatever decompressed cleanly before the error.
fn decompress(rec: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(rec.len() * 8);
    let _ = bzip2::read::BzDecoder::new(rec).read_to_end(&mut out);
    out
}

fn parse_msg31(data: &[u8]) -> Option<(Radial, Option<VolInfo>)> {
    let cur = Cur(data);
    let ms = cur.u32(4)?;
    let jdate = cur.u16(8)?;
    let az = cur.f32(12)?;
    let az_res = cur.u8(20)?;
    let elev_num = cur.u8(22)?;
    let elev = cur.f32(24)?;
    let n_blocks = cur.u16(30)? as usize;
    let mut radial = Radial {
        azimuth: az,
        elevation: elev,
        elevation_number: elev_num,
        azimuth_resolution: az_res,
        time: Utc::from_nexrad(jdate as u32, ms),
        nyquist_ms: None,
        unambiguous_range_km: None,
        moments: Vec::with_capacity(n_blocks),
    };
    let mut info = None;

    for i in 0..n_blocks {
        let p = cur.u32(32 + 4 * i)? as usize;
        if p == 0 || p + 4 > data.len() {
            continue;
        }
        let btype = data[p];
        let name = String::from_utf8_lossy(&data[p + 1..p + 4]).trim().to_string();
        match (btype, name.as_str()) {
            (b'R', "VOL") => {
                if let (Some(lat), Some(lon), Some(h), Some(vcp)) = (cur.f32(p + 8), cur.f32(p + 12), cur.i16(p + 16), cur.u16(p + 40)) {
                    info = Some(VolInfo { latitude: lat, longitude: lon, height_m: h, vcp });
                }
            }
            (b'R', "RAD") => {
                if let (Some(unamb), Some(nyq)) = (cur.u16(p + 6), cur.i16(p + 16)) {
                    radial.unambiguous_range_km = Some(unamb as f64 * 0.1);
                    radial.nyquist_ms = Some(nyq as f64 * 0.01);
                }
            }
            (b'D', _) => {
                let (Some(n_gates), Some(first), Some(spacing), Some(bits), Some(scale), Some(offset)) =
                    (cur.u16(p + 8), cur.i16(p + 10), cur.u16(p + 12), cur.u8(p + 19), cur.f32(p + 20), cur.f32(p + 24))
                else {
                    continue;
                };
                let n_gates = n_gates as usize;
                let word = if bits == 8 { 1 } else { 2 };
                let Some(words) = cur.bytes(p + 28, n_gates * word) else { continue };
                // (raw - offset) / scale in float32, like the numpy original, so float16 output matches.
                let values = if word == 1 {
                    words.iter().map(|&w| scale_word(w as u32, scale, offset)).collect()
                } else {
                    words.as_chunks::<2>().0.iter().map(|w| scale_word(u16::from_be_bytes(*w) as u32, scale, offset)).collect()
                };
                radial.moments.push(Moment { name, n_gates, first_gate_m: first as i32, gate_spacing_m: spacing as u32, values });
            }
            _ => {}
        }
    }
    Some((radial, info))
}

#[inline]
fn scale_word(raw: u32, scale: f32, offset: f32) -> f32 {
    match raw {
        0 => MISSING,
        1 => RANGE_FOLDED,
        _ => (raw as f32 - offset) / scale,
    }
}

/// Every Message 31 radial of one decompressed record, plus the site info if any.
fn parse_record(rec: &[u8]) -> (Vec<Radial>, Option<VolInfo>) {
    let cur = Cur(rec);
    let mut radials = Vec::new();
    let mut info = None;
    let mut pos = 0;
    while pos + CTM_HEADER_SIZE + MSG_HEADER_SIZE <= rec.len() {
        let h = pos + CTM_HEADER_SIZE;
        let (Some(size_hw), Some(mtype), Some(n_seg), Some(seg_num)) = (cur.u16(h), cur.u8(h + 3), cur.u16(h + 12), cur.u16(h + 14)) else {
            break;
        };
        if mtype == 31 {
            let total = if size_hw == MSG31_OVERFLOW { ((n_seg as usize) << 16) | seg_num as usize } else { size_hw as usize * 2 };
            let start = h + MSG_HEADER_SIZE;
            let end = (h + total).min(rec.len());
            if end <= start {
                break;
            }
            match parse_msg31(&rec[start..end]) {
                Some((r, i)) => {
                    radials.push(r);
                    info = info.or(i);
                }
                None => break, // truncated radial at the end of a torn record
            }
            pos = end;
        } else {
            // Fixed-size message, or an empty (type 0) padding slot in the metadata block.
            pos += FIXED_MSG_SIZE;
        }
    }
    (radials, info)
}

/// Decodes an Archive2 file (or the concatenated chunks of one in progress).
pub fn read_volume(raw: &[u8]) -> Result<Volume> {
    let gunzipped;
    let raw = if raw.starts_with(&[0x1f, 0x8b]) {
        let mut out = Vec::with_capacity(raw.len() * 4);
        flate2::read::MultiGzDecoder::new(raw).read_to_end(&mut out).map_err(|e| Error::from(format!("gzip: {e}")))?;
        gunzipped = out;
        &gunzipped[..]
    } else {
        raw
    };
    if !raw.starts_with(b"AR2V00") || raw.len() < VOLUME_HEADER_SIZE {
        return Err("not an Archive2 volume (missing AR2V header)".into());
    }
    let cur = Cur(raw);
    let (vol_date, vol_ms) = (cur.u32(12).unwrap_or(1), cur.u32(16).unwrap_or(0));
    let icao = String::from_utf8_lossy(&raw[20..24]).to_string();
    let mut volume = Volume { icao, time: Utc::from_nexrad(vol_date, vol_ms), complete: true, ..Default::default() };

    let compressed = raw.get(28..31) == Some(b"BZh");
    let parse = |rec: &&[u8]| if compressed { parse_record(&decompress(rec)) } else { parse_record(rec) };
    #[cfg(not(target_arch = "wasm32"))]
    let parsed: Vec<(Vec<Radial>, Option<VolInfo>)> = records(raw).par_iter().map(parse).collect();
    #[cfg(target_arch = "wasm32")]
    let parsed: Vec<(Vec<Radial>, Option<VolInfo>)> = records(raw).iter().map(parse).collect();
    for (radials, info) in parsed {
        if let Some(i) = info {
            volume.latitude = Some(i.latitude as f64);
            volume.longitude = Some(i.longitude as f64);
            volume.height_m = Some(i.height_m as f64);
            volume.vcp = Some(i.vcp);
        }
        volume.radials.extend(radials);
    }
    if volume.radials.is_empty() {
        return Err("no Message 31 radials found".into());
    }
    Ok(volume)
}

pub fn read_file(path: impl AsRef<std::path::Path>) -> Result<Volume> {
    let raw = std::fs::read(path.as_ref()).map_err(|e| Error::from(format!("{}: {e}", path.as_ref().display())))?;
    read_volume(&raw)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::synth::{self, Layout};

    fn assert_same(decoded: &Volume, original: &Volume) {
        assert_eq!(decoded.icao, original.icao);
        assert_eq!(decoded.time, original.time);
        assert!((decoded.latitude.unwrap() - original.latitude.unwrap()).abs() < 1e-5);
        assert!((decoded.longitude.unwrap() - original.longitude.unwrap()).abs() < 1e-5);
        assert_eq!(decoded.height_m, original.height_m);
        assert_eq!(decoded.vcp, original.vcp);
        assert_eq!(decoded.radials.len(), original.radials.len());
        for (d, o) in decoded.radials.iter().zip(&original.radials) {
            assert!((d.azimuth - o.azimuth).abs() < 1e-4);
            assert!((d.elevation - o.elevation).abs() < 1e-4);
            assert_eq!(d.elevation_number, o.elevation_number);
            assert_eq!(d.azimuth_resolution, o.azimuth_resolution);
            assert_eq!(d.time, o.time);
            assert!((d.nyquist_ms.unwrap() - o.nyquist_ms.unwrap()).abs() < 0.005);
            assert!((d.unambiguous_range_km.unwrap() - o.unambiguous_range_km.unwrap()).abs() < 0.05);
            let names = |r: &Radial| r.moments.iter().map(|m| m.name.clone()).collect::<Vec<_>>();
            assert_eq!(names(d), names(o));
            for m in &o.moments {
                let got = d.moment(&m.name).unwrap();
                assert_eq!((got.n_gates, got.first_gate_m, got.gate_spacing_m), (m.n_gates, m.first_gate_m, m.gate_spacing_m));
                let (_, scale, _) = synth::encoding(&m.name);
                let mut any = false;
                for (g, w) in got.values.iter().zip(&m.values) {
                    for sentinel in [MISSING, RANGE_FOLDED] {
                        assert_eq!(*g == sentinel, *w == sentinel);
                    }
                    if *w > -900.0 {
                        any = true;
                        // Within half a quantisation step (plus float32 slack) wherever nothing was clipped.
                        assert!((g - w).abs() <= 0.5 / scale + 1e-4, "{}: {g} vs {w}", m.name);
                    }
                }
                let _ = any;
            }
        }
    }

    #[test]
    fn round_trip_both_layouts() {
        let vol = synth::small_volume();
        for layout in [Layout::Bz2, Layout::Gz] {
            let raw = synth::encode_archive(&vol, layout);
            let magic: &[u8] = if layout == Layout::Gz { &[0x1f, 0x8b, 0x08, 0x00] } else { b"AR2V" };
            assert_eq!(&raw[..4], magic);
            assert_same(&read_volume(&raw).unwrap(), &vol);
        }
    }

    #[test]
    fn sweeps_grouped_in_scan_order() {
        let vol = read_volume(&synth::encode_archive(&synth::small_volume(), Layout::Bz2)).unwrap();
        let sweeps = vol.sweeps();
        assert_eq!(sweeps.iter().map(|s| s[0].elevation_number).collect::<Vec<_>>(), [1, 2, 3]);
        assert_eq!(sweeps.iter().map(|s| s.len()).collect::<Vec<_>>(), [720, 720, 360]);
        fn names(r: &Radial) -> Vec<&str> {
            r.moments.iter().map(|m| m.name.as_str()).collect()
        }
        assert_eq!(names(sweeps[0][0]), ["REF", "ZDR", "PHI", "RHO"]);
        assert_eq!(names(sweeps[1][0]), ["REF", "VEL", "SW"]);
        let vel: Vec<f32> = sweeps[1].iter().flat_map(|r| r.moment("VEL").unwrap().values.clone()).collect();
        assert!(vel.contains(&MISSING) && vel.contains(&RANGE_FOLDED));
    }

    #[test]
    fn partial_archive_decodes_available_radials() {
        // What live() does: decode header + the first records only.
        let vol = synth::small_volume();
        let parts = synth::ldm_records(&synth::encode_archive(&vol, Layout::Bz2));
        let partial = read_volume(&parts[..4].concat()).unwrap(); // header, metadata, 2 radial records
        assert_eq!(partial.radials.len(), 2 * synth::RADIALS_PER_RECORD);
        assert_eq!(partial.vcp, Some(212));
        let err = read_volume(&parts[..2].concat()).unwrap_err().to_string();
        assert!(err.contains("no Message 31"), "{err}");
        // A torn last record still yields everything before the tear.
        let mut torn = parts[..4].concat();
        torn.truncate(torn.len() - 200);
        assert!(read_volume(&torn).unwrap().radials.len() >= synth::RADIALS_PER_RECORD);
    }

    #[test]
    fn garbage_is_rejected() {
        let err = read_volume(b"hello world, definitely not radar data").unwrap_err().to_string();
        assert!(err.contains("AR2V"), "{err}");
        assert!(read_volume(&[0x1f, 0x8b, 1, 2, 3]).is_err());
    }

    #[test]
    fn msg31_overflow_size() {
        // A Message 31 whose halfword size is 65535 carries its byte length in the segment fields.
        let small = synth::small_volume();
        let mut vol = small.clone();
        vol.radials.truncate(2);
        let msgs: Vec<Vec<u8>> = vol.radials.iter().enumerate().map(|(i, r)| synth::msg31(&vol, r, i as u16 + 1)).collect();
        let mut first = msgs[0].clone();
        let total = first.len() - CTM_HEADER_SIZE;
        let c = CTM_HEADER_SIZE;
        first[c..c + 2].copy_from_slice(&MSG31_OVERFLOW.to_be_bytes());
        first[c + 12..c + 14].copy_from_slice(&((total >> 16) as u16).to_be_bytes());
        first[c + 14..c + 16].copy_from_slice(&((total & 0xFFFF) as u16).to_be_bytes());
        let raw = [synth::volume_header(&vol), first, msgs[1].clone()].concat();
        let got = read_volume(&raw).unwrap(); // uncompressed stream, as in the old layout
        assert_eq!(got.radials.len(), 2);
        assert!((got.radials[1].azimuth - vol.radials[1].azimuth).abs() < 1e-5);
    }
}

//! Synthetic NEXRAD data for tests: an Archive2 encoder and a small, deterministic storm scene.
//!
//! `encode_archive()` is the inverse of `level2::read_volume()`: it writes a `Volume` as an
//! Archive2 file in either layout the decoder reads (bzip2 LDM records, or the older
//! gzip-wrapped uncompressed stream), with a metadata record of fixed-size messages in front
//! like the real files. Values are quantised with the usual per-moment scale/offset, so a
//! round trip is exact to within half a quantisation step.
//!
//! `Scene` renders one storm (a reflectivity core with a rotation couplet, drifting with the
//! storm motion) in a veering, strengthening environmental wind, as seen by any radar at any
//! time. Sites share the scene's geometry, so neighbouring radars see the same storm.
//!
//! ```text
//! nexrad synth [out_dir]    # (re)build tests/fixtures/volumes
//! ```

use std::io::Write;
use std::path::{Path, PathBuf};

use crate::level2::{self, CTM_HEADER_SIZE, FIXED_MSG_SIZE, MISSING, MSG_HEADER_SIZE, Moment, RANGE_FOLDED, Radial, Volume};
use crate::time::Utc;
use crate::{Result, vad};

/// Moment encodings as the RDA sends them: (word bits, scale, offset); raw = value * scale + offset.
pub fn encoding(name: &str) -> (u8, f32, f32) {
    match name {
        "REF" => (8, 2.0, 66.0),
        "VEL" => (8, 2.0, 129.0),
        "SW" => (8, 2.0, 129.0),
        "ZDR" => (8, 16.0, 128.0),
        "PHI" => (16, 2.8361, 2.0),
        "RHO" => (8, 300.0, -60.5),
        _ => panic!("no encoding for moment {name}"),
    }
}

pub const RADIALS_PER_RECORD: usize = 120;
pub const KM_PER_DEG: f64 = 111.195;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Layout {
    /// Header + bzip2 LDM records, each prefixed by its signed length (the last one
    /// negative, as some writers do).
    Bz2,
    /// The whole file gzip-wrapped with the message stream uncompressed after the header
    /// (pre-2016 layout).
    Gz,
}

/// Raw gate words for a moment: 0 = below threshold, 1 = range folded. Big-endian for 16-bit.
pub fn quantise(name: &str, values: &[f32]) -> Vec<u8> {
    let (bits, scale, offset) = encoding(name);
    let max = ((1u32 << bits) - 1) as f32;
    let mut out = Vec::with_capacity(values.len() * if bits == 8 { 1 } else { 2 });
    for &v in values {
        let raw = if v == MISSING {
            0
        } else if v == RANGE_FOLDED {
            1
        } else {
            (v * scale + offset).round().clamp(2.0, max) as u32
        };
        if bits == 8 {
            out.push(raw as u8);
        } else {
            out.extend_from_slice(&(raw as u16).to_be_bytes());
        }
    }
    out
}

fn be_u16(v: u16) -> [u8; 2] {
    v.to_be_bytes()
}

/// CTM header + message header + body. Size is in halfwords and excludes the CTM header.
fn message(mtype: u8, mut body: Vec<u8>, t: Utc, seq: u16) -> Vec<u8> {
    if body.len() % 2 == 1 {
        body.push(0);
    }
    let (days, ms) = t.to_nexrad();
    let size_hw = ((MSG_HEADER_SIZE + body.len()) / 2) as u16;
    let mut out = vec![0u8; CTM_HEADER_SIZE];
    out.extend_from_slice(&be_u16(size_hw));
    out.push(8);
    out.push(mtype);
    out.extend_from_slice(&be_u16(seq));
    out.extend_from_slice(&be_u16(days as u16));
    out.extend_from_slice(&ms.to_be_bytes());
    out.extend_from_slice(&be_u16(1));
    out.extend_from_slice(&be_u16(1));
    out.extend_from_slice(&body);
    out
}

/// A metadata message padded to the fixed 2432-byte slot (contents are not decoded).
fn fixed_message(mtype: u8, t: Utc, seq: u16) -> Vec<u8> {
    let mut msg = message(mtype, Vec::new(), t, seq);
    msg.resize(FIXED_MSG_SIZE, 0);
    msg
}

/// One Message 31 (with its headers) for radial `r`.
pub fn msg31(vol: &Volume, r: &Radial, az_num: u16) -> Vec<u8> {
    let f = |v: f32| v.to_be_bytes();
    let mut blocks: Vec<Vec<u8>> = Vec::new();
    let mut rvol = b"RVOL".to_vec();
    rvol.extend_from_slice(&be_u16(44));
    rvol.extend_from_slice(&[1, 0]);
    rvol.extend_from_slice(&f(vol.latitude.unwrap_or(0.0) as f32));
    rvol.extend_from_slice(&f(vol.longitude.unwrap_or(0.0) as f32));
    rvol.extend_from_slice(&(vol.height_m.unwrap_or(0.0) as i16).to_be_bytes());
    rvol.extend_from_slice(&be_u16(10));
    for _ in 0..5 {
        rvol.extend_from_slice(&f(0.0));
    }
    rvol.extend_from_slice(&be_u16(vol.vcp.unwrap_or(0)));
    rvol.extend_from_slice(&be_u16(0));
    blocks.push(rvol);
    let mut relv = b"RELV".to_vec();
    relv.extend_from_slice(&be_u16(12));
    relv.extend_from_slice(&0i16.to_be_bytes());
    relv.extend_from_slice(&f(0.0));
    blocks.push(relv);
    let mut rrad = b"RRAD".to_vec();
    rrad.extend_from_slice(&be_u16(28));
    rrad.extend_from_slice(&be_u16((r.unambiguous_range_km.unwrap_or(0.0) * 10.0).round() as u16));
    rrad.extend_from_slice(&f(0.0));
    rrad.extend_from_slice(&f(0.0));
    rrad.extend_from_slice(&((r.nyquist_ms.unwrap_or(0.0) * 100.0).round() as i16).to_be_bytes());
    rrad.extend_from_slice(&0i16.to_be_bytes());
    rrad.extend_from_slice(&f(0.0));
    rrad.extend_from_slice(&f(0.0));
    blocks.push(rrad);
    for m in &r.moments {
        let (bits, scale, offset) = encoding(&m.name);
        let mut blk = b"D".to_vec();
        blk.extend_from_slice(format!("{:<3}", m.name).as_bytes());
        blk.extend_from_slice(&0u32.to_be_bytes());
        blk.extend_from_slice(&be_u16(m.n_gates as u16));
        blk.extend_from_slice(&(m.first_gate_m as i16).to_be_bytes());
        blk.extend_from_slice(&be_u16(m.gate_spacing_m as u16));
        blk.extend_from_slice(&be_u16(0));
        blk.extend_from_slice(&0i16.to_be_bytes());
        blk.push(0);
        blk.push(bits);
        blk.extend_from_slice(&f(scale));
        blk.extend_from_slice(&f(offset));
        let data = quantise(&m.name, &m.values);
        blk.extend_from_slice(&data);
        if data.len() % 2 == 1 {
            blk.push(0);
        }
        blocks.push(blk);
    }

    let head = 32 + 4 * blocks.len();
    let mut pointers = Vec::with_capacity(blocks.len());
    let mut pos = head;
    for b in &blocks {
        pointers.push(pos as u32);
        pos += b.len();
    }
    let (days, ms) = r.time.to_nexrad();
    let mut body = format!("{:<4}", vol.icao.chars().take(4).collect::<String>()).into_bytes();
    body.extend_from_slice(&ms.to_be_bytes());
    body.extend_from_slice(&be_u16(days as u16));
    body.extend_from_slice(&be_u16(az_num));
    body.extend_from_slice(&f(r.azimuth));
    body.extend_from_slice(&[0, 0]);
    body.extend_from_slice(&be_u16(pos as u16));
    body.push(r.azimuth_resolution);
    body.push(0);
    body.push(r.elevation_number);
    body.push(0);
    body.extend_from_slice(&f(r.elevation));
    body.extend_from_slice(&[0, 0]);
    body.extend_from_slice(&be_u16(blocks.len() as u16));
    for p in pointers {
        body.extend_from_slice(&p.to_be_bytes());
    }
    for b in blocks {
        body.extend_from_slice(&b);
    }
    message(31, body, r.time, az_num)
}

/// Uncompressed LDM record payloads: one metadata record, then radials in batches.
fn records(vol: &Volume) -> Vec<Vec<u8>> {
    let meta: Vec<u8> = [15u8, 13, 18, 3, 5, 2, 0].iter().enumerate().flat_map(|(i, &t)| fixed_message(t, vol.time, i as u16)).collect();
    let mut out = vec![meta];
    for (i, batch) in vol.radials.chunks(RADIALS_PER_RECORD).enumerate() {
        out.push(batch.iter().enumerate().flat_map(|(k, r)| msg31(vol, r, (i * RADIALS_PER_RECORD + k + 1) as u16)).collect());
    }
    out
}

pub fn volume_header(vol: &Volume) -> Vec<u8> {
    let (days, ms) = vol.time.to_nexrad();
    let mut out = b"AR2V0006.001".to_vec();
    out.extend_from_slice(&days.to_be_bytes());
    out.extend_from_slice(&ms.to_be_bytes());
    out.extend_from_slice(format!("{:<4}", vol.icao.chars().take(4).collect::<String>()).as_bytes());
    out
}

/// Archive2 bytes for `vol` in the given layout.
pub fn encode_archive(vol: &Volume, layout: Layout) -> Vec<u8> {
    let records = records(vol);
    match layout {
        Layout::Gz => {
            let mut enc = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
            enc.write_all(&volume_header(vol)).unwrap();
            for r in &records {
                enc.write_all(r).unwrap();
            }
            enc.finish().unwrap()
        }
        Layout::Bz2 => {
            let mut out = volume_header(vol);
            let last = records.len() - 1;
            for (i, rec) in records.iter().enumerate() {
                let mut enc = bzip2::write::BzEncoder::new(Vec::new(), bzip2::Compression::best());
                enc.write_all(rec).unwrap();
                let c = enc.finish().unwrap();
                let len = c.len() as i32;
                out.extend_from_slice(&(if i == last { -len } else { len }).to_be_bytes());
                out.extend_from_slice(&c);
            }
            out
        }
    }
}

/// Splits a bz2-layout archive into `[header, record, record, ...]`, each record with its
/// length prefix, like the chunks bucket serves them (the S chunk = header + first).
pub fn ldm_records(archive: &[u8]) -> Vec<Vec<u8>> {
    let mut out = vec![archive[..24].to_vec()];
    let mut pos = 24;
    while pos + 4 <= archive.len() {
        let size = i32::from_be_bytes([archive[pos], archive[pos + 1], archive[pos + 2], archive[pos + 3]]).unsigned_abs() as usize;
        let end = (pos + 4 + size).min(archive.len());
        out.push(archive[pos..end].to_vec());
        pos = end;
    }
    out
}

// --- deterministic random numbers -----------------------------------------------------------

/// xoshiro256++ seeded through splitmix64: small, fast, identical on every platform.
pub struct Rng([u64; 4]);

impl Rng {
    pub fn seed(seed: u64) -> Rng {
        let mut x = seed;
        let mut next = || {
            x = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut z = x;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            z ^ (z >> 31)
        };
        Rng([next(), next(), next(), next()])
    }

    /// Seed from several words (a scene seed, a time, a site).
    pub fn seed_words(words: &[u64]) -> Rng {
        let mut h = 0xcbf2_9ce4_8422_2325u64;
        for &w in words {
            h ^= w;
            h = h.wrapping_mul(0x0000_0100_0000_01B3);
            h ^= h >> 29;
        }
        Rng::seed(h)
    }

    pub fn next_u64(&mut self) -> u64 {
        let s = &mut self.0;
        let result = s[0].wrapping_add(s[3]).rotate_left(23).wrapping_add(s[0]);
        let t = s[1] << 17;
        s[2] ^= s[0];
        s[3] ^= s[1];
        s[1] ^= s[2];
        s[0] ^= s[3];
        s[2] ^= t;
        s[3] = s[3].rotate_left(45);
        result
    }

    /// Uniform in [0, 1).
    pub fn random(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 * (1.0 / (1u64 << 53) as f64)
    }

    /// Standard normal (Box-Muller).
    pub fn normal(&mut self) -> f64 {
        let u1 = loop {
            let u = self.random();
            if u > 0.0 {
                break u;
            }
        };
        let u2 = self.random();
        (-2.0 * u1.ln()).sqrt() * (2.0 * std::f64::consts::PI * u2).cos()
    }
}

// --- scene ----------------------------------------------------------------------------------

#[derive(Clone, Debug)]
pub struct Site {
    pub icao: &'static str,
    pub latitude: f64,
    pub longitude: f64,
    pub height_m: f64,
}

/// One sweep of the scan: elevation, azimuth step (0.5 or 1.0) and the moments it carries.
#[derive(Clone, Debug)]
pub struct Tilt {
    pub elevation: f64,
    pub step: f64,
    pub moments: &'static [&'static str],
}

pub const DOPPLER: &[&str] = &["REF", "VEL", "SW"];
pub const SURVEILLANCE: &[&str] = &["REF", "ZDR", "PHI", "RHO"];
pub const ALL: &[&str] = &["REF", "VEL", "SW", "ZDR", "PHI", "RHO"];

const fn tilt(elevation: f64, step: f64, moments: &'static [&'static str]) -> Tilt {
    Tilt { elevation, step, moments }
}

/// A cut-down VCP 212: split cut at 0.5 deg, a SAILS repeat of it at the end, batch cuts above.
pub const SCAN: &[Tilt] = &[
    tilt(0.5, 0.5, SURVEILLANCE),
    tilt(0.5, 0.5, DOPPLER),
    tilt(1.5, 1.0, ALL),
    tilt(3.0, 1.0, DOPPLER),
    tilt(5.0, 1.0, DOPPLER),
    tilt(7.5, 1.0, DOPPLER),
    tilt(11.0, 1.0, DOPPLER),
    tilt(0.5, 0.5, DOPPLER),
];

/// A quick scan for tests that do not need the whole VCP: one split cut, one batch tilt.
pub const SMALL_SCAN: &[Tilt] = &[tilt(0.5, 0.5, SURVEILLANCE), tilt(0.5, 0.5, DOPPLER), tilt(1.5, 1.0, ALL)];

/// One supercell-ish storm near `origin` (lat, lon), drifting with `storm_motion` (m/s
/// east, north) from `center_km` (east, north of origin) at `t0`, in a wind veering from
/// 10 m/s southerly at the ground to 30 m/s westerly at 6 km.
#[derive(Clone, Debug)]
pub struct Scene {
    pub origin: (f64, f64),
    pub t0: Utc,
    pub center_km: (f64, f64),
    pub storm_motion: (f64, f64),
    pub core_dbz: f64,
    pub core_radius_km: f64,
    pub couplet_ms: f64,
    pub nyquist_ms: f64,
    /// n, first gate, spacing (m).
    pub ref_gates: (usize, i32, u32),
    pub dop_gates: (usize, i32, u32),
    pub seed: u64,
}

impl Scene {
    pub fn new(origin: (f64, f64), t0: Utc) -> Scene {
        Scene {
            origin,
            t0,
            center_km: (18.0, 14.0),
            storm_motion: (10.0, 6.0),
            core_dbz: 58.0,
            core_radius_km: 7.0,
            couplet_ms: 25.0,
            nyquist_ms: 20.0,
            ref_gates: (48, 1000, 1000),
            dop_gates: (48, 1000, 1000),
            seed: 0,
        }
    }

    /// Environmental wind (u east, v north) at a height above the radar.
    pub fn wind(&self, height_m: f64) -> (f64, f64) {
        let f = (height_m / 6000.0).clamp(0.0, 1.5);
        let spd = 10.0 + 20.0 * f;
        let from = (180.0 + 90.0 * f).to_radians(); // direction the wind blows from
        (-spd * from.sin(), -spd * from.cos())
    }

    pub fn site_offset_km(&self, site: &Site) -> (f64, f64) {
        let (lat0, lon0) = self.origin;
        ((site.longitude - lon0) * KM_PER_DEG * lat0.to_radians().cos(), (site.latitude - lat0) * KM_PER_DEG)
    }

    pub fn volume(&self, site: &Site, time: Utc, scan: &[Tilt]) -> Volume {
        let icao_sum: u64 = site.icao.bytes().map(u64::from).sum();
        let mut rng = Rng::seed_words(&[self.seed, time.0 as u64, icao_sum]);
        let mut vol = Volume {
            icao: site.icao.to_string(),
            time,
            latitude: Some(site.latitude),
            longitude: Some(site.longitude),
            height_m: Some(site.height_m),
            vcp: Some(212),
            radials: Vec::new(),
            complete: true,
        };
        let (ox, oy) = self.site_offset_km(site);
        let elapsed = time.secs_since(self.t0);
        let cx = self.center_km.0 + self.storm_motion.0 * elapsed / 1000.0 - ox;
        let cy = self.center_km.1 + self.storm_motion.1 * elapsed / 1000.0 - oy;
        let mut t = time;
        for (num, tilt) in scan.iter().enumerate() {
            let n_az = (360.0 / tilt.step).round() as usize;
            let az: Vec<f64> = (0..n_az).map(|i| (i as f64 + 0.5) * tilt.step).collect();
            let fields = self.sweep(tilt, &az, cx, cy, &mut rng);
            for i in 0..n_az {
                vol.radials.push(Radial {
                    azimuth: az[i] as f32,
                    elevation: (tilt.elevation + rng.normal() * 0.02) as f32,
                    elevation_number: num as u8 + 1,
                    azimuth_resolution: if tilt.step == 0.5 { 1 } else { 2 },
                    time: t.add_ms((15_000 * i / n_az) as i64),
                    nyquist_ms: Some(self.nyquist_ms),
                    unambiguous_range_km: Some(if tilt.moments == SURVEILLANCE { 466.0 } else { 137.0 }),
                    moments: fields
                        .iter()
                        .map(|(name, values, first, spacing)| Moment {
                            name: name.to_string(),
                            n_gates: values[i].len(),
                            first_gate_m: *first,
                            gate_spacing_m: *spacing,
                            values: values[i].clone(),
                        })
                        .collect(),
                });
            }
            t = t.add_ms(18_000);
        }
        vol
    }

    /// Every moment of one sweep: (name, per-azimuth gate values with sentinels, first, spacing).
    #[allow(clippy::type_complexity)]
    fn sweep(&self, tilt: &Tilt, az_deg: &[f64], cx: f64, cy: f64, rng: &mut Rng) -> Vec<(&'static str, Vec<Vec<f32>>, i32, u32)> {
        let e = tilt.elevation.to_radians();
        let mut out = Vec::new();
        for &name in tilt.moments {
            let (n, first, spacing) = if SURVEILLANCE.contains(&name) { self.ref_gates } else { self.dop_gates };
            let mut rows: Vec<Vec<f32>> = Vec::with_capacity(az_deg.len());
            for &azd in az_deg {
                let az = azd.to_radians();
                let mut row = Vec::with_capacity(n);
                let mut phi = 40.0;
                for g in 0..n {
                    let slant = first as f64 + spacing as f64 * g as f64;
                    let h = vad::beam_height_m(slant, tilt.elevation);
                    let ground = slant * e.cos() / 1000.0;
                    let (x, y) = (ground * az.sin(), ground * az.cos());
                    let d = (x - cx).hypot(y - cy);
                    let core = (-(d / self.core_radius_km).powi(2)).exp() * (1.2 - h / 12000.0).clamp(0.0, 1.0);
                    let ref_dbz = 5.0 + (self.core_dbz - 5.0) * core + 10.0 * (-(d / 25.0).powi(2)).exp() + rng.normal();
                    let precip = ref_dbz > 12.0;
                    let v: f64 = match name {
                        "REF" => {
                            if precip || h < 2500.0 {
                                ref_dbz
                            } else {
                                MISSING as f64
                            }
                        }
                        "VEL" => {
                            let (u, w) = self.wind(h);
                            // Rotation couplet: solid-body inside 2 km of the core centre, 1/r outside.
                            let dd = d.max(1e-6);
                            let vt = self.couplet_ms * if d < 2.0 { d / 2.0 } else { 2.0 / dd } * (-h / 6000.0).exp();
                            let ux = u + vt * -(y - cy) / dd;
                            let uy = w + vt * (x - cx) / dd;
                            let truth = e.cos() * (ux * az.sin() + uy * az.cos()) + rng.normal();
                            let vn = self.nyquist_ms;
                            let mut v = (truth + vn).rem_euclid(2.0 * vn) - vn;
                            if rng.random() < 0.08 {
                                v = MISSING as f64;
                            }
                            // Second-trip echo over a small sector at far range.
                            if tilt.elevation < 1.0 && azd > 300.0 && azd < 315.0 && slant > 35000.0 {
                                v = RANGE_FOLDED as f64;
                            }
                            v
                        }
                        "SW" => {
                            if precip {
                                1.5 + 4.0 * (-(d / 2.0).powi(2)).exp()
                            } else {
                                MISSING as f64
                            }
                        }
                        "ZDR" => {
                            if precip {
                                // Tumbling debris near the ground: ZDR falls to ~0 with RHO.
                                let debris = if tilt.elevation < 2.0 { (-(d / 1.5).powi(2)).exp() } else { 0.0 };
                                let w = (2.0 * debris).min(1.0);
                                (0.2 + (ref_dbz - 20.0) / 12.0).clamp(-1.0, 4.0) * (1.0 - w) + 0.1 * w
                            } else {
                                MISSING as f64
                            }
                        }
                        "RHO" => {
                            let debris = if tilt.elevation < 2.0 { (-(d / 1.5).powi(2)).exp() } else { 0.0 };
                            let noise = rng.normal().abs();
                            if precip { 0.985 - 0.25 * debris - 0.004 * noise } else { MISSING as f64 }
                        }
                        "PHI" => {
                            let rain = (ref_dbz - 30.0).max(0.0) * 0.05;
                            phi += rain * spacing as f64 / 1000.0;
                            if precip { phi } else { MISSING as f64 }
                        }
                        _ => MISSING as f64,
                    };
                    row.push(v as f32);
                }
                rows.push(row);
            }
            out.push((name, rows, first, spacing));
        }
        out
    }
}

// --- fixtures -------------------------------------------------------------------------------

pub const T0: Utc = Utc(1_714_600_800_000); // 2024-05-01T22:00:00Z
pub const FIXTURE_SITES: &[Site] = &[
    Site { icao: "KTST", latitude: 35.3331, longitude: -97.2778, height_m: 370.0 },
    Site { icao: "KTSU", latitude: 35.35, longitude: -96.62, height_m: 330.0 }, // ~60 km east: a mosaic neighbour
];
const NEIGHBOUR_SCAN: &[Tilt] = &[tilt(0.5, 0.5, DOPPLER), tilt(1.5, 1.0, DOPPLER)];
/// (site index, seconds after T0, scan). The neighbour carries two tilts only, to stay small.
pub const FIXTURE_VOLUMES: &[(usize, i64, &[Tilt])] = &[(0, 0, SCAN), (0, 300, SCAN), (1, 130, NEIGHBOUR_SCAN)];

pub fn fixture_scene() -> Scene {
    Scene::new((FIXTURE_SITES[0].latitude, FIXTURE_SITES[0].longitude), T0)
}

/// The test volume most unit tests use: KTST at T0 with the small scan.
pub fn small_volume() -> Volume {
    fixture_scene().volume(&FIXTURE_SITES[0], T0, SMALL_SCAN)
}

/// The decoded volumes behind tests/fixtures/volumes: each one is encoded to Archive2 and
/// decoded again, so the fixtures are exactly what the real pipeline would produce.
pub fn fixture_volumes() -> Vec<Volume> {
    let scene = fixture_scene();
    FIXTURE_VOLUMES
        .iter()
        .enumerate()
        .map(|(i, &(site, secs, scan))| {
            let vol = scene.volume(&FIXTURE_SITES[site], T0.add_secs(secs as f64), scan);
            level2::read_volume(&encode_archive(&vol, if i == 1 { Layout::Gz } else { Layout::Bz2 })).expect("fixture round trip")
        })
        .collect()
}

pub fn build_fixtures(root: &Path) -> Result<Vec<PathBuf>> {
    if root.exists() {
        std::fs::remove_dir_all(root)?;
    }
    std::fs::create_dir_all(root)?;
    fixture_volumes().iter().map(|v| crate::volume::write_volume(v, root)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::grid::Grid;
    use crate::volume::{read_field, read_meta, tempdir};
    use crate::{dealias, vad};

    #[test]
    fn julian_dates_and_quantisation() {
        let t = Utc::from_ymd_hms(2013, 5, 20, 20, 3, 59).add_ms(250);
        let (d, ms) = t.to_nexrad();
        assert_eq!(Utc::from_nexrad(d, ms), t);
        assert_eq!(T0, Utc::from_ymd_hms(2024, 5, 1, 22, 0, 0));
        assert_eq!(quantise("REF", &[MISSING, RANGE_FOLDED, -99.0, 0.0, 200.0]), [0, 1, 2, 66, 255]);
        assert_eq!(quantise("PHI", &[360.0]).len(), 2);
    }

    #[test]
    fn rng_is_deterministic_and_sane() {
        let mut a = Rng::seed_words(&[1, 2, 3]);
        let mut b = Rng::seed_words(&[1, 2, 3]);
        assert_eq!((0..5).map(|_| a.next_u64()).collect::<Vec<_>>(), (0..5).map(|_| b.next_u64()).collect::<Vec<_>>());
        let n = 20000;
        let (mut sum, mut sq) = (0.0, 0.0);
        for _ in 0..n {
            let x = a.normal();
            sum += x;
            sq += x * x;
        }
        let mean = sum / n as f64;
        assert!(mean.abs() < 0.03 && ((sq / n as f64) - 1.0).abs() < 0.05, "{mean} {}", sq / n as f64);
        assert!((0..1000).all(|_| (0.0..1.0).contains(&b.random())));
    }

    fn vel_sweeps(scene: &Scene) -> Vec<(Grid, f64, f64, f64)> {
        let vol = scene.volume(&FIXTURE_SITES[0], T0, SCAN);
        let mut out = Vec::new();
        for radials in vol.sweeps() {
            if let Some(m) = radials[0].moment("VEL") {
                let data: Vec<f32> = radials.iter().flat_map(|r| r.moment("VEL").unwrap().values.clone()).collect();
                let elev = radials.iter().map(|r| r.elevation as f64).sum::<f64>() / radials.len() as f64;
                out.push((Grid::from_vec(radials.len(), m.n_gates, data), elev, m.first_gate_m as f64, m.gate_spacing_m as f64));
            }
        }
        out
    }

    #[test]
    fn dealias_recovers_truth() {
        // Same random draws, but a Nyquist so large that nothing aliases.
        let mut truth_scene = fixture_scene();
        truth_scene.nyquist_ms = 1e4;
        let truth = vel_sweeps(&truth_scene);
        for nyquist in [20.0, 15.0, 12.0] {
            let mut scene = fixture_scene();
            scene.nyquist_ms = nyquist;
            let sweeps = vel_sweeps(&scene);
            let inputs: Vec<dealias::SweepIn> = sweeps
                .iter()
                .map(|(g, e, f, s)| dealias::SweepIn { vel: g, nyquist, elevation_deg: *e, first_gate_m: *f, gate_spacing_m: *s })
                .collect();
            let out = dealias::dealias_volume(&inputs);
            let (mut aliased, mut wrong, mut total) = (0usize, 0usize, 0usize);
            for ((sw, o), t) in sweeps.iter().zip(&out).zip(&truth) {
                for i in 0..sw.0.len() {
                    if sw.0.data[i] > -900.0 {
                        total += 1;
                        aliased += ((sw.0.data[i] - t.0.data[i]).abs() > 1.0) as usize;
                        wrong += ((o.data[i] - t.0.data[i]).abs() > 1.0) as usize;
                    }
                }
            }
            assert!(aliased as f64 / total as f64 > 0.05, "nyquist {nyquist}: the test means something");
            assert!((wrong as f64 / total as f64) < 1e-3, "nyquist {nyquist}: {wrong}/{total} wrong");
        }
    }

    #[test]
    fn vad_matches_scene_wind() {
        // Without the couplet: a vortex is not the uniform wind VAD assumes, and biases it by ~2 m/s.
        let mut scene = fixture_scene();
        scene.couplet_ms = 0.0;
        let mut unaliased = scene.clone();
        unaliased.nyquist_ms = 1e4;
        let sweeps = vel_sweeps(&unaliased);
        let inputs: Vec<vad::SweepIn> = sweeps
            .iter()
            .map(|(g, e, f, s)| vad::SweepIn {
                dvel: g,
                vel: Some(g),
                nyquist: scene.nyquist_ms,
                elevation_deg: *e,
                first_gate_m: *f,
                gate_spacing_m: *s,
            })
            .collect();
        let prof = vad::wind_profile(&inputs).expect("profile");
        let h = &prof.height_m;
        assert!(h[0] <= 1000.0 && h[h.len() - 1] >= 5000.0);
        for (i, &hi) in h.iter().enumerate() {
            let (u, v) = scene.wind(hi);
            let err = (prof.u_ms[i] - u).hypot(prof.v_ms[i] - v);
            assert!(err < 1.0, "{} m: {err}", h[i]);
        }
        assert!(vad::bunkers(Some(&prof)).is_some());
    }

    #[test]
    fn fixture_set() {
        let dir = tempdir::Dir::new("fixtures");
        let root = dir.path().join("volumes");
        let paths = build_fixtures(&root).unwrap();
        let names: Vec<String> = paths.iter().map(|p| p.file_name().unwrap().to_string_lossy().to_string()).collect();
        assert_eq!(names, ["KTST_20240501_220000", "KTST_20240501_220500", "KTSU_20240501_220210"]);

        // Split cut and SAILS repeat.
        let meta = read_meta(&root.join("KTST_20240501_220000")).unwrap();
        let low: Vec<_> = meta.sweeps.iter().filter(|s| (s.elevation_deg - 0.5).abs() < 0.1).collect();
        assert_eq!(low.len(), 3); // surveillance + Doppler cut, and the SAILS repeat at the end
        assert!(!low[0].fields.contains_key("VEL") && low[1].fields.contains_key("VEL") && low[2].fields.contains_key("VEL"));
        assert!(low[2].time > low[1].time);
        let steps: std::collections::BTreeSet<u64> = meta.sweeps.iter().map(|s| (s.azimuth_step_deg * 10.0) as u64).collect();
        assert_eq!(steps.into_iter().collect::<Vec<_>>(), [5, 10]);
        let elevs: std::collections::BTreeSet<i64> = meta.sweeps.iter().map(|s| (s.elevation_deg * 10.0).round() as i64).collect();
        assert_eq!(elevs.len(), 6);

        // Storm and sentinels.
        let out = root.join("KTST_20240501_220000");
        let s = &meta.sweeps[1];
        let ref_ = read_field(&out, s, "REF").unwrap().unwrap();
        let vel = read_field(&out, s, "VEL").unwrap().unwrap();
        assert!(ref_.data.iter().cloned().fold(f32::MIN, f32::max) > 50.0); // the core
        assert!(vel.data.contains(&-1000.0) && vel.data.contains(&-2000.0));
        let top = read_field(&out, &meta.sweeps[6], "REF").unwrap().unwrap();
        assert!(top.data.contains(&-1000.0)); // clear air aloft
        assert_eq!(meta.storm_motion.as_ref().unwrap().method, "bunkers");
        // The neighbour has two tilts and too shallow a profile for Bunkers.
        assert!(read_meta(&root.join("KTSU_20240501_220210")).unwrap().storm_motion.is_none());

        // The storm moves between volumes.
        let core_bin = |name: &str| {
            let out = root.join(name);
            let meta = read_meta(&out).unwrap();
            let g = read_field(&out, &meta.sweeps[1], "REF").unwrap().unwrap();
            (0..g.len()).max_by(|&a, &b| g.data[a].total_cmp(&g.data[b])).unwrap()
        };
        assert_ne!(core_bin("KTST_20240501_220000"), core_bin("KTST_20240501_220500"));

        // Deterministic.
        let again = dir.path().join("again");
        for p in build_fixtures(&again).unwrap() {
            for f in std::fs::read_dir(&p).unwrap() {
                let f = f.unwrap();
                let other = root.join(p.file_name().unwrap()).join(f.file_name());
                assert_eq!(std::fs::read(f.path()).unwrap(), std::fs::read(other).unwrap(), "{}", f.path().display());
            }
        }
    }
}

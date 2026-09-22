//! Real-time NEXRAD Level II via Unidata's chunks bucket.
//!
//! Layout: `unidata-nexrad-level2-chunks/<SITE>/<volume 1..999>/<YYYYMMDD-HHMMSS>-<chunk>-<S|I|E>`.
//! Volume numbers wrap around at 999, and a reused number's directory can still hold the
//! previous cycle's chunks (days old) next to the new ones, so every lookup keys on the
//! newest timestamp prefix in the directory. Each chunk is one or more whole LDM compressed
//! records; the S chunk also carries the 24-byte Archive2 header. Concatenating
//! S + I... + E byte-for-byte yields a normal archive file, so the same decoder works
//! on a partial volume as chunks arrive (typically within ~5-10 s of the sweep).

use crate::Result;
use crate::archive::Bucket;
use crate::level2::{Volume, read_volume};
use crate::time::Utc;
use std::collections::HashSet;
use std::io::Write;

pub const BUCKET: &str = "https://unidata-nexrad-level2-chunks.s3.amazonaws.com";
pub const MAX_VOLUME: u32 = 999;

fn stamp(key: &str) -> &str {
    let name = key.rsplit('/').next().unwrap_or(key);
    &name[..name.len().min(15)]
}

fn parse_stamp(stamp: &str) -> Option<Utc> {
    Utc::parse_compact(stamp)
}

fn chunk_number(key: &str) -> u32 {
    key.rsplit('/').next().unwrap_or(key).split('-').nth(2).and_then(|n| n.parse().ok()).unwrap_or(0)
}

pub fn chunk_time(key: &str) -> Option<Utc> {
    parse_stamp(stamp(key))
}

fn newest_stamp(keys: &[String]) -> Option<&str> {
    keys.iter().map(|k| stamp(k)).max()
}

/// Chunk keys of the newest volume stored under this number, in chunk order.
///
/// Leftover chunks from the previous trip around the ring are dropped. With `newer_than`,
/// returns `[]` unless that newest volume started after it (i.e. the directory only holds
/// leftovers so far).
pub fn list_chunks(bucket: &dyn Bucket, site: &str, volume: u32, newer_than: Option<Utc>) -> Result<Vec<String>> {
    let keys = bucket.list(&format!("{}/{volume}/", site.to_uppercase()))?;
    let Some(newest) = newest_stamp(&keys).map(str::to_string) else { return Ok(Vec::new()) };
    if let (Some(limit), Some(t)) = (newer_than, parse_stamp(&newest))
        && t <= limit
    {
        return Ok(Vec::new());
    }
    let mut keys: Vec<String> = keys.into_iter().filter(|k| stamp(k) == newest).collect();
    keys.sort_by_key(|k| chunk_number(k));
    Ok(keys)
}

/// Start time of the newest volume stored under this number (ignores leftovers).
pub fn volume_time(bucket: &dyn Bucket, site: &str, volume: u32) -> Result<Option<Utc>> {
    let keys = bucket.list(&format!("{}/{volume}/", site.to_uppercase()))?;
    Ok(newest_stamp(&keys).and_then(parse_stamp))
}

pub fn next_volume(volume: u32) -> u32 {
    if volume >= MAX_VOLUME { 1 } else { volume + 1 }
}

/// Locates the newest volume number in the circular 1..999 buffer.
///
/// Times increase with volume number except at one wrap point. Sample coarsely, then
/// binary-search the segment after the newest sample for the last number whose time is
/// still >= the sample's time. ~20 requests total.
pub fn find_latest_volume(bucket: &dyn Bucket, site: &str) -> Result<u32> {
    let step = 100;
    let mut best: Option<(u32, Utc)> = None;
    for n in (1..=MAX_VOLUME).step_by(step as usize) {
        if let Some(t) = volume_time(bucket, site, n)?
            && best.is_none_or(|(_, bt)| t > bt)
        {
            best = Some((n, t));
        }
    }
    let Some((start, base)) = best else { return Err(format!("no chunks found for {site}").into()) };
    let (mut lo, mut hi) = (start, (start + step - 1).min(MAX_VOLUME));
    while lo < hi {
        let mid = (lo + hi).div_ceil(2);
        match volume_time(bucket, site, mid)? {
            Some(t) if t >= base => lo = mid,
            _ => hi = mid - 1,
        }
    }
    Ok(lo)
}

/// Follows `site` on the chunks bucket: starts on the in-progress volume (skipping it if
/// joined after its first chunk), hands the partial volume to `sink` (which stores it and
/// returns its name) each time chunks arrive, marks it complete on the E chunk, then moves on
/// to the next number. `sleep` runs between polls and returns false to stop; `start` skips the
/// ring search (tests).
pub fn live(
    bucket: &dyn Bucket,
    site: &str,
    sink: &mut dyn FnMut(&Volume) -> Result<String>,
    start: Option<u32>,
    mut sleep: impl FnMut() -> bool,
    log: &mut dyn Write,
) -> Result<()> {
    let site = site.to_uppercase();
    let mut volume = match start {
        Some(v) => v,
        None => {
            let _ = writeln!(log, "locating newest {site} volume...");
            find_latest_volume(bucket, &site)?
        }
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut buf: Vec<u8> = Vec::new();
    let mut finished: Option<Utc> = None; // start time of the last volume we completed

    loop {
        let keys = match list_chunks(bucket, &site, volume, finished) {
            Ok(k) => k,
            Err(e) => {
                let _ = writeln!(log, "{site}/{volume}: listing failed: {e}");
                if !sleep() {
                    return Ok(());
                }
                continue;
            }
        };
        let new: Vec<&String> = keys.iter().filter(|k| !seen.contains(*k)).collect();
        if !new.is_empty() {
            let last = keys.last().unwrap();
            let ends = last.ends_with("-E");
            if buf.is_empty() && !new[0].ends_with("-S") {
                // Joined mid-volume: skip to the next one rather than decode a headerless buffer.
                let _ = writeln!(log, "{site}/{volume}: mid-volume, waiting for next");
                seen.extend(keys.iter().cloned());
                if ends {
                    finished = chunk_time(last);
                    volume = next_volume(volume);
                    seen.clear();
                }
                if !sleep() {
                    return Ok(());
                }
                continue;
            }
            let mut fetched_all = true;
            for k in new {
                match bucket.get(k) {
                    Ok(bytes) => {
                        buf.extend_from_slice(&bytes);
                        seen.insert(k.clone());
                    }
                    Err(e) => {
                        let _ = writeln!(log, "{site}/{volume}: {k}: {e}");
                        fetched_all = false;
                        break;
                    }
                }
            }
            match read_volume(&buf) {
                Ok(mut vol) => {
                    vol.complete = ends && fetched_all;
                    match sink(&vol) {
                        Ok(name) => {
                            let _ = writeln!(
                                log,
                                "{name}: {} sweeps ({} chunks){}",
                                vol.sweeps().len(),
                                seen.len(),
                                if vol.complete { " complete" } else { "" }
                            );
                        }
                        Err(e) => {
                            let _ = writeln!(log, "{site}/{volume}: write failed: {e}");
                        }
                    }
                }
                // e.g. only the metadata chunk has arrived so far, or a torn chunk
                Err(e) => {
                    let _ = writeln!(log, "{site}/{volume}: {e}");
                }
            }
            if ends && fetched_all {
                finished = chunk_time(last);
                volume = next_volume(volume);
                seen.clear();
                buf.clear();
                continue;
            }
        }
        if !sleep() {
            return Ok(());
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::rc::Rc;

    use super::*;
    use crate::archive::fakes::FakeBucket;
    use crate::synth::{self, Layout};

    /// A `live` sink writing to `dir`, as the CLI does.
    fn write_to(dir: &std::path::Path) -> impl FnMut(&Volume) -> Result<String> + '_ {
        move |v| Ok(crate::volume::write_volume(v, dir)?.file_name().unwrap().to_string_lossy().into_owned())
    }

    #[test]
    fn list_chunks_drops_leftovers_and_sorts_numerically() {
        let new: Vec<String> =
            [1, 2, 10, 9].iter().map(|n| format!("KTST/5/20240501-220000-{n:03}-{}", if *n == 1 { "S" } else { "I" })).collect();
        let old = ["KTST/5/20240425-101500-001-S".to_string(), "KTST/5/20240425-101500-044-E".to_string()];
        let all: Vec<String> = old.iter().chain(&new).cloned().collect();
        let b = FakeBucket { lister: Some(Box::new(move |_| all.clone())), ..Default::default() };
        let got = list_chunks(&b, "ktst", 5, None).unwrap();
        assert_eq!(got.iter().map(|k| chunk_number(k)).collect::<Vec<_>>(), [1, 2, 9, 10]);
        assert_eq!(list_chunks(&b, "KTST", 5, Some(Utc::from_ymd_hms(2024, 5, 1, 21, 55, 0))).unwrap(), got);
        assert!(list_chunks(&b, "KTST", 5, Some(Utc::from_ymd_hms(2024, 5, 1, 22, 0, 0))).unwrap().is_empty());
        let empty = FakeBucket { lister: Some(Box::new(|_| Vec::new())), ..Default::default() };
        assert!(list_chunks(&empty, "KTST", 5, None).unwrap().is_empty());
    }

    #[test]
    fn times_and_ring_wrap() {
        assert_eq!(chunk_time("KTST/5/20240501-220013-003-I"), Some(Utc::from_ymd_hms(2024, 5, 1, 22, 0, 13)));
        assert_eq!(next_volume(998), 999);
        assert_eq!(next_volume(999), 1);
    }

    #[test]
    fn finds_latest_volume() {
        // Numbers after `newest` hold the previous trip around the ring (older), or nothing yet.
        let base = Utc::from_ymd_hms(2024, 5, 1, 22, 0, 0);
        for newest in [1u32, 57, 437, 999] {
            for full in [true, false] {
                let b = FakeBucket {
                    lister: Some(Box::new(move |prefix: &str| {
                        let n: u32 = prefix.split('/').nth(1).unwrap().parse().unwrap();
                        if !full && n > newest {
                            return Vec::new();
                        }
                        let age = (newest + MAX_VOLUME - n) % MAX_VOLUME; // volumes back in time from the newest
                        let t = base.add_secs(-300.0 * age as f64);
                        vec![format!("KTST/{n}/{}-001-S", t.stamp())]
                    })),
                    ..Default::default()
                };
                assert_eq!(find_latest_volume(&b, "KTST").unwrap(), newest, "newest={newest} full={full}");
                assert!(b.listed.borrow().len() <= 20);
            }
        }
    }

    #[test]
    fn live_follows_a_growing_volume() {
        let vol = synth::small_volume();
        let parts = synth::ldm_records(&synth::encode_archive(&vol, Layout::Bz2));
        let mut payloads = vec![[parts[0].clone(), parts[1].clone()].concat()]; // S = header + metadata record
        payloads.extend(parts[2..].iter().cloned());
        let stamp = vol.time.stamp();
        let n = payloads.len();
        let keys: Vec<String> = (0..n)
            .map(|i| {
                format!(
                    "KTST/7/{stamp}-{:03}-{}",
                    i + 1,
                    if i == 0 {
                        "S"
                    } else if i == n - 1 {
                        "E"
                    } else {
                        "I"
                    }
                )
            })
            .collect();
        let visible = Rc::new(Cell::new(1usize));
        let polls = Rc::new(Cell::new(0usize));
        let b = FakeBucket {
            lister: Some(Box::new({
                let keys = keys.clone();
                let visible = visible.clone();
                move |prefix: &str| {
                    if prefix == "KTST/7/" {
                        let mut v = vec!["KTST/7/20240420-000000-001-S".to_string()]; // plus leftovers
                        v.extend(keys[..visible.get()].iter().cloned());
                        v
                    } else {
                        Vec::new()
                    }
                }
            })),
            ..Default::default()
        };
        for (k, p) in keys.iter().zip(payloads) {
            b.objects.borrow_mut().insert(k.clone(), p);
        }
        let dir = crate::volume::tempdir::Dir::new("live");
        let mut log = Vec::new();
        let sleep = || {
            polls.set(polls.get() + 1);
            visible.set((visible.get() + 3).min(n));
            polls.get() <= 12
        };
        live(&b, "ktst", &mut write_to(dir.path()), Some(7), sleep, &mut log).unwrap();
        let log = String::from_utf8(log).unwrap();
        let name = format!("KTST_{}", vol.time.compact());
        let writes: Vec<&str> = log.lines().filter(|l| l.starts_with(&name)).collect();
        assert!(writes.len() >= 3, "{log}");
        assert!(!writes[0].ends_with("complete") && writes.last().unwrap().ends_with("complete"), "{log}");
        let meta = crate::volume::read_meta(&dir.path().join(&name)).unwrap();
        assert!(meta.complete);
        assert_eq!(meta.sweeps.len(), 3);
        for e in std::fs::read_dir(dir.path().join(&name)).unwrap() {
            assert!(!e.unwrap().file_name().to_string_lossy().ends_with(".tmp"));
        }
    }

    #[test]
    fn live_skips_a_volume_joined_mid_way() {
        let keys = vec!["KTST/7/20240501-220000-004-I".to_string(), "KTST/7/20240501-220000-005-E".to_string()];
        let b = FakeBucket {
            lister: Some(Box::new(move |prefix: &str| if prefix == "KTST/7/" { keys.clone() } else { Vec::new() })),
            ..Default::default()
        };
        let dir = crate::volume::tempdir::Dir::new("live-mid");
        let mut log = Vec::new();
        let mut polls = 0;
        live(
            &b,
            "KTST",
            &mut write_to(dir.path()),
            Some(7),
            || {
                polls += 1;
                polls <= 2
            },
            &mut log,
        )
        .unwrap();
        assert!(String::from_utf8(log).unwrap().contains("mid-volume"));
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
    }
}

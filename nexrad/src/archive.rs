//! The archive mirror (Unidata's `unidata-nexrad-level2` bucket, ~5 min behind real time,
//! back to ~2008): keys are `YYYY/MM/DD/SITE/SITEYYYYMMDD_HHMMSS_V06[.gz]`, one per volume.

use std::path::{Path, PathBuf};

use crate::time::{Date, Utc};
use crate::{Error, Result};

pub const BUCKET: &str = "https://unidata-nexrad-level2.s3.amazonaws.com";

/// An S3 bucket with anonymous listing and reads (`net::HttpBucket`, or a fake in tests).
pub trait Bucket {
    /// Keys under `prefix`, as the bucket lists them (at most one page of 1000).
    fn list(&self, prefix: &str) -> Result<Vec<String>>;
    fn get(&self, key: &str) -> Result<Vec<u8>>;
}

/// `<Key>` elements of an S3 ListObjectsV2 response.
pub fn parse_listing(xml: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = xml;
    while let Some(i) = rest.find("<Key>") {
        rest = &rest[i + 5..];
        let Some(j) = rest.find("</Key>") else { break };
        let key = rest[..j].replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'");
        if !key.is_empty() {
            out.push(key);
        }
        rest = &rest[j + 6..];
    }
    out
}

/// Scan start time from an archive key's `SITEYYYYMMDD_HHMMSS` file name, if it has one.
pub fn key_time(key: &str) -> Option<Utc> {
    let name = key.rsplit('/').next().unwrap_or(key).as_bytes();
    // Four upper-case letters, eight digits, '_', six digits, anywhere in the name.
    for start in 0..name.len().saturating_sub(18) {
        let w = &name[start..start + 19];
        if w[..4].iter().all(u8::is_ascii_uppercase)
            && w[12] == b'_'
            && let Some(t) = Utc::parse_compact(std::str::from_utf8(&w[4..]).ok()?)
        {
            return Some(t);
        }
    }
    None
}

pub fn file_name(key: &str) -> &str {
    key.rsplit('/').next().unwrap_or(key)
}

/// Volume keys of one site and day, sorted. `_MDM` files are metadata-only stubs; skipped.
pub fn list_keys(bucket: &dyn Bucket, site: &str, day: Date) -> Result<Vec<String>> {
    let prefix = format!("{}/{}/", day.slashed(), site.to_uppercase());
    let mut keys: Vec<String> = bucket.list(&prefix)?.into_iter().filter(|k| !k.ends_with("_MDM") && key_time(k).is_some()).collect();
    keys.sort();
    Ok(keys)
}

pub fn latest_key(bucket: &dyn Bucket, site: &str) -> Result<String> {
    let today = Utc::now().date();
    for day in [today, today.add_days(-1)] {
        if let Some(k) = list_keys(bucket, site, day)?.pop() {
            return Ok(k);
        }
    }
    Err(format!("no volumes found for {site} in the last two days").into())
}

/// Newest key whose scan start is at or before `at`.
pub fn key_at(bucket: &dyn Bucket, site: &str, at: Utc) -> Result<String> {
    for day in [at.date(), at.date().add_days(-1)] {
        if let Some(k) = list_keys(bucket, site, day)?.into_iter().rfind(|k| key_time(k).unwrap() <= at) {
            return Ok(k);
        }
    }
    Err(format!("no volumes for {site} at or before {}", at.isoformat()).into())
}

pub fn keys_between(bucket: &dyn Bucket, site: &str, start: Utc, end: Utc) -> Result<Vec<String>> {
    let mut out = Vec::new();
    let mut day = start.date();
    while day <= end.date() {
        out.extend(list_keys(bucket, site, day)?.into_iter().filter(|k| {
            let t = key_time(k).unwrap();
            start <= t && t <= end
        }));
        day = day.add_days(1);
    }
    Ok(out)
}

/// Volumes to backfill before following live chunks: enough to give history without a slow
/// startup (`nexrad live`, `nexrad-wasm::live`).
pub const BACKFILL_COUNT: usize = 11; // newest plus latest-1 through latest-10

/// The most recent `n` complete archive volumes for `site`, oldest first. The archive mirror
/// only ever holds finished uploads, so this never returns an in-progress scan (unlike the
/// chunks bucket). Volumes run every 4-10 min, so `n` usually needs only today's keys; scans
/// back a further week at most (VCPs with long clear-air volumes, or just after midnight UTC).
pub fn recent_keys(bucket: &dyn Bucket, site: &str, n: usize) -> Result<Vec<String>> {
    let mut day = Utc::now().date();
    let mut keys: Vec<String> = Vec::new();
    for _ in 0..8 {
        let mut day_keys = list_keys(bucket, site, day)?;
        day_keys.extend(keys);
        keys = day_keys;
        if keys.len() >= n {
            break;
        }
        day = day.add_days(-1);
    }
    if keys.is_empty() {
        return Err(format!("no volumes found for {site} in the last 8 days").into());
    }
    let start = keys.len().saturating_sub(n);
    Ok(keys[start..].to_vec())
}

/// Which keys a fetch/update asks for.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Selection {
    pub at: Option<Utc>,
    pub start: Option<Utc>,
    pub end: Option<Utc>,
}

pub fn resolve_keys(bucket: &dyn Bucket, site: &str, sel: &Selection) -> Result<Vec<String>> {
    match (sel.start, sel.end, sel.at) {
        (Some(s), Some(e), _) => keys_between(bucket, site, s, e),
        (None, None, Some(at)) => Ok(vec![key_at(bucket, site, at)?]),
        (None, None, None) => Ok(vec![latest_key(bucket, site)?]),
        _ => Err("--from and --to must be given together".into()),
    }
}

/// Downloads `key` into `raw_dir` (skipped if already there); returns the local path.
pub fn download(bucket: &dyn Bucket, key: &str, raw_dir: &Path, log: &mut dyn std::io::Write) -> Result<PathBuf> {
    let dest = raw_dir.join(file_name(key));
    std::fs::create_dir_all(raw_dir).map_err(|e| Error::from(format!("{}: {e}", raw_dir.display())))?;
    if dest.exists() {
        let _ = writeln!(log, "already have {}", file_name(key));
        return Ok(dest);
    }
    let _ = writeln!(log, "downloading {key}");
    let bytes = bucket.get(key)?;
    crate::volume::write_atomic(&dest, &bytes)?;
    Ok(dest)
}

/// The newest successfully finalized complete volume, used to seed live following.
pub struct BackfillSeed {
    pub name: String,
    pub time: Utc,
    pub prior: Vec<crate::volume::PriorTilt>,
}

/// Publish recent scans newest first, then replace them with chronological temporal solutions.
/// `keys` must be oldest first. Only raw file paths and one complete prior are retained; final
/// decoding never reads provisional volumes as priors. Failed scans are logged and skipped.
pub fn backfill(
    bucket: &dyn Bucket,
    keys: &[String],
    raw_dir: &Path,
    volumes_dir: &Path,
    mut emit: impl FnMut(&Path),
    log: &mut dyn std::io::Write,
) -> Option<BackfillSeed> {
    use crate::{level2, volume};
    let mut downloaded = Vec::new();
    let mut excluded: Vec<String> =
        keys.iter().filter_map(|key| Some(volume::volume_dir_name(file_name(key).get(..4)?, key_time(key)?))).collect();
    for (i, key) in keys.iter().rev().enumerate() {
        let _ = writeln!(log, "[{}/{}] {}", i + 1, keys.len(), file_name(key));
        let result = (|| -> Result<()> {
            let raw = download(bucket, key, raw_dir, log)?;
            let vol = level2::read_file(&raw)?;
            excluded.push(volume::volume_dir_name(&vol.icao, vol.time));
            let mut enc = volume::encode_volume(&vol);
            enc.meta.provisional = true;
            let path = volume::write_encoded(&enc, volumes_dir)?;
            emit(&path);
            downloaded.push(raw);
            Ok(())
        })();
        if let Err(e) = result {
            let _ = writeln!(log, "backfill {}: {e}", file_name(key));
        }
    }
    let mut prior = Vec::new();
    let mut previous: Option<(String, Utc)> = None;
    let mut newest = None;
    for raw in downloaded.iter().rev() {
        let result = (|| -> Result<()> {
            let vol = level2::read_file(raw)?;
            let valid = previous.as_ref().is_some_and(|(site, time)| volume::is_prior(&vol.icao, vol.time, site, *time));
            // Preserve update's starting reference on populated roots. Selected names may
            // still be provisional after failures and must never supply this reference.
            let initial =
                if previous.is_none() { volume::find_prior_excluding(volumes_dir, &vol.icao, vol.time, &excluded) } else { Vec::new() };
            let enc = volume::encode_volume_with(&vol, if valid { &prior } else { &initial });
            let path = volume::write_encoded(&enc, volumes_dir)?;
            emit(&path);
            if vol.complete {
                prior = enc.prior();
                previous = Some((vol.icao.clone(), vol.time));
                newest = Some(volume::volume_dir_name(&vol.icao, vol.time));
            }
            Ok(())
        })();
        if let Err(e) = result {
            let _ = writeln!(log, "backfill finalize {}: {e}", raw.display());
        }
    }
    newest.zip(previous).map(|(name, (_, time))| BackfillSeed { name, time, prior })
}

#[cfg(test)]
pub mod fakes {
    //! Stand-ins for the S3 HTTP layer.
    use std::cell::RefCell;
    use std::collections::HashMap;

    use super::*;

    pub fn s3_listing(keys: &[&str]) -> String {
        let items: String = keys.iter().map(|k| format!("<Contents><Key>{k}</Key><Size>1</Size></Contents>")).collect();
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Name>bucket</Name>{items}</ListBucketResult>"
        )
    }

    pub type Lister = Box<dyn Fn(&str) -> Vec<String>>;

    /// Keys by prefix and objects by key, plus a log of every prefix listed.
    #[derive(Default)]
    pub struct FakeBucket {
        pub keys: RefCell<HashMap<String, Vec<String>>>,
        pub objects: RefCell<HashMap<String, Vec<u8>>>,
        pub listed: RefCell<Vec<String>>,
        /// Called with the prefix instead of `keys` when set.
        pub lister: Option<Lister>,
    }

    impl FakeBucket {
        pub fn put_day(&self, day: &str, names: &[&str]) {
            let prefix = format!("{day}/KTST/");
            self.keys.borrow_mut().insert(prefix.clone(), names.iter().map(|n| format!("{prefix}{n}")).collect());
        }
    }

    impl Bucket for FakeBucket {
        fn list(&self, prefix: &str) -> Result<Vec<String>> {
            self.listed.borrow_mut().push(prefix.to_string());
            if let Some(f) = &self.lister {
                return Ok(f(prefix));
            }
            Ok(parse_listing(&s3_listing(
                &self.keys.borrow().get(prefix).map(|v| v.iter().map(String::as_str).collect::<Vec<_>>()).unwrap_or_default(),
            )))
        }
        fn get(&self, key: &str) -> Result<Vec<u8>> {
            self.objects.borrow().get(key).cloned().ok_or_else(|| format!("{key}: not in the fake bucket").into())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fakes::*;
    use super::*;

    #[test]
    fn backfill_publishes_newest_first_then_matches_chronological_decode() {
        use crate::{level2, synth, volume};
        let dir = volume::tempdir::Dir::new("backfill");
        let raw = dir.path().join("raw");
        let out = dir.path().join("volumes");
        let expected = dir.path().join("expected");
        let bucket = FakeBucket::default();
        let vols = synth::fixture_volumes();
        let keys: Vec<String> = vols[..2].iter().map(|v| format!("{}{}_V06", v.icao, v.time.compact())).collect();
        for (key, vol) in keys.iter().zip(&vols) {
            let bytes = synth::encode_archive(vol, synth::Layout::Bz2);
            volume::write_volume(&level2::read_volume(&bytes).unwrap(), &expected).unwrap();
            bucket.objects.borrow_mut().insert(key.clone(), bytes);
        }
        // A missing scan does not stop later scans or become a temporal reference.
        let selected = vec![keys[0].clone(), "missing".into(), keys[1].clone()];
        let mut emitted = Vec::new();
        let newest = backfill(
            &bucket,
            &selected,
            &raw,
            &out,
            |p| emitted.push(p.file_name().unwrap().to_string_lossy().into_owned()),
            &mut Vec::new(),
        );
        let names: Vec<String> = vols[..2].iter().map(|v| volume::volume_dir_name(&v.icao, v.time)).collect();
        assert_eq!(emitted, [names[1].clone(), names[0].clone(), names[0].clone(), names[1].clone()]);
        let seed = newest.unwrap();
        assert_eq!(seed.name, names[1]);
        assert_eq!(seed.time, vols[1].time);
        assert!(!seed.prior.is_empty());
        for name in &names {
            for entry in std::fs::read_dir(expected.join(name)).unwrap() {
                let entry = entry.unwrap();
                assert_eq!(std::fs::read(entry.path()).unwrap(), std::fs::read(out.join(name).join(entry.file_name())).unwrap());
            }
        }
        // If a cached raw scan disappears between phases, its provisional disk output must
        // not seed live following. Keep the newest successfully finalized complete scan.
        let seed = backfill(
            &bucket,
            &keys,
            &raw,
            &out,
            |path| {
                if path.file_name().unwrap().to_string_lossy() == names[1] {
                    std::fs::remove_file(raw.join(file_name(&keys[1]))).unwrap();
                }
            },
            &mut Vec::new(),
        )
        .unwrap();
        assert_eq!(seed.name, names[0]);
        assert_eq!(seed.time, vols[0].time);
        assert!(volume::read_meta(&out.join(&names[1])).unwrap().provisional);
        assert!(!volume::read_meta(&out.join(&names[0])).unwrap().provisional);
    }

    #[test]
    fn backfill_preserves_external_prior_and_excludes_failed_selected_scans() {
        use crate::{level2, synth, volume};
        let dir = volume::tempdir::Dir::new("backfill-prior");
        let raw = dir.path().join("raw");
        let out = dir.path().join("volumes");
        let expected = dir.path().join("expected");
        let vols = synth::fixture_volumes();
        let mut external = volume::encode_volume(&vols[0]);
        external.meta.time = vols[0].time.add_secs(-300.0).isoformat();
        let period = 2.0 * synth::fixture_scene().nyquist_ms as f32;
        for (name, bytes) in &mut external.files {
            if name.ends_with("_DVEL.bin") {
                for gate in bytes.as_chunks_mut::<2>().0 {
                    let value = half::f16::from_le_bytes([gate[0], gate[1]]).to_f32();
                    if value > -900.0 {
                        gate.copy_from_slice(&half::f16::from_f32(value + period).to_le_bytes());
                    }
                }
            }
        }
        volume::write_encoded(&external, &out).unwrap();
        volume::write_encoded(&external, &expected).unwrap();
        let bucket = FakeBucket::default();
        let keys: Vec<String> = vols[..2].iter().map(|v| format!("{}{}_V06", v.icao, v.time.compact())).collect();
        for (key, vol) in keys.iter().zip(&vols) {
            let bytes = synth::encode_archive(vol, synth::Layout::Bz2);
            volume::write_volume(&level2::read_volume(&bytes).unwrap(), &expected).unwrap();
            bucket.objects.borrow_mut().insert(key.clone(), bytes);
        }
        backfill(&bucket, &keys, &raw, &out, |_| {}, &mut Vec::new()).unwrap();
        let names: Vec<String> = vols[..2].iter().map(|v| volume::volume_dir_name(&v.icao, v.time)).collect();
        let plain = volume::encode_volume(&vols[0]);
        assert!(
            plain.files.iter().any(|(file, bytes)| {
                file.ends_with("_DVEL.bin") && *bytes != std::fs::read(expected.join(&names[0]).join(file)).unwrap()
            }),
            "the external reference must change the solution"
        );
        for name in &names {
            for entry in std::fs::read_dir(expected.join(name)).unwrap() {
                let entry = entry.unwrap();
                assert_eq!(std::fs::read(entry.path()).unwrap(), std::fs::read(out.join(name).join(entry.file_name())).unwrap());
            }
        }
        // Make the first selected scan fail finalization. The second must skip its provisional
        // disk version and still use the external reference within the 15-minute window.
        backfill(
            &bucket,
            &keys,
            &raw,
            &out,
            |path| {
                if path.file_name().unwrap().to_string_lossy() == names[0] {
                    std::fs::remove_file(raw.join(file_name(&keys[0]))).unwrap();
                }
            },
            &mut Vec::new(),
        )
        .unwrap();
        let second = level2::read_volume(&bucket.objects.borrow()[&keys[1]]).unwrap();
        let want = volume::encode_volume_with(&second, &external.prior());
        for (file, bytes) in want.files {
            assert_eq!(bytes, std::fs::read(out.join(&names[1]).join(file)).unwrap());
        }
        assert_eq!(volume::read_meta(&out.join(&names[1])).unwrap(), want.meta);
        assert!(volume::read_meta(&out.join(&names[0])).unwrap().provisional);
        // Abrupt cancellation after phase-one publication still leaves a durable marker.
        let interrupted = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            backfill(&bucket, &keys, &raw, &out, |_| panic!("simulate process termination"), &mut Vec::new())
        }));
        assert!(interrupted.is_err());
        assert!(volume::read_meta(&out.join(&names[1])).unwrap().provisional);
        // Both selected outputs are now provisional, so a subsequent live write must find
        // the older external scan rather than either canceled/failed archive output.
        let live_prior = volume::find_prior(&out, &vols[1].icao, vols[1].time.add_secs(60.0));
        let external_prior = external.prior();
        assert_eq!(live_prior.len(), external_prior.len());
        for (actual, expected) in live_prior.iter().zip(&external_prior) {
            assert_eq!(actual.dvel.to_f16_le(), expected.dvel.to_f16_le());
        }
    }

    #[test]
    fn key_times() {
        assert_eq!(key_time("2013/05/20/KTLX/KTLX20130520_200359_V06.gz"), Some(Utc::from_ymd_hms(2013, 5, 20, 20, 3, 59)));
        assert_eq!(key_time("2013/05/20/KTLX/NOP3_20130520"), None);
        assert_eq!(key_time("junk"), None);
        assert_eq!(parse_listing(&s3_listing(&["a/b", "c&amp;d"])), ["a/b", "c&d"]);
    }

    #[test]
    fn list_keys_filters_and_sorts() {
        let b = FakeBucket::default();
        b.put_day("2024/05/01", &["KTST20240501_220500_V06", "KTST20240501_220000_V06", "KTST20240501_220000_V06_MDM", "junk"]);
        let keys = list_keys(&b, "ktst", Date::new(2024, 5, 1)).unwrap();
        assert_eq!(keys, ["2024/05/01/KTST/KTST20240501_220000_V06", "2024/05/01/KTST/KTST20240501_220500_V06"]);
        assert_eq!(b.listed.borrow()[0], "2024/05/01/KTST/");
    }

    #[test]
    fn key_at_and_between() {
        let b = FakeBucket::default();
        b.put_day("2024/04/30", &["KTST20240430_235500_V06"]);
        b.put_day("2024/05/01", &["KTST20240501_000400_V06", "KTST20240501_001000_V06"]);
        let at = key_at(&b, "KTST", Utc::from_ymd_hms(2024, 5, 1, 0, 2, 0)).unwrap();
        assert!(at.ends_with("KTST20240430_235500_V06")); // falls back to the previous day
        assert!(key_at(&b, "KTST", Utc::from_ymd_hms(2024, 5, 1, 0, 5, 0)).unwrap().ends_with("000400_V06"));
        assert!(key_at(&b, "KTST", Utc::from_ymd_hms(2024, 4, 30, 12, 0, 0)).is_err());
        let between = keys_between(&b, "KTST", Utc::from_ymd_hms(2024, 4, 30, 23, 0, 0), Utc::from_ymd_hms(2024, 5, 1, 0, 5, 0)).unwrap();
        assert_eq!(between.iter().map(|k| file_name(k)).collect::<Vec<_>>(), ["KTST20240430_235500_V06", "KTST20240501_000400_V06"]);
        let sel = Selection { start: Some(Utc(0)), ..Default::default() };
        assert!(resolve_keys(&b, "KTST", &sel).unwrap_err().to_string().contains("--from and --to"));
        let sel = Selection { at: Some(Utc::from_ymd_hms(2024, 5, 1, 0, 5, 0)), ..Default::default() };
        assert_eq!(resolve_keys(&b, "KTST", &sel).unwrap().len(), 1);
    }

    #[test]
    fn recent_keys_spans_days_oldest_first() {
        let b = FakeBucket::default();
        let today = Utc::now().date();
        let yesterday = today.add_days(-1);
        b.put_day(&yesterday.slashed(), &["KTST20240430_235500_V06", "KTST20240430_235900_V06"]);
        b.put_day(&today.slashed(), &["KTST20240501_000400_V06"]);
        let keys = recent_keys(&b, "ktst", 3).unwrap();
        assert_eq!(
            keys.iter().map(|k| file_name(k)).collect::<Vec<_>>(),
            ["KTST20240430_235500_V06", "KTST20240430_235900_V06", "KTST20240501_000400_V06"]
        );
        // Fewer volumes exist than asked for: returns what it found, still oldest first.
        assert_eq!(recent_keys(&b, "ktst", 10).unwrap().len(), 3);
        // More volumes exist than asked for: keeps only the newest n.
        let newest_only = recent_keys(&b, "ktst", 1).unwrap();
        assert_eq!(file_name(&newest_only[0]), "KTST20240501_000400_V06");
    }

    #[test]
    fn recent_keys_errors_when_nothing_found() {
        let b = FakeBucket::default();
        assert!(recent_keys(&b, "KTST", 5).unwrap_err().to_string().contains("no volumes"));
    }

    #[test]
    fn download_caches() {
        let b = FakeBucket::default();
        b.objects.borrow_mut().insert("2024/05/01/KTST/KTST20240501_000400_V06".into(), vec![1, 2, 3]);
        let dir = crate::volume::tempdir::Dir::new("raw");
        let mut log = Vec::new();
        let p = download(&b, "2024/05/01/KTST/KTST20240501_000400_V06", dir.path(), &mut log).unwrap();
        assert_eq!(std::fs::read(&p).unwrap(), [1, 2, 3]);
        download(&b, "2024/05/01/KTST/KTST20240501_000400_V06", dir.path(), &mut log).unwrap();
        let log = String::from_utf8(log).unwrap();
        assert!(log.starts_with("downloading ") && log.contains("already have KTST20240501_000400_V06"));
    }
}

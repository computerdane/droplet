//! Disk quota for `data/`: deletes the oldest decoded volumes and raw archive files once a
//! directory holds more than its budget. Age comes from the time in the names
//! (`<ICAO>_<YYYYMMDD_HHMMSS>` directories, `<ICAO><YYYYMMDD_HHMMSS>_V06[.gz]` files), so a volume
//! from 2013 fetched today still goes before yesterday's. The newest entry of each site is
//! never deleted, so a live view or a just-fetched case survives a tight budget.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::Result;

/// Budget for everything under `data/` in bytes, from `$DROPLET_QUOTA_GB` (default 20 GB).
pub fn quota_bytes() -> u64 {
    let gb = std::env::var("DROPLET_QUOTA_GB").ok().and_then(|v| v.parse::<f64>().ok()).unwrap_or(20.0);
    (gb.max(0.0) * 1e9) as u64
}

/// Share of the quota for decoded volumes; the rest is for raw files (a raw file is ~10 MB
/// against ~90 MB decoded).
pub const VOLUMES_SHARE: f64 = 0.85;

/// (site, time key) of a volume directory or raw file name, or None for anything else.
fn site_and_time(name: &str) -> Option<(String, String)> {
    let digits = |s: &str| s.len() == 15 && s.as_bytes()[8] == b'_' && s.bytes().enumerate().all(|(i, b)| i == 8 || b.is_ascii_digit());
    if let Some((site, time)) = name.split_once('_')
        && site.len() == 4
        && digits(time)
    {
        return Some((site.to_string(), time.to_string()));
    }
    let (site, rest) = name.split_at_checked(4)?;
    let time = rest.get(..15)?;
    (digits(time) && rest[15..].starts_with("_V")).then(|| (site.to_string(), time.to_string()))
}

fn size_of(path: &Path) -> u64 {
    match std::fs::metadata(path) {
        Ok(m) if m.is_dir() => std::fs::read_dir(path).map(|d| d.filter_map(|e| e.ok()).map(|e| size_of(&e.path())).sum()).unwrap_or(0),
        Ok(m) => m.len(),
        Err(_) => 0,
    }
}

/// Deletes the oldest entries of `dir` until it holds at most `budget` bytes, keeping each
/// site's newest. Returns the deleted paths and the bytes freed.
pub fn prune_dir(dir: &Path, budget: u64) -> Result<(Vec<PathBuf>, u64)> {
    let Ok(read) = std::fs::read_dir(dir) else { return Ok((Vec::new(), 0)) };
    let mut entries: Vec<(String, String, PathBuf, u64)> = Vec::new();
    let mut total = 0u64;
    for e in read.filter_map(|e| e.ok()) {
        let path = e.path();
        let size = size_of(&path);
        total += size;
        let name = e.file_name().to_string_lossy().to_string();
        if let Some((site, time)) = site_and_time(&name) {
            entries.push((time, site, path, size));
        }
    }
    if total <= budget {
        return Ok((Vec::new(), 0));
    }
    let mut newest: HashMap<String, String> = HashMap::new();
    for (time, site, _, _) in &entries {
        let t = newest.entry(site.clone()).or_default();
        if time > t {
            *t = time.clone();
        }
    }
    entries.sort();
    let (mut deleted, mut freed) = (Vec::new(), 0u64);
    for (time, site, path, size) in entries {
        if total - freed <= budget {
            break;
        }
        if newest.get(&site) == Some(&time) {
            continue;
        }
        let gone = if path.is_dir() { std::fs::remove_dir_all(&path) } else { std::fs::remove_file(&path) };
        if gone.is_ok() {
            freed += size;
            deleted.push(path);
        }
    }
    Ok((deleted, freed))
}

/// Applies the quota to `data/volumes` and `data/raw` under `data`. Returns a one-line
/// summary if anything was deleted (without volume names, which the fetch panel would take
/// for new volumes).
pub fn prune_data(data: &Path, quota: u64) -> Result<Option<String>> {
    let volumes_budget = (quota as f64 * VOLUMES_SHARE) as u64;
    let (vols, vol_bytes) = prune_dir(&data.join("volumes"), volumes_budget)?;
    let (raws, raw_bytes) = prune_dir(&data.join("raw"), quota - volumes_budget)?;
    if vols.is_empty() && raws.is_empty() {
        return Ok(None);
    }
    Ok(Some(format!(
        "quota {:.1} GB: removed {} oldest volumes and {} raw files ({:.2} GB)",
        quota as f64 / 1e9,
        vols.len(),
        raws.len(),
        (vol_bytes + raw_bytes) as f64 / 1e9
    )))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        assert_eq!(site_and_time("KTLX_20130520_200359"), Some(("KTLX".into(), "20130520_200359".into())));
        assert_eq!(site_and_time("KTLX20130520_200359_V06.gz"), Some(("KTLX".into(), "20130520_200359".into())));
        assert_eq!(site_and_time("KTLX20260922_180402_V06"), Some(("KTLX".into(), "20260922_180402".into())));
        assert_eq!(site_and_time("basemap"), None);
        assert_eq!(site_and_time("live_ring.json"), None);
        assert_eq!(site_and_time("KTLX_2013"), None);
    }

    #[test]
    fn prunes_oldest_but_keeps_each_sites_newest() {
        let dir = crate::volume::tempdir::Dir::new("prune");
        let mk = |name: &str, bytes: usize| {
            let d = dir.path().join(name);
            std::fs::create_dir_all(&d).unwrap();
            std::fs::write(d.join("s00_REF.bin"), vec![0u8; bytes]).unwrap();
        };
        mk("KTLX_20130520_200359", 100); // oldest, but not the newest KTLX
        mk("KTLX_20240501_220000", 100);
        mk("KFDR_20100101_000000", 100); // KFDR's only volume: kept however old
        mk("KTLX_20260922_180402", 100);
        std::fs::create_dir_all(dir.path().join("other")).unwrap(); // not ours: counted, kept
        let (deleted, freed) = prune_dir(dir.path(), 250).unwrap();
        let names: Vec<String> = deleted.iter().map(|p| p.file_name().unwrap().to_string_lossy().to_string()).collect();
        assert_eq!(names, ["KTLX_20130520_200359", "KTLX_20240501_220000"]);
        assert_eq!(freed, 200);
        assert!(dir.path().join("KFDR_20100101_000000").exists() && dir.path().join("KTLX_20260922_180402").exists());
        // Under budget: nothing to do.
        assert!(prune_dir(dir.path(), 1000).unwrap().0.is_empty());
    }
}

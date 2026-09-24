//! Disk quota for `data/`: once a directory holds more than its budget, deletes decoded volumes
//! and raw archive files oldest first. Age comes from the time in the names
//! (`<ICAO>_<YYYYMMDD_HHMMSS>` directories, `<ICAO><YYYYMMDD_HHMMSS>_V06[.gz]` files), so a volume
//! from 2013 fetched today still goes before yesterday's.
//!
//! Two kinds of entry are never deleted:
//! - scans inside a protected time [`Window`] (the app's current window from `data/window.json`,
//!   `nexrad prune --keep-from/--keep-to`, or the range `nexrad update` just fetched), so a
//!   historical event fetched into a site that also has newer scans survives (#37);
//! - the newest entry of each site, with or without a window, so a live view or a just-fetched
//!   case survives a tight budget even while the window file is missing, stale or lagging behind
//!   the live clock. It costs one volume per cached site.
//!
//! When the protected entries alone exceed the budget they are all kept and the summary says the
//! quota is exceeded; prune never deletes inside the window to make room.
//!
//! `data/window.json` (written atomically by the app whenever its window changes):
//!
//! ```json
//! {"from": "2013-05-20T19:30:00Z", "to": "2013-05-20T20:45:00Z", "live": false, "written": "2026-09-23T12:00:00Z"}
//! ```
//!
//! - `from`, `to`: ISO 8601 UTC (anything [`Utc::parse_iso`] accepts), `from <= to`, inclusive.
//! - `live` (optional, default false): a live window rolls with the clock. The app writes
//!   `from = now - span`, `to = now`; prune protects `[now - (to - from), open end]`, so it keeps
//!   protecting the newest scans without the app rewriting the file every scan.
//! - `written`: when the app wrote it. The file is ignored when `written` is missing or more than
//!   [`WINDOW_MAX_AGE_MS`] away from now (left behind by a crash), and when it is unreadable or
//!   invalid; prune then falls back to the rule without a window.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::Result;
use crate::time::Utc;

/// Budget for everything under `data/` in bytes, from `$DROPLET_QUOTA_GB` (default 20 GB).
pub fn quota_bytes() -> u64 {
    let gb = std::env::var("DROPLET_QUOTA_GB").ok().and_then(|v| v.parse::<f64>().ok()).unwrap_or(20.0);
    (gb.max(0.0) * 1e9) as u64
}

/// Share of the quota for decoded volumes; the rest is for raw files (a raw file is ~10 MB
/// against ~90 MB decoded).
pub const VOLUMES_SHARE: f64 = 0.85;

/// Name of the app's window file under `data/`.
pub const WINDOW_FILE: &str = "window.json";

/// A window file whose `written` is further than this from now is stale and ignored (1 day).
pub const WINDOW_MAX_AGE_MS: i64 = 86_400_000;

/// A protected scan-time range, inclusive at both ends.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Window {
    pub from: Utc,
    pub to: Utc,
}

impl Window {
    /// An open end for a live window (no scan is later).
    pub const OPEN: Utc = Utc(i64::MAX);

    pub fn contains(&self, t: Utc) -> bool {
        self.from <= t && t <= self.to
    }

    /// The window of `data/window.json` text at `now`, or None if it is invalid or stale
    /// (see the module docs for the format).
    pub fn parse_file(text: &str, now: Utc) -> Option<Window> {
        let doc: serde_json::Value = serde_json::from_str(text).ok()?;
        let time = |key: &str| doc.get(key)?.as_str().and_then(|s| Utc::parse_iso(s).ok());
        let (from, to, written) = (time("from")?, time("to")?, time("written")?);
        let live = match doc.get("live") {
            None | Some(serde_json::Value::Null) => false,
            Some(v) => v.as_bool()?,
        };
        if from > to || (now.0 - written.0).abs() > WINDOW_MAX_AGE_MS {
            return None;
        }
        Some(if live { Window { from: now.add_ms(-(to.0 - from.0)), to: Window::OPEN } } else { Window { from, to } })
    }

    /// The window of `<data>/window.json` at `now`, or None if absent, invalid or stale.
    pub fn read_file(data: &Path, now: Utc) -> Option<Window> {
        Window::parse_file(&std::fs::read_to_string(data.join(WINDOW_FILE)).ok()?, now)
    }
}

/// What [`prune_dir`] did.
#[derive(Debug, Default)]
pub struct Pruned {
    /// Deleted paths, oldest first.
    pub deleted: Vec<PathBuf>,
    pub freed: u64,
    /// Bytes still held; more than the budget when protected entries alone exceed it.
    pub remaining: u64,
}

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

/// Scan time of a volume directory or raw file name (`KTLX_20130520_200359`,
/// `KTLX20130520_200359_V06.gz`), or None for anything else.
pub fn scan_time(name: &str) -> Option<Utc> {
    Utc::parse_compact(&site_and_time(name)?.1)
}

fn size_of(path: &Path) -> u64 {
    match std::fs::metadata(path) {
        Ok(m) if m.is_dir() => std::fs::read_dir(path).map(|d| d.filter_map(|e| e.ok()).map(|e| size_of(&e.path())).sum()).unwrap_or(0),
        Ok(m) => m.len(),
        Err(_) => 0,
    }
}

/// Deletes entries of `dir` oldest first until it holds at most `budget` bytes. Entries inside
/// any of `windows` and each site's newest entry are never deleted, even if the budget cannot
/// be met without them.
pub fn prune_dir(dir: &Path, budget: u64, windows: &[Window]) -> Result<Pruned> {
    let Ok(read) = std::fs::read_dir(dir) else { return Ok(Pruned::default()) };
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
        return Ok(Pruned { remaining: total, ..Pruned::default() });
    }
    let mut newest: HashMap<String, String> = HashMap::new();
    for (time, site, _, _) in &entries {
        let t = newest.entry(site.clone()).or_default();
        if time > t {
            *t = time.clone();
        }
    }
    let in_window = |time: &str| Utc::parse_compact(time).is_some_and(|t| windows.iter().any(|w| w.contains(t)));
    entries.sort();
    let mut out = Pruned::default();
    for (time, site, path, size) in entries {
        if total - out.freed <= budget {
            break;
        }
        if newest.get(&site) == Some(&time) || in_window(&time) {
            continue;
        }
        let gone = if path.is_dir() { std::fs::remove_dir_all(&path) } else { std::fs::remove_file(&path) };
        if gone.is_ok() {
            out.freed += size;
            out.deleted.push(path);
        }
    }
    out.remaining = total - out.freed;
    Ok(out)
}

/// Applies the quota to `data/volumes` and `data/raw` under `data`, protecting `windows`.
/// Returns a one-line summary if anything was deleted or the protected scans alone exceed the
/// quota (without volume names, which the fetch panel would take for new volumes).
pub fn prune_data(data: &Path, quota: u64, windows: &[Window]) -> Result<Option<String>> {
    let volumes_budget = (quota as f64 * VOLUMES_SHARE) as u64;
    let raw_budget = quota - volumes_budget;
    let vols = prune_dir(&data.join("volumes"), volumes_budget, windows)?;
    let raws = prune_dir(&data.join("raw"), raw_budget, windows)?;
    let over = vols.remaining > volumes_budget || raws.remaining > raw_budget;
    if vols.deleted.is_empty() && raws.deleted.is_empty() && !over {
        return Ok(None);
    }
    let mut summary = format!(
        "quota {:.1} GB: removed {} oldest volumes and {} raw files ({:.2} GB)",
        quota as f64 / 1e9,
        vols.deleted.len(),
        raws.deleted.len(),
        (vols.freed + raws.freed) as f64 / 1e9
    );
    if over {
        summary += &format!(
            "; still over quota at {:.2} GB: the time window and each site's newest scan are kept",
            (vols.remaining + raws.remaining) as f64 / 1e9
        );
    }
    Ok(Some(summary))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn iso(s: &str) -> Utc {
        Utc::parse_iso(s).unwrap()
    }

    fn mk(dir: &Path, name: &str, bytes: usize) {
        let d = dir.join(name);
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("s00_REF.bin"), vec![0u8; bytes]).unwrap();
    }

    fn names(p: &Pruned) -> Vec<String> {
        p.deleted.iter().map(|p| p.file_name().unwrap().to_string_lossy().to_string()).collect()
    }

    #[test]
    fn name_parsing() {
        assert_eq!(site_and_time("KTLX_20130520_200359"), Some(("KTLX".into(), "20130520_200359".into())));
        assert_eq!(site_and_time("KTLX20130520_200359_V06.gz"), Some(("KTLX".into(), "20130520_200359".into())));
        assert_eq!(site_and_time("KTLX20260922_180402_V06"), Some(("KTLX".into(), "20260922_180402".into())));
        assert_eq!(site_and_time("basemap"), None);
        assert_eq!(site_and_time("live_ring.json"), None);
        assert_eq!(site_and_time("KTLX_2013"), None);
        assert_eq!(scan_time("KTLX20130520_200359_V06.gz"), Some(iso("2013-05-20T20:03:59Z")));
        assert_eq!(scan_time("window.json"), None);
    }

    #[test]
    fn prunes_oldest_but_keeps_each_sites_newest() {
        let dir = crate::volume::tempdir::Dir::new("prune");
        mk(dir.path(), "KTLX_20130520_200359", 100); // oldest, but not the newest KTLX
        mk(dir.path(), "KTLX_20240501_220000", 100);
        mk(dir.path(), "KFDR_20100101_000000", 100); // KFDR's only volume: kept however old
        mk(dir.path(), "KTLX_20260922_180402", 100);
        std::fs::create_dir_all(dir.path().join("other")).unwrap(); // not ours: counted, kept
        let p = prune_dir(dir.path(), 250, &[]).unwrap();
        assert_eq!(names(&p), ["KTLX_20130520_200359", "KTLX_20240501_220000"]);
        assert_eq!((p.freed, p.remaining), (200, 200));
        assert!(dir.path().join("KFDR_20100101_000000").exists() && dir.path().join("KTLX_20260922_180402").exists());
        // Under budget: nothing to do.
        assert!(prune_dir(dir.path(), 1000, &[]).unwrap().deleted.is_empty());
    }

    /// #37: an old event fetched into a site with newer scans survives a tight quota; the newer
    /// scans outside the window go oldest first, except the site's newest.
    #[test]
    fn keeps_the_window_over_newer_scans() {
        let dir = crate::volume::tempdir::Dir::new("prune-window");
        let event = ["KTLX_20130520_193100", "KTLX_20130520_200359", "KTLX_20130520_204500"];
        for n in event {
            mk(dir.path(), n, 100);
        }
        mk(dir.path(), "KTLX_20130520_210000", 100); // same day, after the window
        for n in ["KTLX_20260923_110000", "KTLX_20260923_110500", "KTLX_20260923_111000", "KTLX_20260923_111500"] {
            mk(dir.path(), n, 100);
        }
        let window = Window { from: iso("2013-05-20T19:30:00Z"), to: iso("2013-05-20T20:45:00Z") };
        let p = prune_dir(dir.path(), 500, &[window]).unwrap();
        assert_eq!(names(&p), ["KTLX_20130520_210000", "KTLX_20260923_110000", "KTLX_20260923_110500"]);
        assert_eq!(p.remaining, 500);
        for n in event.iter().chain(&["KTLX_20260923_111000", "KTLX_20260923_111500"]) {
            assert!(dir.path().join(n).exists(), "{n} kept");
        }
        // Without the window the same budget would have taken the event first.
        let p = prune_dir(dir.path(), 300, &[]).unwrap();
        assert_eq!(names(&p), ["KTLX_20130520_193100", "KTLX_20130520_200359"]);
    }

    /// Protected scans alone over the budget are all kept, and the summary says so.
    #[test]
    fn window_over_budget_is_kept() {
        let data = crate::volume::tempdir::Dir::new("prune-over");
        let vols = data.path().join("volumes");
        for n in ["KTLX_20130520_200000", "KTLX_20130520_200500", "KTLX_20130520_201000", "KTLX_20260923_110000"] {
            mk(&vols, n, 100);
        }
        let window = Window { from: iso("2013-05-20T20:00Z"), to: iso("2013-05-20T20:10Z") };
        let p = prune_dir(&vols, 150, &[window]).unwrap();
        assert!(p.deleted.is_empty());
        assert_eq!(p.remaining, 400);
        let summary = prune_data(data.path(), 100, &[window]).unwrap().unwrap();
        assert!(summary.contains("removed 0 oldest volumes") && summary.contains("still over quota"), "{summary}");
        assert!(!summary.contains("KTLX"), "no volume names: {summary}");
        assert_eq!(std::fs::read_dir(&vols).unwrap().count(), 4);
        // Two windows: only the scan in neither goes.
        let other = Window { from: iso("2013-05-20T20:05Z"), to: iso("2013-05-20T20:05Z") };
        let p = prune_dir(&vols, 150, &[Window { from: iso("2013-05-20T20:10Z"), ..window }, other]).unwrap();
        assert_eq!(names(&p), ["KTLX_20130520_200000"]);
    }

    #[test]
    fn window_file_parsing() {
        let now = iso("2026-09-23T12:30:00Z");
        let text = r#"{"from": "2013-05-20T19:30:00Z", "to": "2013-05-20T20:45:00Z", "live": false, "written": "2026-09-23T12:00:00Z"}"#;
        let event = Window { from: iso("2013-05-20T19:30Z"), to: iso("2013-05-20T20:45Z") };
        assert_eq!(Window::parse_file(text, now), Some(event));
        assert!(event.contains(event.from) && event.contains(event.to) && !event.contains(event.to.add_ms(1)));
        // `live` is optional.
        let no_live = r#"{"from": "2013-05-20T19:30Z", "to": "2013-05-20T20:45Z", "written": "2026-09-23T12:00Z"}"#;
        assert_eq!(Window::parse_file(no_live, now), Some(event));
        // A live window rolls: the same span ending now, open-ended.
        let live = r#"{"from": "2026-09-23T11:00:00Z", "to": "2026-09-23T12:00:00Z", "live": true, "written": "2026-09-23T12:00:00Z"}"#;
        let w = Window::parse_file(live, now).unwrap();
        assert_eq!(w, Window { from: iso("2026-09-23T11:30Z"), to: Window::OPEN });
        assert!(w.contains(now.add_secs(30.0)) && !w.contains(iso("2026-09-23T11:15Z")));
        // Stale (a crash left it behind) or invalid: ignored.
        assert_eq!(Window::parse_file(text, iso("2026-09-24T12:00:01Z")), None, "stale");
        assert_eq!(Window::parse_file(text, iso("2026-09-24T12:00:00Z")), Some(event), "one day is still fresh");
        for bad in [
            "",
            "not json",
            "[]",
            r#"{"from": "2013-05-20T19:30Z", "to": "2013-05-20T20:45Z"}"#,
            r#"{"from": "2013-05-20T20:45Z", "to": "2013-05-20T19:30Z", "written": "2026-09-23T12:00Z"}"#,
            r#"{"from": "yesterday", "to": "2013-05-20T20:45Z", "written": "2026-09-23T12:00Z"}"#,
            r#"{"from": 1369078200, "to": "2013-05-20T20:45Z", "written": "2026-09-23T12:00Z"}"#,
            r#"{"from": "2013-05-20T19:30Z", "to": "2013-05-20T20:45Z", "live": "no", "written": "2026-09-23T12:00Z"}"#,
        ] {
            assert_eq!(Window::parse_file(bad, now), None, "{bad}");
        }
    }

    #[test]
    fn stale_window_file_is_ignored() {
        let data = crate::volume::tempdir::Dir::new("prune-stale");
        let vols = data.path().join("volumes");
        for n in ["KTLX_20130520_200000", "KTLX_20260923_110000", "KTLX_20260923_110500"] {
            mk(&vols, n, 100);
        }
        let file = r#"{"from": "2013-05-20T19:30Z", "to": "2013-05-20T20:45Z", "live": false, "written": "2026-09-20T12:00Z"}"#;
        std::fs::write(data.path().join(WINDOW_FILE), file).unwrap();
        let now = iso("2026-09-23T12:00Z");
        assert_eq!(Window::read_file(data.path(), now), None);
        assert_eq!(Window::read_file(&data.path().join("absent"), now), None);
        let windows: Vec<Window> = Window::read_file(data.path(), now).into_iter().collect();
        let p = prune_dir(&vols, 200, &windows).unwrap();
        assert_eq!(names(&p), ["KTLX_20130520_200000"], "the old event is not protected");
        // The same file written recently protects it.
        mk(&vols, "KTLX_20130520_200000", 100);
        std::fs::write(data.path().join(WINDOW_FILE), file.replace("2026-09-20", "2026-09-23")).unwrap();
        let windows: Vec<Window> = Window::read_file(data.path(), now).into_iter().collect();
        assert_eq!(windows.len(), 1);
        assert_eq!(names(&prune_dir(&vols, 200, &windows).unwrap()), ["KTLX_20260923_110000"]);
    }
}

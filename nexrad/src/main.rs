//! CLI: nexrad <command> ...
//!
//! History (archive mirror, ~5 min behind real time, back to ~2008):
//!     nexrad latest KTLX                          # newest key on the mirror
//!     nexrad fetch KTLX                           # newest volume -> data/raw/
//!     nexrad fetch KTLX --at 2013-05-20T20:00Z    # nearest volume at/before a time
//!     nexrad fetch KTLX --from 2013-05-20T19:30Z --to 2013-05-20T21:30Z
//!     nexrad decode data/raw/KTLX*                # raw -> data/volumes/<ICAO>_<time>/
//!     nexrad update KTLX [--at ...]               # fetch + decode
//!     nexrad derive [data/volumes/KTLX_*]         # (re)compute VAD winds, storm motion and
//!                                                 # the derived fields, products and HCA (alias: winds)
//!
//! Live (chunks bucket, seconds behind real time):
//!     nexrad live KTLX [KFDR ...] [--interval 5] [--since-minutes 60]
//!                                                 # backfill complete scans in the live window,
//!                                                 # then poll partial scans (one thread per site)
//!
//! Disk: update, live and `nexrad prune` keep data/ under $DROPLET_QUOTA_GB (default 20) by
//! deleting the oldest volumes and raw files outside the app's time window (data/window.json,
//! see nexrad::prune). `fetch`/`update` also protect the scans they just fetched;
//! `nexrad prune --keep-from T --keep-to T` protects that range instead of the file's.
//!
//! Basemap (state/county lines and city labels, once):
//!     nexrad basemap                              # -> data/basemap/
//!
//! Tests:
//!     nexrad synth [out_dir]                      # synthetic fixture volumes -> tests/fixtures/volumes
//!
//! `data/` and `tests/` are resolved under $DROPLET_ROOT, or the current directory.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::exit;

use nexrad::archive::{self, Selection};
use nexrad::net::HttpBucket;
use nexrad::prune::Window;
use nexrad::time::Utc;
use nexrad::{Result, basemap, chunks, level2, prune, synth, volume};

fn root() -> PathBuf {
    std::env::var_os("DROPLET_ROOT").map(PathBuf::from).unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| ".".into()))
}

/// The app's current window from `data/window.json`, if fresh (see nexrad::prune).
fn app_window(root: &Path) -> Option<Window> {
    Window::read_file(&root.join("data"), Utc::now())
}

/// Keeps `data/` under `$DROPLET_QUOTA_GB` (see nexrad::prune), protecting scans inside
/// `windows`; reports on stderr.
fn enforce_quota(root: &Path, windows: &[Window]) {
    match prune::prune_data(&root.join("data"), prune::quota_bytes(), windows) {
        Ok(Some(summary)) => eprintln!("{summary}"),
        Ok(None) => {}
        Err(e) => eprintln!("prune: {e}"),
    }
}

fn usage() -> ! {
    eprintln!("usage: nexrad latest|fetch|update SITE [--at T | --from T --to T]");
    eprintln!("       nexrad decode PATH...");
    eprintln!("       nexrad live SITE... [--interval SECONDS] [--since-minutes MINUTES]");
    eprintln!("       nexrad derive [VOLUME_DIR...]");
    eprintln!("       nexrad basemap");
    eprintln!("       nexrad prune [--keep-from T --keep-to T]");
    eprintln!("                    (keep data/ under $DROPLET_QUOTA_GB, default 20, deleting the oldest");
    eprintln!("                     scans outside the range, else outside data/window.json)");
    eprintln!("       nexrad synth [OUT_DIR]");
    exit(2)
}

/// `SITE [--at T] [--from T --to T]`.
fn parse_selection(args: &[String]) -> Result<(String, Selection)> {
    let site = args.first().filter(|a| !a.starts_with("--")).ok_or("missing SITE")?.to_uppercase();
    let mut sel = Selection::default();
    let mut i = 1;
    while i < args.len() {
        let value = args.get(i + 1).ok_or_else(|| format!("{} needs a value", args[i]))?;
        match args[i].as_str() {
            "--at" => sel.at = Some(Utc::parse_iso(value)?),
            "--from" => sel.start = Some(Utc::parse_iso(value)?),
            "--to" => sel.end = Some(Utc::parse_iso(value)?),
            other => return Err(format!("unknown option {other}").into()),
        }
        i += 2;
    }
    Ok((site, sel))
}

/// `SITE... [--interval SECONDS] [--since-minutes MINUTES]`.
fn parse_live(args: &[String]) -> Result<(Vec<String>, f64, u32)> {
    let sites: Vec<String> = args.iter().take_while(|a| !a.starts_with("--")).map(|s| s.to_uppercase()).collect();
    if sites.is_empty() {
        return Err("missing SITE".into());
    }
    let mut interval = 5.0f64;
    let mut since_minutes = archive::DEFAULT_BACKFILL_MINUTES;
    let mut i = sites.len();
    while i < args.len() {
        let value = args.get(i + 1).ok_or_else(|| format!("{} needs a value", args[i]))?;
        match args[i].as_str() {
            "--interval" => interval = value.parse().map_err(|_| "--interval: not a number")?,
            "--since-minutes" => {
                let minutes: u32 = value.parse().map_err(|_| "--since-minutes: not a whole number of minutes")?;
                since_minutes = minutes.min(archive::MAX_BACKFILL_MINUTES);
            }
            other => return Err(format!("unknown option {other}").into()),
        }
        i += 2;
    }
    Ok((sites, interval, since_minutes))
}

fn decode(path: &Path, volumes_dir: &Path) -> Result<PathBuf> {
    volume::write_volume(&level2::read_file(path)?, volumes_dir)
}

/// Write a followed chunk using only this live session's last complete scan as its temporal
/// reference. A partial scan is published but cannot become the next scan's prior.
fn write_live_volume(v: &level2::Volume, volumes_dir: &Path, session_prior: &mut Option<archive::BackfillSeed>) -> Result<String> {
    let reference = session_prior
        .as_ref()
        .filter(|seed| seed.name.get(..4).is_some_and(|site| volume::is_prior(&v.icao, v.time, site, seed.time)))
        .map(|seed| seed.prior.as_slice())
        .unwrap_or(&[]);
    let enc = volume::encode_volume_with(v, reference);
    let dir = volume::write_encoded(&enc, volumes_dir)?;
    if v.complete {
        *session_prior = Some(archive::BackfillSeed { name: volume::volume_dir_name(&v.icao, v.time), time: v.time, prior: enc.prior() });
    }
    Ok(dir.file_name().and_then(|n| n.to_str()).unwrap_or("").to_string())
}

fn run(args: &[String]) -> Result<()> {
    let root = root();
    let raw_dir = root.join("data").join("raw");
    let volumes_dir = root.join("data").join("volumes");
    let mut err = std::io::stderr();
    let Some(cmd) = args.first() else { usage() };
    let rest = &args[1..];
    match cmd.as_str() {
        "latest" => {
            let (site, _) = parse_selection(rest)?;
            println!("{}", archive::latest_key(&HttpBucket::new(archive::BUCKET), &site)?);
        }
        "fetch" | "update" => {
            let (site, sel) = parse_selection(rest)?;
            let bucket = HttpBucket::new(archive::BUCKET);
            let keys = archive::resolve_keys(&bucket, &site, &sel)?;
            // Protect what this command fetched (and the requested range) besides the app's
            // window, so a quota tighter than the range does not delete it right away.
            let mut fetched: Vec<Utc> = [sel.start, sel.end].into_iter().flatten().collect();
            for (i, k) in keys.iter().enumerate() {
                let path = if cmd == "update" {
                    // "[i/n]" progress on stderr and one decoded path per line on stdout; the Godot
                    // fetch dialog (scripts/fetcher.gd) reads both.
                    eprintln!("[{}/{}] {}", i + 1, keys.len(), archive::file_name(k));
                    decode(&archive::download(&bucket, k, &raw_dir, &mut err)?, &volumes_dir)?
                } else {
                    archive::download(&bucket, k, &raw_dir, &mut err)?
                };
                fetched.extend(prune::scan_time(archive::file_name(k)));
                fetched.extend(path.file_name().and_then(|n| prune::scan_time(&n.to_string_lossy())));
                println!("{}", path.display());
                let _ = std::io::stdout().flush();
            }
            let mut windows: Vec<Window> = app_window(&root).into_iter().collect();
            if let (Some(&from), Some(&to)) = (fetched.iter().min(), fetched.iter().max()) {
                windows.push(Window { from, to });
            }
            enforce_quota(&root, &windows);
        }
        "decode" => {
            if rest.is_empty() {
                usage();
            }
            for p in rest {
                println!("{}", decode(Path::new(p), &volumes_dir)?.display());
                let _ = std::io::stdout().flush();
            }
        }
        "live" => {
            // One or more sites, each followed on its own thread.
            let (sites, interval, since_minutes) = parse_live(rest)?;
            // Remember where each ring was, so the next run needs a few listings, not ~20.
            let ring_file = root.join("data").join("live_ring.json");
            let ring: serde_json::Map<String, serde_json::Value> =
                std::fs::read_to_string(&ring_file).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
            let ring = std::sync::Mutex::new(ring);
            let follow = |site: &str| -> Result<()> {
                // Whole lines (one write() call each), so several sites' output does not
                // interleave mid-line and the fetch panel (scripts/fetcher.gd) can regex-match
                // volume names out of either pipe.
                let mut out = std::io::LineWriter::new(std::io::stdout());
                let mut log = std::io::LineWriter::new(std::io::stderr());

                // Publish newest first, then finalize the temporal chain oldest first.
                // A temporarily unavailable mirror must not prevent chunk following.
                let mut last_backfilled = None;
                let archive_bucket = HttpBucket::new(archive::BUCKET);
                let now = Utc::now();
                let since = now.add_secs(-60.0 * f64::from(since_minutes));
                match archive::keys_since(&archive_bucket, site, since, now) {
                    Ok(keys) => {
                        last_backfilled = archive::backfill(
                            &archive_bucket,
                            &keys,
                            &raw_dir,
                            &volumes_dir,
                            |path| {
                                let _ = writeln!(out, "{}", path.display());
                            },
                            &mut log,
                        );
                        if !keys.is_empty() {
                            enforce_quota(&root, app_window(&root).as_slice());
                        }
                    }
                    Err(e) => {
                        let _ = writeln!(log, "{site}: backfill unavailable: {e}");
                    }
                }

                let bucket = HttpBucket::new(chunks::BUCKET);
                let sleep = || {
                    std::thread::sleep(std::time::Duration::from_secs_f64(interval.max(0.0)));
                    true
                };
                let seed_name = last_backfilled.as_ref().map(|seed| seed.name.clone());
                let mut session_prior = last_backfilled;
                let mut sink = |v: &level2::Volume| -> Result<String> {
                    let name = volume::volume_dir_name(&v.icao, v.time);
                    if v.complete && seed_name.as_deref() == Some(name.as_str()) {
                        // Exact duplicate of the backfill's last volume (the archive mirror
                        // caught up to it before live started): already on disk, skip the
                        // redundant decode + write instead of reporting it a second time.
                        return Ok(name);
                    }
                    let name = write_live_volume(v, &volumes_dir, &mut session_prior)?;
                    if v.complete {
                        enforce_quota(&root, app_window(&root).as_slice());
                    }
                    Ok(name)
                };
                let hint = ring
                    .lock()
                    .unwrap()
                    .get(site)
                    .and_then(|v| Some((v.get(0)?.as_u64()? as u32, Utc::parse_compact(v.get(1)?.as_str()?)?)));
                let start = chunks::Start::Newest { hint, now: Utc::now() };
                let mut remember = |v: u32, t: Utc| {
                    let mut ring = ring.lock().unwrap();
                    ring.insert(site.to_string(), serde_json::json!([v, t.compact()]));
                    if let Ok(text) = serde_json::to_string(&*ring) {
                        let _ = volume::write_atomic(&ring_file, text.as_bytes());
                    }
                };
                chunks::live(&bucket, site, &mut sink, start, &mut remember, sleep, &mut log)
            };
            let results: Vec<Result<()>> = std::thread::scope(|s| {
                let handles: Vec<_> = sites.iter().map(|site| s.spawn(|| follow(site))).collect();
                handles.into_iter().map(|h| h.join().unwrap_or_else(|_| Err("live thread panicked".into()))).collect()
            });
            for r in results {
                r?;
            }
        }
        "prune" => {
            let (mut from, mut to) = (None, None);
            let mut i = 0;
            while i < rest.len() {
                let value = rest.get(i + 1).ok_or_else(|| format!("{} needs a value", rest[i]))?;
                match rest[i].as_str() {
                    "--keep-from" => from = Some(Utc::parse_iso(value)?),
                    "--keep-to" => to = Some(Utc::parse_iso(value)?),
                    other => return Err(format!("unknown option {other}").into()),
                }
                i += 2;
            }
            let windows: Vec<Window> = match (from, to) {
                (Some(from), Some(to)) if from <= to => vec![Window { from, to }],
                (None, None) => app_window(&root).into_iter().collect(),
                (Some(_), Some(_)) => return Err("--keep-from is after --keep-to".into()),
                _ => return Err("--keep-from and --keep-to go together".into()),
            };
            enforce_quota(&root, &windows);
        }
        "derive" | "winds" => {
            let dirs: Vec<PathBuf> = if rest.is_empty() {
                let mut d: Vec<PathBuf> = std::fs::read_dir(&volumes_dir)?
                    .filter_map(|e| e.ok())
                    .map(|e| e.path())
                    .filter(|p| p.join("volume.json").exists())
                    .collect();
                d.sort();
                d
            } else {
                rest.iter().map(PathBuf::from).collect()
            };
            for d in dirs {
                let name = d.file_name().and_then(|n| n.to_str()).unwrap_or("").to_string();
                let desc = match volume::add_winds(&d)? {
                    Some(sm) => {
                        let [u, v] = sm.right;
                        let from = ((-u).atan2(-v).to_degrees() + 360.0) % 360.0;
                        format!("storm (Bunkers right) from {from:03.0} deg at {:.1} m/s, 0-1 km SRH {:.0}", u.hypot(v), sm.srh_0_1km)
                    }
                    None => "no storm motion (profile too sparse)".to_string(),
                };
                let prods = if volume::add_derived(&d)? { "AZSHR/KDP, CREF/ET/VIL" } else { "AZSHR/KDP, no REF so no products" };
                let hca = match volume::read_meta(&d)?.melting_layer {
                    Some(ml) => format!("; HCA, melting layer {:.1}-{:.1} km ({})", ml.bottom_m / 1000.0, ml.top_m / 1000.0, ml.source),
                    None => String::new(),
                };
                println!("{name}: {desc}; {prods}{hca}");
            }
        }
        "basemap" => {
            println!("{}", basemap::build(&root.join("data").join("basemap"), &raw_dir.join("basemap"), &mut err)?.display());
        }
        "synth" => {
            let out = rest.first().map(PathBuf::from).unwrap_or_else(|| root.join("tests").join("fixtures").join("volumes"));
            for p in synth::build_fixtures(&out)? {
                println!("{}", p.display());
            }
        }
        "-h" | "--help" | "help" => usage(),
        other => {
            eprintln!("unknown command {other}");
            usage()
        }
    }
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Err(e) = run(&args) {
        eprintln!("nexrad: {e}");
        exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nexrad::synth;
    use std::sync::atomic::{AtomicU64, Ordering};

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(label: &str) -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let path =
                std::env::temp_dir().join(format!("droplet-{label}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_string()).collect()
    }

    #[test]
    fn live_arguments_select_window_without_changing_historical_selection() {
        assert_eq!(parse_live(&args(&["ktlx", "KFDR"])).unwrap(), (vec!["KTLX".into(), "KFDR".into()], 5.0, 60));
        assert_eq!(parse_live(&args(&["KTLX", "--since-minutes", "20", "--interval", "2.5"])).unwrap().2, 20);
        assert_eq!(parse_live(&args(&["KTLX", "--since-minutes", "99999"])).unwrap().2, archive::MAX_BACKFILL_MINUTES);
        assert!(parse_live(&args(&["KTLX", "--since-minutes", "-5"])).is_err());
        assert!(parse_live(&args(&["KTLX", "--since-minutes"])).is_err());
        assert!(parse_live(&args(&["KTLX", "--bogus", "1"])).is_err());
        assert!(parse_live(&args(&["--since-minutes", "5"])).is_err());
        assert!(parse_selection(&args(&["KTLX", "--at", "2013-05-20T20:00Z"])).unwrap().1.at.is_some());
        let (_, range) = parse_selection(&args(&["KTLX", "--from", "2013-05-20T19:30Z", "--to", "2013-05-20T20:00Z"])).unwrap();
        assert!(range.start.is_some() && range.end.is_some());
    }

    fn shifted_cached_prior(v: &level2::Volume, time: Utc) -> volume::Encoded {
        let mut cached = volume::encode_volume(v);
        cached.meta.time = time.isoformat();
        let period = 2.0 * synth::fixture_scene().nyquist_ms as f32;
        for (name, bytes) in &mut cached.files {
            if name.ends_with("_DVEL.bin") {
                for gate in bytes.as_chunks_mut::<2>().0 {
                    let value = half::f16::from_le_bytes(*gate).to_f32();
                    if value > -900.0 {
                        *gate = half::f16::from_f32(value + period).to_le_bytes();
                    }
                }
            }
        }
        cached
    }

    fn assert_files_match(dir: &Path, expected: &volume::Encoded) {
        for (name, bytes) in &expected.files {
            assert_eq!(std::fs::read(dir.join(name)).unwrap(), *bytes, "{name}");
        }
        assert_eq!(volume::read_meta(dir).unwrap(), expected.meta);
    }

    #[test]
    fn live_without_backfill_ignores_a_cached_disk_prior() {
        let dir = TempDir::new("live-empty-window-prior");
        let vols = synth::fixture_volumes();
        let cached = shifted_cached_prior(&vols[0], vols[0].time);
        volume::write_encoded(&cached, dir.path()).unwrap();
        let expected = volume::encode_volume(&vols[1]);
        let from_disk = volume::encode_volume_with(&vols[1], &cached.prior());
        assert!(expected.files.iter().any(|(name, bytes)| name.ends_with("_DVEL.bin") && from_disk.file(name) != Some(bytes.as_slice())));
        let mut prior = None;
        let name = write_live_volume(&vols[1], dir.path(), &mut prior).unwrap();
        assert_files_match(&dir.path().join(name), &expected);
        assert_eq!(prior.unwrap().time, vols[1].time);
    }

    #[test]
    fn live_uses_backfill_seed_over_a_newer_cached_disk_scan_and_ignores_partial_as_prior() {
        let dir = TempDir::new("live-session-prior");
        let vols = synth::fixture_volumes();
        let seed = volume::encode_volume(&vols[0]);
        let cached = shifted_cached_prior(&vols[0], vols[0].time.add_secs(150.0));
        volume::write_encoded(&cached, dir.path()).unwrap();
        let expected = volume::encode_volume_with(&vols[1], &seed.prior());
        let from_disk = volume::encode_volume_with(&vols[1], &cached.prior());
        assert!(expected.files.iter().any(|(name, bytes)| name.ends_with("_DVEL.bin") && from_disk.file(name) != Some(bytes.as_slice())));
        let mut prior = Some(archive::BackfillSeed {
            name: volume::volume_dir_name(&vols[0].icao, vols[0].time),
            time: vols[0].time,
            prior: seed.prior(),
        });
        let mut partial = vols[1].clone();
        partial.complete = false;
        write_live_volume(&partial, dir.path(), &mut prior).unwrap();
        assert_eq!(prior.as_ref().unwrap().time, vols[0].time);
        let name = write_live_volume(&vols[1], dir.path(), &mut prior).unwrap();
        assert_files_match(&dir.path().join(name), &expected);
        assert_eq!(prior.unwrap().time, vols[1].time);
    }
}

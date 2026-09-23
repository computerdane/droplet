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
//!                                                 # the column products (alias: winds)
//!
//! Live (chunks bucket, seconds behind real time):
//!     nexrad live KTLX [KFDR ...] [--interval 5]  # poll, decode partial volumes as they grow
//!                                                 # (several sites: one thread each)
//!
//! Disk: update, live and `nexrad prune` keep data/ under $DROPLET_QUOTA_GB (default 20) by
//! deleting the oldest volumes and raw files (see nexrad::prune).
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
use nexrad::time::Utc;
use nexrad::{Result, basemap, chunks, level2, prune, synth, volume};

fn root() -> PathBuf {
    std::env::var_os("DROPLET_ROOT").map(PathBuf::from).unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| ".".into()))
}

/// Keeps `data/` under `$DROPLET_QUOTA_GB` (see nexrad::prune); reports on stderr.
fn enforce_quota(root: &Path) {
    match prune::prune_data(&root.join("data"), prune::quota_bytes()) {
        Ok(Some(summary)) => eprintln!("{summary}"),
        Ok(None) => {}
        Err(e) => eprintln!("prune: {e}"),
    }
}

fn usage() -> ! {
    eprintln!("usage: nexrad latest|fetch|update SITE [--at T | --from T --to T]");
    eprintln!("       nexrad decode PATH...");
    eprintln!("       nexrad live SITE... [--interval SECONDS]");
    eprintln!("       nexrad derive [VOLUME_DIR...]");
    eprintln!("       nexrad basemap");
    eprintln!("       nexrad prune                  (keep data/ under $DROPLET_QUOTA_GB, default 20)");
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

fn decode(path: &Path, volumes_dir: &Path) -> Result<PathBuf> {
    volume::write_volume(&level2::read_file(path)?, volumes_dir)
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
            for (i, k) in keys.iter().enumerate() {
                let path = if cmd == "update" {
                    // "[i/n]" progress on stderr and one decoded path per line on stdout; the Godot
                    // fetch dialog (scripts/fetcher.gd) reads both.
                    eprintln!("[{}/{}] {}", i + 1, keys.len(), archive::file_name(k));
                    decode(&archive::download(&bucket, k, &raw_dir, &mut err)?, &volumes_dir)?
                } else {
                    archive::download(&bucket, k, &raw_dir, &mut err)?
                };
                println!("{}", path.display());
                let _ = std::io::stdout().flush();
            }
            enforce_quota(&root);
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
            let sites: Vec<String> = rest.iter().take_while(|a| !a.starts_with("--")).map(|s| s.to_uppercase()).collect();
            if sites.is_empty() {
                return Err("missing SITE".into());
            }
            let mut interval = 5.0f64;
            let mut i = sites.len();
            while i < rest.len() {
                match rest[i].as_str() {
                    "--interval" => {
                        interval = rest.get(i + 1).ok_or("--interval needs a value")?.parse().map_err(|_| "--interval: not a number")?;
                        i += 2;
                    }
                    other => return Err(format!("unknown option {other}").into()),
                }
            }
            // Remember where each ring was, so the next run needs a few listings, not ~20.
            let ring_file = root.join("data").join("live_ring.json");
            let ring: serde_json::Map<String, serde_json::Value> =
                std::fs::read_to_string(&ring_file).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
            let ring = std::sync::Mutex::new(ring);
            let follow = |site: &str| -> Result<()> {
                let bucket = HttpBucket::new(chunks::BUCKET);
                let sleep = || {
                    std::thread::sleep(std::time::Duration::from_secs_f64(interval.max(0.0)));
                    true
                };
                let mut sink = |v: &level2::Volume| -> Result<String> {
                    let dir = volume::write_volume(v, &volumes_dir)?;
                    if v.complete {
                        enforce_quota(&root);
                    }
                    Ok(dir.file_name().and_then(|n| n.to_str()).unwrap_or("").to_string())
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
                // Whole lines, so several sites' logs do not interleave mid-line.
                let mut log = std::io::LineWriter::new(std::io::stderr());
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
        "prune" => enforce_quota(&root),
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
                println!("{name}: {desc}; {prods}");
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

//! Raw deterministic Archive2 data for browser smoke tests; no public radar service needed.
use nexrad::synth::{self, Layout};

fn main() -> nexrad::Result<()> {
    let path = std::env::args().nth(1).ok_or("usage: web_fixture OUTPUT")?;
    let mut volume = synth::small_volume();
    volume.icao = "KTLX".into();
    std::fs::write(path, synth::encode_archive(&volume, Layout::Bz2))?;
    Ok(())
}

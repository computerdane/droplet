//! Dealiasing consistency over time: for consecutive volume directories of one site, the share
//! of gates on each of the lowest six DVEL tilts that differ from the previous volume's by more
//! than the Nyquist velocity. A few tenths of a percent is storm evolution; whole percents mean
//! a component placed a fold off in one of the two.
//!
//! ```text
//! cargo run --release --example fold_check -- data/volumes/KTLX_20130520_*
//! ```
use nexrad::products::tilts;
use nexrad::volume::{read_field, read_meta};
use std::path::Path;

fn main() {
    let dirs: Vec<String> = std::env::args().skip(1).collect();
    for w in dirs.windows(2) {
        let (a, b) = (Path::new(&w[0]), Path::new(&w[1]));
        let (ma, mb) = (read_meta(a).unwrap(), read_meta(b).unwrap());
        let (ta, tb) = (tilts(&ma.sweeps, "DVEL"), tilts(&mb.sweeps, "DVEL"));
        let mut line = format!("{} ", b.file_name().unwrap().to_str().unwrap());
        for (k, &ib) in tb.iter().enumerate().take(6) {
            let sb = &mb.sweeps[ib];
            let Some(&ia) = ta.iter().find(|&&i| (ma.sweeps[i].elevation_deg - sb.elevation_deg).abs() < 0.2) else { continue };
            let sa = &ma.sweeps[ia];
            let (ga, gb) = (read_field(a, sa, "DVEL").unwrap().unwrap(), read_field(b, sb, "DVEL").unwrap().unwrap());
            let fa = &sa.fields["DVEL"];
            let fb = &sb.fields["DVEL"];
            let vn = sb.nyquist_ms.unwrap_or(30.0);
            let (mut n, mut bad) = (0usize, 0usize);
            for r in 0..gb.n_az {
                let ra = r * ga.n_az / gb.n_az;
                for g in 0..gb.n_gates {
                    let rng = fb.first_gate_m as f64 + g as f64 * fb.gate_spacing_m as f64;
                    let gga = ((rng - fa.first_gate_m as f64) / fa.gate_spacing_m as f64).round() as i64;
                    if gga < 0 || gga >= ga.n_gates as i64 {
                        continue;
                    }
                    let (x, y) = (gb.at(r, g), ga.at(ra, gga as usize));
                    if x < -900.0 || y < -900.0 {
                        continue;
                    }
                    n += 1;
                    if ((x - y) as f64).abs() > vn {
                        bad += 1;
                    }
                }
            }
            line += &format!(" t{k} {:.1}° {:.3}%", sb.elevation_deg, 100.0 * bad as f64 / n.max(1) as f64);
        }
        println!("{line}");
    }
}

//! NEXRAD Level II pipeline for droplet: fetch (archive mirror and the real-time chunks
//! bucket), decode, dealias, VAD winds, and the on-disk volume format Godot reads.
//! Pure Rust so the same code runs natively and in the browser.

pub mod archive;
pub mod basemap;
pub mod cells;
pub mod chunks;
pub mod dealias;
pub mod fields;
pub mod grid;
pub mod level2;
#[cfg(feature = "native")]
pub mod net;
pub mod products;
#[cfg(feature = "native")]
pub mod prune;
pub mod synth;
pub mod time;
pub mod vad;
pub mod volume;

pub type Error = Box<dyn std::error::Error + Send + Sync>;
pub type Result<T> = std::result::Result<T, Error>;

/// Rounds like Python's `round(x, digits)` for the small `digits` used in metadata.
pub fn round_to(x: f64, digits: i32) -> f64 {
    let f = 10f64.powi(digits);
    (x * f).round_ties_even() / f
}

//! wasm-bindgen entry point: `decode(raw)` runs the same read → rasterise → dealias → VAD
//! path as `nexrad decode` and returns the volume in memory instead of writing it to disk.

use js_sys::{Date, Map, Object, Reflect, Uint8Array};
use nexrad::{level2, volume};
use wasm_bindgen::prelude::*;

/// Raw archive bytes (bzip2 or gzip layout) → `{ name, volume_json, files, read_ms, encode_ms }`,
/// where `name` is the volume directory (`ICAO_YYYYMMDD_HHMMSS`), `volume_json` the exact
/// `volume.json` text and `files` a `Map` of `sNN_<FIELD>.bin` → float16 `Uint8Array`.
#[wasm_bindgen]
pub fn decode(raw: &[u8]) -> Result<Object, JsError> {
    let t0 = Date::now();
    let vol = level2::read_volume(raw).map_err(|e| JsError::new(&e.to_string()))?;
    let t1 = Date::now();
    let enc = volume::encode_volume(&vol);
    let text = volume::meta_json(&enc.meta).map_err(|e| JsError::new(&e.to_string()))?;
    let t2 = Date::now();

    let files = Map::new();
    for (name, bytes) in &enc.files {
        files.set(&name.into(), &Uint8Array::from(&bytes[..]));
    }
    let out = Object::new();
    let set = |k: &str, v: JsValue| Reflect::set(&out, &k.into(), &v).map(|_| ());
    set("name", volume::volume_dir_name(&vol.icao, vol.time).into()).map_err(err)?;
    set("volume_json", text.into()).map_err(err)?;
    set("files", files.into()).map_err(err)?;
    set("read_ms", (t1 - t0).into()).map_err(err)?;
    set("encode_ms", (t2 - t1).into()).map_err(err)?;
    Ok(out)
}

fn err(e: JsValue) -> JsError {
    JsError::new(&format!("{e:?}"))
}

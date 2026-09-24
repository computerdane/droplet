//! wasm-bindgen entry points for the browser (web/nexrad_worker.js runs them in a Web Worker):
//! `decode(raw)` runs the same read → rasterise → dealias → VAD path as `nexrad decode` and
//! returns the volume in memory; `resolve_keys()` and `live()` are `nexrad update`'s key
//! selection and `nexrad live` over a bucket whose HTTP the worker supplies.

use js_sys::{Array, Date, Function, Map, Object, Reflect, Uint8Array};
use nexrad::archive::{self, Bucket, Selection};
use nexrad::level2::{self, Volume};
use nexrad::time::Utc;
use nexrad::{chunks, volume};
use wasm_bindgen::prelude::*;

/// Raw archive bytes (bzip2 or gzip layout) → `{ name, volume_json, files, read_ms, encode_ms }`,
/// where `name` is the volume directory (`ICAO_YYYYMMDD_HHMMSS`), `volume_json` the exact
/// `volume.json` text and `files` a `Map` of `sNN_<FIELD>.bin` → float16 `Uint8Array`.
/// `key` (the archive key or file name) supplies the site of pre-2008 files whose header lacks it.
#[wasm_bindgen]
pub fn decode(raw: &[u8], key: Option<String>) -> Result<Object, JsError> {
    let t0 = Date::now();
    let vol = level2::read_volume(raw).map_err(|e| JsError::new(&e.to_string()))?;
    let vol = level2::with_site(vol, key.as_deref().unwrap_or(""));
    if vol.icao.is_empty() {
        return Err(JsError::new("no site id in the header or the key"));
    }
    let t1 = Date::now();
    let (out, _) = encode(&vol, &[])?;
    Reflect::set(&out, &"read_ms".into(), &(t1 - t0).into()).map_err(err)?;
    Reflect::set(&out, &"encode_ms".into(), &(Date::now() - t1).into()).map_err(err)?;
    Ok(out)
}

/// `{ name, volume_json, files }` for a decoded volume, as `decode` returns it, and the volume
/// itself (for `Encoded::prior`). `prior` = the previous volume's DVEL (see `volume::add_dealiased`).
fn encode(vol: &Volume, prior: &[volume::PriorTilt]) -> Result<(Object, volume::Encoded), JsError> {
    let enc = volume::encode_volume_with(vol, prior);
    let text = volume::meta_json(&enc.meta).map_err(|e| JsError::new(&e.to_string()))?;
    let files = Map::new();
    for (name, bytes) in &enc.files {
        files.set(&name.into(), &Uint8Array::from(&bytes[..]));
    }
    let out = Object::new();
    let set = |k: &str, v: JsValue| Reflect::set(&out, &k.into(), &v).map(|_| ());
    set("name", volume::volume_dir_name(&vol.icao, vol.time).into()).map_err(err)?;
    set("volume_json", text.into()).map_err(err)?;
    set("files", files.into()).map_err(err)?;
    Ok((out, enc))
}

/// An update decodes its volumes in parallel, so none has its predecessor as the temporal
/// dealiasing reference: this dealiases `volume_json` + `files` (`decode()`'s shape) again with
/// the previous volume (`prior_json`, `prior_files`: its DVEL files suffice) if that one is its
/// prior (`volume::is_prior`). Returns null if nothing changed, else `{volume_json, files}` with
/// the new volume.json and the changed sweep files only.
#[wasm_bindgen]
pub fn redealias(volume_json: &str, files: &Map, prior_json: &str, prior_files: &Map) -> Result<JsValue, JsError> {
    let parse = |text: &str| volume::parse_meta(text).map_err(|e| JsError::new(&e.to_string()));
    let (meta, prior_meta) = (parse(volume_json)?, parse(prior_json)?);
    let time = |m: &volume::VolumeMeta| Utc::parse_iso(&m.time).map_err(|e| JsError::new(&e.to_string()));
    if !volume::is_prior(&meta.icao, time(&meta)?, &prior_meta.icao, time(&prior_meta)?) {
        return Ok(JsValue::NULL);
    }
    let get = |map: &Map, name: &str| map.get(&name.into()).dyn_into::<Uint8Array>().ok().map(|a| a.to_vec());
    let prior = volume::prior_tilts(&prior_meta, |f| get(prior_files, f));
    let mut enc = volume::Encoded { meta, files: Vec::new() };
    for key in files.keys() {
        let name = key.map_err(err)?.as_string().unwrap_or_default();
        let bytes = get(files, &name).unwrap_or_default();
        enc.files.push((name, bytes));
    }
    let changed = enc.redealias(&prior);
    if changed.is_empty() {
        return Ok(JsValue::NULL);
    }
    let out_files = Map::new();
    for name in &changed {
        out_files.set(&name.into(), &Uint8Array::from(enc.file(name).unwrap_or_default()));
    }
    let out = Object::new();
    let text = volume::meta_json(&enc.meta).map_err(|e| JsError::new(&e.to_string()))?;
    Reflect::set(&out, &"volume_json".into(), &text.into()).map_err(err)?;
    Reflect::set(&out, &"files".into(), &out_files.into()).map_err(err)?;
    Ok(out.into())
}

/// A bucket whose HTTP lives in JavaScript: `list(prefix)` returns the ListObjectsV2 XML and
/// `get(key)` a `Uint8Array`, both synchronously (sync XHR is allowed in workers), or throw.
struct JsBucket {
    list: Function,
    get: Function,
}

impl JsBucket {
    fn new(bucket: &JsValue) -> Result<JsBucket, JsError> {
        let f = |name: &str| -> Result<Function, JsError> {
            Reflect::get(bucket, &name.into())
                .map_err(err)?
                .dyn_into()
                .map_err(|_| JsError::new(&format!("bucket.{name} is not a function")))
        };
        Ok(JsBucket { list: f("list")?, get: f("get")? })
    }
}

fn js_error(e: JsValue) -> nexrad::Error {
    e.as_string().or_else(|| e.dyn_ref::<js_sys::Error>().map(|e| String::from(e.message()))).unwrap_or_else(|| format!("{e:?}")).into()
}

impl Bucket for JsBucket {
    fn list(&self, prefix: &str) -> nexrad::Result<Vec<String>> {
        let xml = self.list.call1(&JsValue::NULL, &prefix.into()).map_err(js_error)?;
        Ok(archive::parse_listing(&xml.as_string().ok_or("bucket.list: expected a string")?))
    }

    fn get(&self, key: &str) -> nexrad::Result<Vec<u8>> {
        let bytes = self.get.call1(&JsValue::NULL, &key.into()).map_err(js_error)?;
        Ok(bytes.dyn_into::<Uint8Array>().map_err(|_| "bucket.get: expected a Uint8Array")?.to_vec())
    }
}

fn parse_time(s: &str) -> Result<Option<Utc>, JsError> {
    if s.is_empty() { Ok(None) } else { Utc::parse_iso(s).map(Some).map_err(|e| JsError::new(&e.to_string())) }
}

/// Archive keys `nexrad update SITE` would fetch: the newest (all times ""), the one at or
/// before `at`, or every one from `from` to `to` (ISO times, e.g. 2013-05-20T20:00Z).
#[wasm_bindgen]
pub fn resolve_keys(site: &str, at: &str, from: &str, to: &str, bucket: &JsValue) -> Result<Array, JsError> {
    let sel = Selection { at: parse_time(at)?, start: parse_time(from)?, end: parse_time(to)? };
    let keys = archive::resolve_keys(&JsBucket::new(bucket)?, &site.to_uppercase(), &sel).map_err(|e| JsError::new(&e.to_string()))?;
    Ok(keys.iter().map(|k| JsValue::from(k.as_str())).collect())
}

/// The complete archive volumes of `site` from the last `minutes` (the app's live window),
/// oldest first (see `archive::keys_since`): what `live()` backfills before following the chunks
/// bucket, so a partial scan never shows up as if it were the history.
#[wasm_bindgen]
pub fn keys_since(site: &str, minutes: u32, bucket: &JsValue) -> Result<Array, JsError> {
    let now = Utc::now();
    let start = now.add_secs(-60.0 * f64::from(minutes.min(archive::MAX_BACKFILL_MINUTES)));
    let keys = archive::keys_since(&JsBucket::new(bucket)?, &site.to_uppercase(), start, now).map_err(|e| JsError::new(&e.to_string()))?;
    Ok(keys.iter().map(|k| JsValue::from(k.as_str())).collect())
}

/// `nexrad live SITE` against the chunks bucket: each time the in-progress volume grows,
/// `emit({name, volume_json, files, complete})` is called; `log(line)` gets the CLI's status
/// lines. `sleep()` runs between polls and returns false to stop. Blocks until then.
/// `hint_volume` / `hint_time_ms` = where the ring was last time (see `chunks::Start::Newest`),
/// and `remember(volume, time_ms)` is told each volume as it begins, for the next run's hint.
/// `prior_json` / `prior_files` (DVEL files suffice, as `redealias()` takes them) seed the
/// temporal dealiasing reference from a volume decoded outside this call (a backfilled archive
/// volume, typically), so the first followed volume dealiases against it too, not from scratch.
#[wasm_bindgen]
#[allow(clippy::too_many_arguments)]
pub fn live(
    site: &str,
    bucket: &JsValue,
    sleep: &Function,
    emit: &Function,
    log: &Function,
    hint_volume: Option<u32>,
    hint_time_ms: Option<f64>,
    remember: &Function,
    prior_json: Option<String>,
    prior_files: Option<Map>,
) -> Result<(), JsError> {
    let bucket = JsBucket::new(bucket)?;
    // The last complete volume's DVEL, the temporal dealiasing reference of the next one (as
    // `nexrad live` finds it on disk); seeded from `prior_json`/`prior_files` when given.
    let mut prior: Vec<volume::PriorTilt> = Vec::new();
    let mut prior_time: Option<Utc> = None;
    if let (Some(json), Some(files)) = (prior_json, prior_files) {
        let meta = volume::parse_meta(&json).map_err(|e| JsError::new(&e.to_string()))?;
        if meta.complete {
            let get = |name: &str| files.get(&name.into()).dyn_into::<Uint8Array>().ok().map(|a| a.to_vec());
            prior = volume::prior_tilts(&meta, get);
            prior_time = Some(Utc::parse_iso(&meta.time).map_err(|e| JsError::new(&e.to_string()))?);
        }
    }
    // Guards against reporting the exact volume the seed already covers a second time (the
    // archive mirror caught up to the chunk before live started).
    let seed_time = prior_time;
    let mut sink = |vol: &Volume| -> nexrad::Result<String> {
        let name = volume::volume_dir_name(&vol.icao, vol.time);
        if vol.complete && seed_time == Some(vol.time) {
            return Ok(name);
        }
        let fresh = prior_time.is_some_and(|t| volume::is_prior(&vol.icao, vol.time, &vol.icao, t));
        let (out, enc) = encode(vol, if fresh { &prior } else { &[] }).map_err(|e| format!("{:?}", JsValue::from(e)))?;
        if vol.complete {
            prior = enc.prior();
            prior_time = Some(vol.time);
        }
        Reflect::set(&out, &"complete".into(), &vol.complete.into()).map_err(js_error)?;
        emit.call1(&JsValue::NULL, &out).map_err(js_error)?;
        Ok(name)
    };
    let sleep = || sleep.call0(&JsValue::NULL).map(|v| v.is_truthy()).unwrap_or(false);
    let mut log = LineWriter { log, buf: Vec::new() };
    let hint = hint_volume.zip(hint_time_ms).map(|(v, t)| (v, Utc(t as i64)));
    let start = chunks::Start::Newest { hint, now: Utc(Date::now() as i64) };
    let mut remember = |v: u32, t: Utc| {
        let _ = remember.call2(&JsValue::NULL, &v.into(), &(t.0 as f64).into());
    };
    chunks::live(&bucket, site, &mut sink, start, &mut remember, sleep, &mut log).map_err(|e| JsError::new(&e.to_string()))
}

/// Passes each complete line written to it to a JS function.
struct LineWriter<'a> {
    log: &'a Function,
    buf: Vec<u8>,
}

impl std::io::Write for LineWriter<'_> {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        self.buf.extend_from_slice(data);
        while let Some(i) = self.buf.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = self.buf.drain(..=i).collect();
            let _ = self.log.call1(&JsValue::NULL, &String::from_utf8_lossy(&line[..i]).as_ref().into());
        }
        Ok(data.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn err(e: JsValue) -> JsError {
    JsError::new(&format!("{e:?}"))
}

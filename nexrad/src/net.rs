//! HTTP for the native build: anonymous S3 listing/reads and plain downloads (ureq).

use crate::archive::{Bucket, parse_listing};
use crate::{Error, Result};

const TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);
/// Well above any archive file (~10 MB) or basemap zip.
const MAX_BODY: u64 = 1 << 32;

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder().timeout_global(Some(TIMEOUT)).build().into()
}

pub fn get_bytes(url: &str) -> Result<Vec<u8>> {
    let mut resp = agent().get(url).call().map_err(|e| Error::from(format!("GET {url}: {e}")))?;
    resp.body_mut().with_config().limit(MAX_BODY).read_to_vec().map_err(|e| format!("GET {url}: {e}").into())
}

pub struct HttpBucket {
    pub base: String,
}

impl HttpBucket {
    pub fn new(base: &str) -> HttpBucket {
        HttpBucket { base: base.trim_end_matches('/').to_string() }
    }
}

impl Bucket for HttpBucket {
    fn list(&self, prefix: &str) -> Result<Vec<String>> {
        let mut resp = agent()
            .get(&self.base)
            .query("list-type", "2")
            .query("prefix", prefix)
            .query("max-keys", "1000")
            .call()
            .map_err(|e| Error::from(format!("list {}/{prefix}: {e}", self.base)))?;
        let xml = resp
            .body_mut()
            .with_config()
            .limit(MAX_BODY)
            .read_to_string()
            .map_err(|e| Error::from(format!("list {}/{prefix}: {e}", self.base)))?;
        Ok(parse_listing(&xml))
    }

    fn get(&self, key: &str) -> Result<Vec<u8>> {
        get_bytes(&format!("{}/{key}", self.base))
    }
}

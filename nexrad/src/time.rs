//! UTC instants at millisecond precision, with the few conversions the pipeline needs
//! (NEXRAD modified Julian dates, ISO 8601 in and out, S3 key stamps). No time zones.

use std::fmt;

use crate::{Error, Result};

const MS_PER_DAY: i64 = 86_400_000;

/// Milliseconds since 1970-01-01T00:00:00Z.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug, Default)]
pub struct Utc(pub i64);

/// A calendar day (proleptic Gregorian).
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct Date {
    pub year: i32,
    pub month: u32,
    pub day: u32,
}

/// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
pub fn days_from_civil(y: i32, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y } as i64;
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m as i64 + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Civil date for days since 1970-01-01.
pub fn civil_from_days(z: i64) -> (i32, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    ((if m <= 2 { y + 1 } else { y }) as i32, m, d)
}

impl Date {
    pub fn new(year: i32, month: u32, day: u32) -> Date {
        Date { year, month, day }
    }

    pub fn days(self) -> i64 {
        days_from_civil(self.year, self.month, self.day)
    }

    pub fn from_days(days: i64) -> Date {
        let (year, month, day) = civil_from_days(days);
        Date { year, month, day }
    }

    pub fn add_days(self, n: i64) -> Date {
        Date::from_days(self.days() + n)
    }

    /// `YYYY/MM/DD`, the archive bucket's prefix form.
    pub fn slashed(self) -> String {
        format!("{:04}/{:02}/{:02}", self.year, self.month, self.day)
    }
}

impl Utc {
    pub fn from_ymd_hms(y: i32, mo: u32, d: u32, h: u32, mi: u32, s: u32) -> Utc {
        Utc(days_from_civil(y, mo, d) * MS_PER_DAY + ((h as i64 * 60 + mi as i64) * 60 + s as i64) * 1000)
    }

    /// NEXRAD "modified Julian date": days since 1 Jan 1970 where 1 == 1970-01-01, plus
    /// milliseconds past midnight.
    pub fn from_nexrad(days: u32, ms: u32) -> Utc {
        Utc((days as i64 - 1) * MS_PER_DAY + ms as i64)
    }

    pub fn to_nexrad(self) -> (u32, u32) {
        (self.days() as u32 + 1, self.ms_of_day() as u32)
    }

    pub fn now() -> Utc {
        let d = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
        Utc(d.as_millis() as i64)
    }

    pub fn days(self) -> i64 {
        self.0.div_euclid(MS_PER_DAY)
    }

    fn ms_of_day(self) -> i64 {
        self.0.rem_euclid(MS_PER_DAY)
    }

    pub fn date(self) -> Date {
        Date::from_days(self.days())
    }

    pub fn add_secs(self, s: f64) -> Utc {
        Utc(self.0 + (s * 1000.0).round() as i64)
    }

    pub fn add_ms(self, ms: i64) -> Utc {
        Utc(self.0 + ms)
    }

    /// Seconds from `other` to `self`.
    pub fn secs_since(self, other: Utc) -> f64 {
        (self.0 - other.0) as f64 / 1000.0
    }

    fn parts(self) -> (i32, u32, u32, u32, u32, u32, u32) {
        let (y, m, d) = civil_from_days(self.days());
        let ms = self.ms_of_day();
        let s = ms / 1000;
        (y, m, d, (s / 3600) as u32, (s / 60 % 60) as u32, (s % 60) as u32, (ms % 1000) as u32)
    }

    /// Python's `datetime.isoformat()` for an aware UTC time: `2013-05-20T20:03:59+00:00`,
    /// with `.ffffff` microseconds when the time is not a whole second.
    pub fn isoformat(self) -> String {
        let (y, mo, d, h, mi, s, ms) = self.parts();
        if ms == 0 {
            format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}+00:00")
        } else {
            format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}.{:06}+00:00", ms * 1000)
        }
    }

    /// `YYYYMMDD_HHMMSS`, as in volume directory names.
    pub fn compact(self) -> String {
        let (y, mo, d, h, mi, s, _) = self.parts();
        format!("{y:04}{mo:02}{d:02}_{h:02}{mi:02}{s:02}")
    }

    /// `YYYYMMDD-HHMMSS`, as in chunk keys.
    pub fn stamp(self) -> String {
        let (y, mo, d, h, mi, s, _) = self.parts();
        format!("{y:04}{mo:02}{d:02}-{h:02}{mi:02}{s:02}")
    }

    /// Parses `YYYYMMDD` + `HHMMSS` digit strings (separator ignored).
    pub fn parse_compact(s: &str) -> Option<Utc> {
        let b = s.as_bytes();
        if b.len() != 15 || !b[..8].iter().chain(&b[9..]).all(u8::is_ascii_digit) {
            return None;
        }
        let n = |a: usize, e: usize| s[a..e].parse::<u32>().ok();
        let (y, mo, d) = (n(0, 4)?, n(4, 6)?, n(6, 8)?);
        let (h, mi, sec) = (n(9, 11)?, n(11, 13)?, n(13, 15)?);
        if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || sec > 60 {
            return None;
        }
        Some(Utc::from_ymd_hms(y as i32, mo, d, h, mi, sec))
    }

    /// ISO 8601 as users type it: `2013-05-20T20:00Z`, `2013-05-20T20:00:00+00:00`,
    /// `2013-05-20 20:00` (naive means UTC). Seconds and fractions are optional.
    pub fn parse_iso(s: &str) -> Result<Utc> {
        let s = s.trim();
        let bad = || Error::from(format!("cannot parse time {s:?} (want e.g. 2013-05-20T20:00Z)"));
        let (date, rest) = s.split_once(['T', ' ']).unwrap_or((s, ""));
        let mut dp = date.split('-');
        let (y, mo, d) = (
            dp.next().and_then(|v| v.parse::<i32>().ok()).ok_or_else(bad)?,
            dp.next().and_then(|v| v.parse::<u32>().ok()).ok_or_else(bad)?,
            dp.next().and_then(|v| v.parse::<u32>().ok()).ok_or_else(bad)?,
        );
        if dp.next().is_some() || !(1..=12).contains(&mo) || !(1..=31).contains(&d) {
            return Err(bad());
        }
        // Split off a zone suffix: Z, or +HH:MM / -HH:MM.
        let (time, offset_ms) = if let Some(t) = rest.strip_suffix(['Z', 'z']) {
            (t, 0)
        } else if let Some(i) = rest.rfind(['+', '-']) {
            let (t, z) = rest.split_at(i);
            let sign = if z.starts_with('-') { -1 } else { 1 };
            let mut zp = z[1..].split(':');
            let zh = zp.next().and_then(|v| v.parse::<i64>().ok()).ok_or_else(bad)?;
            let zm = zp.next().map(|v| v.parse::<i64>()).transpose().map_err(|_| bad())?.unwrap_or(0);
            (t, sign * (zh * 60 + zm) * 60_000)
        } else {
            (rest, 0)
        };
        let mut ms = 0i64;
        if !time.is_empty() {
            let mut tp = time.split(':');
            let h = tp.next().and_then(|v| v.parse::<i64>().ok()).ok_or_else(bad)?;
            let mi = tp.next().map(|v| v.parse::<i64>()).transpose().map_err(|_| bad())?.unwrap_or(0);
            let sec = tp.next().map(|v| v.parse::<f64>()).transpose().map_err(|_| bad())?.unwrap_or(0.0);
            if tp.next().is_some() || h > 23 || mi > 59 || !(0.0..61.0).contains(&sec) {
                return Err(bad());
            }
            ms = ((h * 60 + mi) * 60) * 1000 + (sec * 1000.0).round() as i64;
        }
        Ok(Utc(days_from_civil(y, mo, d) * MS_PER_DAY + ms - offset_ms))
    }
}

impl fmt::Display for Utc {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.isoformat())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn civil_round_trip() {
        for days in [-1_000_000, -1, 0, 1, 19_000, 25_000, 100_000] {
            let (y, m, d) = civil_from_days(days);
            assert_eq!(days_from_civil(y, m, d), days);
        }
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(Date::new(2024, 5, 1).add_days(-1), Date::new(2024, 4, 30));
        assert_eq!(Date::new(2024, 2, 28).add_days(1).slashed(), "2024/02/29");
    }

    #[test]
    fn nexrad_dates() {
        assert_eq!(Utc::from_nexrad(1, 0), Utc::from_ymd_hms(1970, 1, 1, 0, 0, 0));
        let t = Utc::from_ymd_hms(2013, 5, 20, 20, 3, 59).add_ms(250);
        let (days, ms) = t.to_nexrad();
        assert_eq!(Utc::from_nexrad(days, ms), t);
        assert_eq!(t.isoformat(), "2013-05-20T20:03:59.250000+00:00");
        assert_eq!(t.compact(), "20130520_200359");
        assert_eq!(t.stamp(), "20130520-200359");
    }

    #[test]
    fn iso_parsing() {
        let want = Utc::from_ymd_hms(2013, 5, 20, 20, 0, 0);
        for s in [
            "2013-05-20T20:00Z",
            " 2013-05-20T20:00 ",
            "2013-05-20T20:00:00+00:00",
            "2013-05-20 21:00+01:00",
            "2013-05-20T15:00:00.000-05:00",
        ] {
            assert_eq!(Utc::parse_iso(s).unwrap(), want, "{s}");
        }
        assert_eq!(Utc::parse_iso("2013-05-20").unwrap(), Utc::from_ymd_hms(2013, 5, 20, 0, 0, 0));
        assert!(Utc::parse_iso("20:00").is_err());
        assert!(Utc::parse_iso("2013-13-01").is_err());
        assert_eq!(Utc::parse_compact("20240501_220013"), Some(Utc::from_ymd_hms(2024, 5, 1, 22, 0, 13)));
        assert_eq!(Utc::parse_compact("2024050122001"), None);
    }
}

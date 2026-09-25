//! Serde helpers that mirror Swift's `Data` ↔ base64 JSON encoding.
//!
//! Swift's `JSONEncoder`/`JSONDecoder` represent `Data` as a base64
//! **string**, so every `Data` field on the wire (H.264 SPS/PPS, Opus
//! payloads, app-icon PNGs, window snapshots) is a base64 string here too.
//! We use the `base64` crate's STANDARD engine, which matches
//! `Data.base64EncodedString()` (padded standard alphabet).

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use serde::{Deserialize, Deserializer, Serializer};

/// `Vec<u8>` ↔ base64 string.
pub fn serialize<S>(bytes: &[u8], serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    serializer.serialize_str(&STANDARD.encode(bytes))
}

pub fn deserialize<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
where
    D: Deserializer<'de>,
{
    let s = String::deserialize(deserializer)?;
    STANDARD.decode(s).map_err(serde::de::Error::custom)
}

/// `Option<Vec<u8>>` ↔ base64 string (or null / absent).
pub mod opt {
    use super::*;

    pub fn serialize<S>(value: &Option<Vec<u8>>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match value {
            Some(bytes) => serializer.serialize_str(&STANDARD.encode(bytes)),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Option<Vec<u8>>, D::Error>
    where
        D: Deserializer<'de>,
    {
        match Option::<String>::deserialize(deserializer)? {
            Some(s) => STANDARD
                .decode(s)
                .map(Some)
                .map_err(serde::de::Error::custom),
            None => Ok(None),
        }
    }
}

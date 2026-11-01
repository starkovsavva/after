//! Source identity independent of storage, AI runtime and operating system.
use super::workspace::CapturedNote;
use sha2::{Digest, Sha256};

pub(crate) fn note_fingerprint(note: &CapturedNote) -> String {
    let value = serde_json::to_value(note).expect("serializable note");
    format!("{:x}", Sha256::digest(value.to_string().as_bytes()))
}

//! Existing library directory identity contract; no filesystem interpretation.
pub(crate) fn valid(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .bytes()
            .all(|value| value.is_ascii_alphanumeric() || value == b'-' || value == b'_')
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn legacy_identifiers_are_preserved_without_accepting_paths_or_aliases() {
        for id in [
            "Meeting_2026-11-03",
            "ABCDEF12-3456-4789-ABCD-123456789ABC",
            "team-sync",
            "-",
        ] {
            assert!(valid(id));
        }
        for id in [
            "",
            ".",
            "..",
            "../outside",
            "/absolute",
            "a/b",
            "a\\b",
            "source.wav",
            "a%2fb",
            "with space",
            "\0",
            "встреча",
        ] {
            assert!(!valid(id), "{id:?}");
        }
        assert!(valid(&"x".repeat(128)));
        assert!(!valid(&"x".repeat(129)));
    }
}

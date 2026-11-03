//! Prepare private local work from host-selected persisted settings and source
//! revision. No queue write, inference, runtime installation or readiness claim.
use super::speech_work::SpeechWork;
use anyhow::{ensure, Result};
use serde_json::Value;

pub(crate) trait SpeechInputs {
    fn settings(&self) -> Result<Value>;
    fn revision(&self, meeting: &str) -> Result<String>;
    fn identity(&self) -> String;
}
pub(crate) fn prepare(port: &impl SpeechInputs, meeting: &str) -> Result<SpeechWork> {
    ensure!(
        crate::domain::meeting_ids::valid(meeting),
        "Invalid meeting identity"
    );
    let settings = crate::domain::speech_settings::local_snapshot(&port.settings()?)?;
    let work = SpeechWork {
        version: 1,
        operation_id: port.identity(),
        attempt_token: port.identity(),
        meeting_id: meeting.into(),
        input_revision: port.revision(meeting)?,
        settings,
    };
    work.validate()?;
    Ok(work)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    struct Inputs {
        settings: RefCell<Value>,
        revision: RefCell<String>,
    }
    impl SpeechInputs for Inputs {
        fn settings(&self) -> Result<Value> {
            Ok(self.settings.borrow().clone())
        }
        fn revision(&self, _: &str) -> Result<String> {
            Ok(self.revision.borrow().clone())
        }
        fn identity(&self) -> String {
            uuid::Uuid::new_v4().to_string()
        }
    }
    #[test]
    fn prepared_selection_and_revision_are_immutable_and_identities_are_fresh() {
        let port = Inputs {
            settings: RefCell::new(
                serde_json::json!({"speechMode":"local","diarization":false,"asrModelPath":"/selected"}),
            ),
            revision: RefCell::new("a".repeat(64)),
        };
        let meeting = uuid::Uuid::new_v4().to_string();
        let one = prepare(&port, &meeting).unwrap();
        let two = prepare(&port, &meeting).unwrap();
        assert_ne!(one.operation_id, two.operation_id);
        assert_ne!(one.attempt_token, two.attempt_token);
        *port.settings.borrow_mut() = serde_json::json!({"speechMode":"cloud"});
        *port.revision.borrow_mut() = "b".repeat(64);
        assert_eq!(one.settings["speechMode"], "local");
        assert_eq!(one.input_revision, "a".repeat(64));
        assert!(prepare(&port, &meeting).is_err());
    }
    #[test]
    fn legacy_meeting_identity_is_preserved_in_prepared_work() {
        let port = Inputs {
            settings: RefCell::new(serde_json::json!({"speechMode":"local","diarization":false,"asrModelPath":"/selected/model"})),
            revision: RefCell::new("a".repeat(64)),
        };
        for meeting in ["Meeting_2026-11-03", "ABCDEF12-3456-4789-ABCD-123456789ABC"] {
            let mut work = prepare(&port, meeting).unwrap();
            assert_eq!(work.meeting_id, meeting);
            work.attempt_token = "legacy-attempt".into();
            assert!(work.validate().is_err());
        }
    }
    #[test]
    fn invalid_meeting_never_reads_private_settings() {
        struct Never;
        impl SpeechInputs for Never {
            fn settings(&self) -> Result<Value> {
                panic!("unexpected settings read")
            }
            fn revision(&self, _: &str) -> Result<String> {
                panic!("unexpected source read")
            }
            fn identity(&self) -> String {
                panic!("unexpected identity allocation")
            }
        }
        for meeting in ["../outside", "", "source.wav"] {
            assert!(prepare(&Never, meeting).is_err());
        }
    }
}

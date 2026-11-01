//! One leased native queue connection. EOF releases ownership; the persistent
//! helper is supervised by the host. No automatic recovery or worker spawning.
use anyhow::{ensure, Result};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Read, Write},
    path::Path,
};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    version: u8,
    id: String,
    request: Value,
}

fn frame(output: &mut impl Write, value: Value) -> Result<()> {
    serde_json::to_writer(&mut *output, &value)?;
    output.write_all(b"\n")?;
    output.flush()?;
    Ok(())
}

pub fn run_stdio(root: &Path, reader: impl Read, mut writer: impl Write) -> Result<()> {
    ensure!(
        root.is_absolute()
            && !root.components().any(|part| matches!(
                part,
                std::path::Component::ParentDir | std::path::Component::CurDir
            )),
        "Invalid private library root"
    );
    let lease = match crate::infrastructure::executor_lease::try_acquire(root) {
        Ok(Some(lease)) => lease,
        outcome => {
            let code = if outcome.is_ok() {
                "busy"
            } else {
                "library_error"
            };
            frame(
                &mut writer,
                json!({"version":1,"event":"unavailable","code":code}),
            )?;
            return Ok(());
        }
    };
    frame(&mut writer, json!({"version":1,"event":"ready"}))?;
    let mut input = BufReader::new(reader);
    loop {
        let mut bytes = Vec::new();
        Read::by_ref(&mut input)
            .take((crate::desktop::MAX_REQUEST_BYTES + 1) as u64)
            .read_until(b'\n', &mut bytes)?;
        if bytes.is_empty() {
            return Ok(());
        }
        ensure!(
            bytes.len() <= crate::desktop::MAX_REQUEST_BYTES && bytes.ends_with(b"\n"),
            "Invalid queue frame"
        );
        let request: Request = serde_json::from_slice(&bytes)?;
        ensure!(
            request.version == 1 && crate::desktop_import::valid_import_id(&request.id),
            "Invalid queue request"
        );
        let envelope = crate::desktop::import_queue_envelope(&lease, request.request);
        frame(
            &mut writer,
            json!({"version":1,"event":"reply","id":request.id,"envelope":envelope}),
        )?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn service_releases_lease_at_eof_and_reports_contention_without_queue_writes() {
        let root = tempfile::tempdir().unwrap();
        let lease = crate::infrastructure::executor_lease::try_acquire(root.path())
            .unwrap()
            .unwrap();
        let mut output = Vec::new();
        run_stdio(root.path(), &b""[..], &mut output).unwrap();
        assert_eq!(
            serde_json::from_slice::<Value>(&output).unwrap()["code"],
            "busy"
        );
        assert!(!root.path().join("jobs.sqlite").exists());
        drop(lease);
        output.clear();
        run_stdio(root.path(), &b""[..], &mut output).unwrap();
        assert_eq!(
            serde_json::from_slice::<Value>(&output).unwrap()["event"],
            "ready"
        );
        assert!(
            crate::infrastructure::executor_lease::try_acquire(root.path())
                .unwrap()
                .is_some()
        );
    }

    #[test]
    fn invalid_frames_release_ownership_and_never_dispatch_arbitrary_commands() {
        let root = tempfile::tempdir().unwrap();
        for input in [
            b"{}".to_vec(),
            vec![b'x'; crate::desktop::MAX_REQUEST_BYTES + 1],
            b"{\"version\":1,\"id\":\"../escape\",\"request\":{}}\n".to_vec(),
        ] {
            assert!(run_stdio(root.path(), &input[..], Vec::new()).is_err());
            assert!(
                crate::infrastructure::executor_lease::try_acquire(root.path())
                    .unwrap()
                    .is_some()
            );
        }
        assert!(!root.path().join("jobs.sqlite").exists());
    }

    #[test]
    fn replies_preserve_identity_and_invalid_actions_do_not_close_the_owner() {
        let root = tempfile::tempdir().unwrap();
        let first = uuid::Uuid::new_v4().to_string();
        let second = uuid::Uuid::new_v4().to_string();
        let input = format!(
            "{}\n{}\n",
            json!({"version":1,"id":first,"request":{"action":"execute","command":"delete"}}),
            json!({"version":1,"id":second,"request":{"action":"list"}})
        );
        let mut output = Vec::new();
        run_stdio(root.path(), input.as_bytes(), &mut output).unwrap();
        let frames: Vec<Value> = output
            .split(|byte| *byte == b'\n')
            .filter(|line| !line.is_empty())
            .map(|line| serde_json::from_slice(line).unwrap())
            .collect();
        assert_eq!(frames.len(), 3);
        assert_eq!(frames[0]["event"], "ready");
        assert_eq!(frames[1]["id"], first);
        assert_eq!(frames[1]["envelope"]["ok"], false);
        assert_eq!(frames[2]["id"], second);
        assert_eq!(frames[2]["envelope"]["result"]["total"], 0);
        assert!(
            crate::infrastructure::executor_lease::try_acquire(root.path())
                .unwrap()
                .is_some()
        );
    }

    #[test]
    fn metadata_transport_cannot_bypass_lifetime_ownership() {
        let root = tempfile::tempdir().unwrap();
        let reply = crate::desktop::handle_bytes(
            root.path(),
            br#"{"command":"import_queue","arguments":{"action":"recover"}}"#,
        );
        assert_eq!(reply["error"]["code"], "unsupported_command");
        assert!(!root.path().join("jobs.sqlite").exists());
    }
}

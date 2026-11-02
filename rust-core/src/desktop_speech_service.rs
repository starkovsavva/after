//! Persistent native speech queue connection. EOF cancels and joins work before
//! releasing ownership. Startup reconciles receipts; it never resumes inference.
use anyhow::{ensure, Result};
use serde_json::json;
use std::{
    io::{Read, Write},
    path::Path,
    sync::Arc,
};
pub fn run_stdio(
    root: &Path,
    backend: &Path,
    reader: impl Read,
    mut writer: impl Write,
) -> Result<()> {
    crate::infrastructure::runtime_tree::absolute(root)?;
    ensure!(backend.is_absolute(), "Speech backend must be absolute");
    let Some(lease) = crate::infrastructure::executor_lease::try_acquire_speech(root)? else {
        crate::infrastructure::native_queue_transport::frame(
            &mut writer,
            json!({"version":1,"event":"unavailable","code":"busy"}),
        )?;
        return Ok(());
    };
    let lease = Arc::new(lease);
    let worker = Arc::new(crate::infrastructure::speech_process::NativeSpeechProcess {
        lease: lease.clone(),
        engine: std::env::current_exe()?,
        backend: backend.to_owned(),
    });
    let mut executor = crate::desktop_speech_queue::Executor::new(lease, worker)?;
    crate::infrastructure::native_queue_transport::frame(
        &mut writer,
        json!({"version":1,"event":"ready"}),
    )?;
    crate::infrastructure::native_queue_transport::serve(reader, writer, |request| {
        let result = serde_json::from_value(request)
            .map_err(Into::into)
            .and_then(|request| executor.command(request));
        match result {
            Ok(result) => json!({"ok":true,"result":result}),
            Err(_) => {
                json!({"ok":false,"error":{"code":"speech_queue_error","message":"Speech work could not be updated. Existing data was preserved."}})
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn metadata_transport_cannot_open_speech_ownership_and_busy_scope_has_no_queue_writes() {
        let root = tempfile::tempdir().unwrap();
        let reply = crate::desktop::handle_bytes(
            root.path(),
            br#"{"command":"speech_queue","arguments":{"action":"reconcile"}}"#,
        );
        assert_eq!(reply["error"]["code"], "unsupported_command");
        assert!(!root.path().join("jobs.sqlite").exists());
        let _lease = crate::infrastructure::executor_lease::try_acquire_speech(root.path())
            .unwrap()
            .unwrap();
        let mut out = Vec::new();
        run_stdio(
            root.path(),
            Path::new("/unused/backend"),
            &b""[..],
            &mut out,
        )
        .unwrap();
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&out).unwrap()["code"],
            "busy"
        );
        assert!(!root.path().join("jobs.sqlite").exists());
    }
    #[test]
    fn invalid_command_is_closed_and_eof_releases_the_native_owner() {
        let root = tempfile::tempdir().unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        let input = format!(
            "{}\n",
            json!({"version":1,"id":id,"request":{"action":"run","jobId":"anything","command":"summarize"}})
        );
        let mut out = Vec::new();
        run_stdio(
            root.path(),
            Path::new("/unused/backend"),
            input.as_bytes(),
            &mut out,
        )
        .unwrap();
        let replies: Vec<serde_json::Value> = out
            .split(|v| *v == b'\n')
            .filter(|v| !v.is_empty())
            .map(|v| serde_json::from_slice(v).unwrap())
            .collect();
        assert_eq!(replies.len(), 2);
        assert_eq!(replies[0]["event"], "ready");
        assert_eq!(replies[1]["envelope"]["ok"], false);
        assert!(
            crate::infrastructure::executor_lease::try_acquire_speech(root.path())
                .unwrap()
                .is_some()
        );
    }
}

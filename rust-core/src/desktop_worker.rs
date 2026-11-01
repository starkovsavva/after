//! Private streaming import transport for the native WorkerHost. No renderer
//! command forwarding, provider configuration or arbitrary executable is accepted.
use crate::application::import_ports::ImportInput;
use crate::application::imports::{ImportCancelled, ImportObserver, ImportPhase, ImportProgress};
use anyhow::{ensure, Result};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    io::{self, BufRead, BufReader, Read, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    version: u8,
    operation_id: String,
    attempt_token: String,
    source_path: PathBuf,
    title: Option<String>,
}

fn line(input: &mut impl BufRead, limit: usize) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    input
        .take((limit + 1) as u64)
        .read_until(b'\n', &mut bytes)?;
    if bytes.len() > limit || !bytes.ends_with(b"\n") {
        return Err(io::Error::other("Invalid worker frame"));
    }
    Ok(bytes)
}

struct Observer<'a, W> {
    request: &'a Request,
    output: &'a mut W,
    cancelled: Arc<AtomicBool>,
    last: Option<Instant>,
}
fn frame(output: &mut impl Write, request: &Request, payload: Value) -> Result<()> {
    serde_json::to_writer(
        &mut *output,
        &json!({"version":1,"operationId":request.operation_id,
        "attemptToken":request.attempt_token,"payload":payload}),
    )?;
    output.write_all(b"\n")?;
    output.flush()?;
    Ok(())
}
impl<W: Write> ImportObserver for Observer<'_, W> {
    fn checkpoint(&mut self, progress: ImportProgress) -> Result<()> {
        if self.cancelled.load(Ordering::Acquire) {
            return Err(ImportCancelled.into());
        }
        if progress.phase == ImportPhase::Committing
            || self
                .last
                .is_none_or(|last| last.elapsed() >= Duration::from_millis(100))
        {
            frame(
                self.output,
                self.request,
                json!({"event":"progress","progress":progress}),
            )?;
            self.last = Some(Instant::now());
        }
        Ok(())
    }
}

pub fn run_stdio(root: &Path) -> Result<()> {
    ensure!(root.is_absolute(), "Invalid library root");
    let mut input = BufReader::new(io::stdin());
    let request: Request = serde_json::from_slice(&line(&mut input, 256 * 1024)?)?;
    ensure!(request.version == 1, "Invalid import request version");
    ImportInput {
        operation_id: request.operation_id.clone(),
        attempt_token: request.attempt_token.clone(),
        source_path: request.source_path.clone(),
        title: request.title.clone(),
    }
    .validate()?;
    let cancelled = Arc::new(AtomicBool::new(false));
    let cancellation = cancelled.clone();
    std::thread::Builder::new()
        .name("after-import-control".into())
        .spawn(move || {
            // EOF or any invalid control frame also closes admission to publication.
            let _ = line(&mut input, 64);
            cancellation.store(true, Ordering::Release);
        })?;
    let mut output = io::stdout().lock();
    let mut observer = Observer {
        request: &request,
        output: &mut output,
        cancelled,
        last: None,
    };
    let result = crate::desktop_import::import_observed(
        root,
        &request.source_path,
        "",
        request.title.as_deref(),
        Some(crate::desktop_import::ImportControl {
            operation: &request.operation_id,
            token: &request.attempt_token,
            observer: &mut observer,
        }),
    );
    let payload = match result {
        Ok(meta) => json!({"event":"committed","meeting":crate::desktop::import_dto(root, &meta)}),
        Err(error) if error.is::<ImportCancelled>() => json!({"event":"cancelled"}),
        Err(_) => json!({"event":"failed"}),
    };
    frame(&mut output, &request, payload)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn request_schema_cannot_forward_commands_or_provider_configuration() {
        let mut value = json!({"version":1,"operationId":uuid::Uuid::new_v4().to_string(),
            "attemptToken":uuid::Uuid::new_v4().to_string(),"sourcePath":"/synthetic.wav","title":null});
        assert!(serde_json::from_value::<Request>(value.clone()).is_ok());
        value["command"] = json!("summarize");
        assert!(serde_json::from_value::<Request>(value).is_err());
    }
    #[test]
    fn input_frames_are_bounded_and_must_be_complete() {
        for bytes in [b"{}".to_vec(), vec![b'x'; 66]] {
            assert!(line(&mut std::io::Cursor::new(bytes), 64).is_err());
        }
        assert_eq!(
            line(&mut std::io::Cursor::new(b"cancel\n"), 64).unwrap(),
            b"cancel\n"
        );
    }
}

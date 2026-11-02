//! Bounded native queue framing. Domain commands and lifetime owners are injected.
use anyhow::{ensure, Result};
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    version: u8,
    id: String,
    request: Value,
}
pub(crate) fn frame(output: &mut impl Write, value: Value) -> Result<()> {
    let bytes = serde_json::to_vec(&value)?;
    ensure!(
        bytes.len() <= 8 * 1024 * 1024 + 1024,
        "Native queue response exceeds its bound"
    );
    output.write_all(&bytes)?;
    output.write_all(b"\n")?;
    output.flush()?;
    Ok(())
}
pub(crate) fn serve(
    reader: impl Read,
    mut output: impl Write,
    mut dispatch: impl FnMut(Value) -> Value,
) -> Result<()> {
    let mut input = BufReader::new(reader);
    loop {
        let mut bytes = Vec::new();
        Read::by_ref(&mut input)
            .take(256 * 1024 + 1)
            .read_until(b'\n', &mut bytes)?;
        if bytes.is_empty() {
            return Ok(());
        }
        ensure!(
            bytes.len() <= 256 * 1024 && bytes.ends_with(b"\n"),
            "Invalid native queue frame"
        );
        let request: Request = serde_json::from_slice(&bytes)?;
        ensure!(
            request.version == 1
                && request.id.len() == 36
                && uuid::Uuid::parse_str(&request.id).is_ok(),
            "Invalid native queue request"
        );
        let envelope = dispatch(request.request);
        frame(
            &mut output,
            json!({"version":1,"event":"reply","id":request.id,"envelope":envelope}),
        )?;
    }
}

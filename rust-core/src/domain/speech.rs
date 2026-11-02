//! Pure validation of a worker transcription before canonical publication.
use anyhow::{ensure, Context, Result};
use serde_json::Value;
pub(crate) fn validate_transcript(transcript: &Value) -> Result<()> {
    let duration = transcript["duration"]
        .as_f64()
        .context("Invalid speech duration")?;
    ensure!(
        duration.is_finite() && duration >= 0.,
        "Invalid speech duration"
    );
    let segments = transcript["segments"]
        .as_array()
        .context("Invalid speech segments")?;
    ensure!(segments.len() <= 100_000, "Too many speech segments");
    for (index, segment) in segments.iter().enumerate() {
        let start = segment["start"].as_f64().context("Invalid segment start")?;
        let end = segment["end"].as_f64().context("Invalid segment end")?;
        ensure!(
            start.is_finite()
                && end.is_finite()
                && start >= 0.
                && end >= start
                && end <= duration + 0.01
                && segment["id"].as_u64() == Some(index as u64)
                && segment["text"].is_string(),
            "Invalid speech segment"
        );
    }
    Ok(())
}

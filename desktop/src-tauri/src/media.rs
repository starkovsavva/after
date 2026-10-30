//! Range-limited playback. A webview can name a meeting ID, never a path.
use crate::{bridge::LibraryBridge, models::validate_id};
use base64::{engine::general_purpose::STANDARD, Engine as _};
use tauri::http::{header, Request, Response, StatusCode};

const CHUNK: u64 = 1_048_576;
fn empty(status: StatusCode) -> Response<Vec<u8>> {
    Response::builder().status(status).header(header::CACHE_CONTROL, "no-store").body(Vec::new()).unwrap()
}
fn requested_range(header: Option<&str>, total: u64) -> Option<(u64, u64)> {
    if total == 0 { return None; }
    let Some(value) = header else { return Some((0, (total - 1).min(CHUNK - 1))); };
    let value = value.strip_prefix("bytes=")?;
    if value.contains(',') { return None; }
    let (first, last) = value.split_once('-')?;
    let (start, end) = if first.is_empty() {
        let suffix = last.parse::<u64>().ok()?;
        if suffix == 0 { return None; }
        (total.saturating_sub(suffix), total - 1)
    } else {
        let start = first.parse::<u64>().ok()?;
        let end = if last.is_empty() { total - 1 } else { last.parse::<u64>().ok()?.min(total - 1) };
        (start, end)
    };
    if start >= total || end < start { return None; }
    Some((start, end.min(start.saturating_add(CHUNK - 1))))
}

pub(crate) fn respond(bridge: &LibraryBridge, request: Request<Vec<u8>>) -> Response<Vec<u8>> {
    if request.method() != tauri::http::Method::GET || request.uri().query().is_some() { return empty(StatusCode::BAD_REQUEST); }
    if let Some(origin) = request.headers().get(header::ORIGIN) {
        let Ok(origin) = origin.to_str() else { return empty(StatusCode::FORBIDDEN); };
        let trusted = ["http://tauri.localhost", "https://tauri.localhost", "tauri://localhost"].contains(&origin)
            || (cfg!(debug_assertions) && origin == "http://127.0.0.1:1420");
        if !trusted { return empty(StatusCode::FORBIDDEN); }
    }
    let Some(id) = request.uri().path().strip_prefix('/') else { return empty(StatusCode::BAD_REQUEST); };
    if validate_id(id).is_err() { return empty(StatusCode::BAD_REQUEST); }
    let header_value = match request.headers().get(header::RANGE) {
        Some(value) => match value.to_str() { Ok(v) => Some(v), Err(_) => return empty(StatusCode::RANGE_NOT_SATISFIABLE) },
        None => None,
    };
    let Ok(info) = bridge.media_chunk(id, 0, 1) else { return empty(StatusCode::NOT_FOUND); };
    if info.meeting_id != id || info.offset != 0 || info.total_bytes == 0 || info.total_bytes > 9_007_199_254_740_991 { return empty(StatusCode::BAD_GATEWAY); }
    let Some((start, end)) = requested_range(header_value, info.total_bytes) else {
        return Response::builder().status(StatusCode::RANGE_NOT_SATISFIABLE).header(header::CONTENT_RANGE, format!("bytes */{}", info.total_bytes)).body(Vec::new()).unwrap();
    };
    let Ok(chunk) = bridge.media_chunk(id, start, (end - start + 1) as u32) else { return empty(StatusCode::BAD_GATEWAY); };
    let Ok(data) = STANDARD.decode(&chunk.data_base64) else { return empty(StatusCode::BAD_GATEWAY); };
    if chunk.meeting_id != id || chunk.offset != start || chunk.total_bytes != info.total_bytes || chunk.content_type != info.content_type || data.len() as u64 != end - start + 1 { return empty(StatusCode::BAD_GATEWAY); }
    let allowed = ["audio/wav", "audio/mpeg", "audio/mp4", "audio/aac", "audio/flac", "audio/ogg", "audio/aiff", "audio/x-caf", "video/mp4", "video/quicktime", "video/webm", "video/x-matroska"];
    if !allowed.contains(&chunk.content_type.as_str()) { return empty(StatusCode::BAD_GATEWAY); }
    let partial = header_value.is_some() || end + 1 != info.total_bytes;
    let mut response = Response::builder().status(if partial { StatusCode::PARTIAL_CONTENT } else { StatusCode::OK })
        .header(header::CONTENT_TYPE, chunk.content_type)
        .header(header::CONTENT_LENGTH, data.len().to_string())
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CACHE_CONTROL, "no-store")
        .header("X-Content-Type-Options", "nosniff");
    if partial { response = response.header(header::CONTENT_RANGE, format!("bytes {start}-{end}/{}", info.total_bytes)); }
    response.body(data).unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn ranges_are_bounded_and_validate_suffixes() {
        assert_eq!(requested_range(Some("bytes=10-"), 100), Some((10, 99)));
        assert_eq!(requested_range(Some("bytes=-4"), 100), Some((96, 99)));
        assert_eq!(requested_range(Some("bytes=0-"), CHUNK * 2), Some((0, CHUNK - 1)));
        for value in ["bytes=100-", "bytes=8-4", "bytes=-0", "bytes=0-1,3-4", "bytes=a-b"] { assert_eq!(requested_range(Some(value), 100), None); }
    }
}

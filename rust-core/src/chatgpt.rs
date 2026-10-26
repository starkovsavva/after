//! ChatGPT plan usage is a distinct credential and billing route. Keep its
//! public endpoint and streaming contract separate from API-key providers.
use anyhow::{bail, Result};
use reqwest::blocking::{Client, RequestBuilder, Response};
use reqwest::StatusCode;
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::io::Read;

pub(crate) const RESPONSES_ENDPOINT: &str = "https://api.openai.com/v1/responses";
const MAX_STREAM_BYTES: usize = 8 * 1024 * 1024;
const MAX_EVENT_BYTES: usize = 1024 * 1024;
const MAX_ANSWER_BYTES: usize = 4 * 1024 * 1024;

/// Payload-free failure details for support and regression checks. Every string
/// is a fixed vocabulary; provider text, IDs, headers and credentials never
/// enter this structure.
#[derive(Clone, Debug, Serialize)]
pub struct ChatGPTDiagnostics {
    pub wire: &'static str,
    pub http_status: u16,
    pub content_type: &'static str,
    pub response_bytes: usize,
    pub events: usize,
    pub output_text_delta: usize,
    pub output_text_done: usize,
    pub content_part_done: usize,
    pub output_item_done: usize,
    pub completed: usize,
    pub other_events: usize,
    pub terminal_status: &'static str,
    pub terminal_output: &'static str,
    pub terminal_output_items: usize,
    pub terminal_text_parts: usize,
    pub terminal_refusal_parts: usize,
    pub terminal_other_parts: usize,
    pub accumulated_text_bytes: usize,
}
impl ChatGPTDiagnostics {
    fn new(wire: &'static str) -> Self {
        Self {
            wire,
            http_status: 0,
            content_type: "missing",
            response_bytes: 0,
            events: 0,
            output_text_delta: 0,
            output_text_done: 0,
            content_part_done: 0,
            output_item_done: 0,
            completed: 0,
            other_events: 0,
            terminal_status: "missing",
            terminal_output: "missing",
            terminal_output_items: 0,
            terminal_text_parts: 0,
            terminal_refusal_parts: 0,
            terminal_other_parts: 0,
            accumulated_text_bytes: 0,
        }
    }
    fn terminal(&mut self, response: &Value) {
        self.terminal_status = match response.get("status").and_then(Value::as_str) {
            Some("completed") => "completed",
            Some("incomplete") => "incomplete",
            Some("failed") => "failed",
            Some("cancelled") => "cancelled",
            Some("queued") => "queued",
            Some("in_progress") => "in_progress",
            None if response.get("status").is_none() => "missing",
            _ => "other",
        };
        self.terminal_output = match response.get("output") {
            Some(Value::Array(items)) => {
                self.terminal_output_items = items.len();
                for part in items
                    .iter()
                    .flat_map(|item| item["content"].as_array().into_iter().flatten())
                {
                    match part["type"].as_str() {
                        Some("output_text") => self.terminal_text_parts += 1,
                        Some("refusal") => self.terminal_refusal_parts += 1,
                        _ => self.terminal_other_parts += 1,
                    }
                }
                "array"
            }
            None => "missing",
            _ => "invalid",
        };
    }
}

#[derive(Debug)]
struct ResponseFailure {
    error: anyhow::Error,
    diagnostics: ChatGPTDiagnostics,
}
impl std::fmt::Display for ResponseFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Display::fmt(&self.error, formatter)
    }
}
impl std::error::Error for ResponseFailure {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(self.error.as_ref())
    }
}
fn with_diagnostics(error: anyhow::Error, diagnostics: ChatGPTDiagnostics) -> anyhow::Error {
    anyhow::Error::new(ResponseFailure { error, diagnostics })
}

/// Callers may save these fixed fields separately from the user-facing error.
pub fn error_diagnostics(error: &anyhow::Error) -> Option<&ChatGPTDiagnostics> {
    error
        .chain()
        .find_map(|cause| cause.downcast_ref::<ResponseFailure>())
        .map(|failure| &failure.diagnostics)
}

pub(crate) fn validate_reasoning(effort: &str) -> Result<()> {
    if ![
        "auto", "none", "minimal", "low", "medium", "high", "xhigh", "max",
    ]
    .contains(&effort)
    {
        bail!("Выберите уровень рассуждений ChatGPT в настройках.");
    }
    Ok(())
}

pub(crate) fn request_body(
    model: &str,
    effort: &str,
    output: &str,
    instructions: &str,
    prompt: &str,
    schema: &Value,
) -> Result<Value> {
    validate_reasoning(effort)?;
    if model.trim().is_empty() || model.chars().any(char::is_control) {
        bail!("Выберите модель из списка ChatGPT.");
    }
    let instructions = if output == "schema" {
        instructions.to_owned()
    } else {
        format!("{instructions}\nReturn exactly one JSON object matching this JSON Schema, with no Markdown or other text:\n{schema}")
    };
    let mut body = json!({
        "model": model.trim(), "store": false, "stream": true,
        "instructions": instructions,
        "input": [{"role": "user", "content": prompt}],
    });
    if effort != "auto" {
        body["reasoning"] = json!({"effort": effort});
    }
    match output {
        "schema" => {
            body["text"] = json!({"format": {"type": "json_schema", "name": "meeting_notes", "strict": true, "schema": schema}})
        }
        "json" => body["text"] = json!({"format": {"type": "json_object"}}),
        "prompt" => {}
        _ => bail!("Выберите формат ответа ChatGPT в настройках."),
    }
    Ok(body)
}

/// Only known machine codes may leave the transport. Arbitrary provider body,
/// diagnostic messages, request IDs and parameter values can contain user data.
fn request_error(status: StatusCode, code: Option<&str>) -> anyhow::Error {
    let (safe_code, hint) = match code {
        Some("subscription_sharing_usage_limit_exceeded") => (
            "subscription_sharing_usage_limit_exceeded",
            "Достигнут лимит использования ChatGPT для приложения. Откройте ChatGPT → Настройки → Использование. Повторите позже; запрос не переключён на оплату API.",
        ),
        Some("subscription_sharing_user_not_eligible") => (
            "subscription_sharing_user_not_eligible",
            "Выбранный аккаунт или рабочее пространство не поддерживает использование подписки ChatGPT в этом приложении. Проверьте тариф и политику доступа.",
        ),
        Some("subscription_sharing_usage_unavailable") => (
            "subscription_sharing_usage_unavailable",
            "Сейчас не удалось проверить лимит ChatGPT. Подключение сохранено; повторите позже.",
        ),
        Some("subscription_sharing_user_unavailable") => (
            "subscription_sharing_user_unavailable",
            "Данные аккаунта ChatGPT временно недоступны. Подключение сохранено; повторите позже.",
        ),
        Some("subscription_sharing_invalid_user") => (
            "subscription_sharing_invalid_user",
            "Не удалось подтвердить разрешение выбранного аккаунта ChatGPT. Войдите через ChatGPT снова.",
        ),
        Some("subscription_sharing_unsupported_capability") => (
            "subscription_sharing_unsupported_capability",
            "Подписка ChatGPT не поддерживает выбранную возможность или модель. Выберите другую доступную модель или формат JSON; исходные данные сохранены.",
        ),
        Some("subscription_sharing_route_not_supported") => (
            "subscription_sharing_route_not_supported",
            "Этот маршрут не поддерживает подписку ChatGPT. Обновите приложение и проверьте подключение.",
        ),
        Some("chatpass_v2_scope_not_authorized") => (
            "chatpass_v2_scope_not_authorized",
            "Не предоставлено нужное разрешение ChatGPT. В настройках подключения разрешите использование подписки и войдите снова.",
        ),
        Some("chatpass_v2_invalid_authorization_context") => (
            "chatpass_v2_invalid_authorization_context",
            "Разрешение ChatGPT не подходит для этого запроса. Проверьте выбранный аккаунт и войдите снова.",
        ),
        Some("model_not_found") => ("model_not_found", "Модель недоступна этому аккаунту ChatGPT. Обновите список и выберите доступную модель."),
        Some("context_length_exceeded") => ("context_length_exceeded", "Запрос превышает контекст модели. Выберите другую модель или сократите фокус встречи."),
        _ => ("request_failed", match status {
            StatusCode::UNAUTHORIZED => "Не удалось подтвердить разрешение ChatGPT. Войдите через ChatGPT снова.",
            StatusCode::FORBIDDEN => "ChatGPT отклонил запрос по правилам аккаунта, рабочего пространства или региона. Проверьте доступ выбранного аккаунта.",
            StatusCode::TOO_MANY_REQUESTS => "ChatGPT временно ограничил запросы. Проверьте ChatGPT → Настройки → Использование и повторите позже.",
            StatusCode::SERVICE_UNAVAILABLE => "Подключение ChatGPT временно недоступно. Аккаунт сохранён; повторите позже.",
            StatusCode::BAD_REQUEST | StatusCode::UNPROCESSABLE_ENTITY => "ChatGPT не поддерживает выбранный запрос. Проверьте модель, уровень рассуждений и формат JSON.",
            status if status.is_redirection() => "ChatGPT вернул перенаправление. Подключение остановлено; учётные данные не переданы другому адресу.",
            _ => "ChatGPT не выполнил запрос. Исходные данные сохранены; повторите позже.",
        }),
    };
    anyhow::anyhow!(
        "ChatGPT: HTTP {} · {}. {}",
        status.as_u16(),
        safe_code,
        hint
    )
}

fn inference_request(builder: RequestBuilder, access_token: &str, body: &Value) -> RequestBuilder {
    builder
        .header(reqwest::header::ACCEPT, "text/event-stream")
        .bearer_auth(access_token.trim())
        .json(body)
}

#[cfg(test)]
pub(crate) const TEST_BEARER: &str = "posle-loopback-subscription-fixture";
#[cfg(test)]
std::thread_local! {
    static TEST_TRANSPORT: std::cell::RefCell<Option<(Client, reqwest::Url)>> = const {
        std::cell::RefCell::new(None)
    };
}

/// Unit tests can exercise the complete AI pipeline through loopback HTTP. This
/// scoped hook is absent from release builds and never reads a real credential.
#[cfg(test)]
pub(crate) fn with_test_transport<T>(
    client: Client,
    endpoint: reqwest::Url,
    operation: impl FnOnce() -> T,
) -> T {
    assert_eq!(endpoint.scheme(), "http");
    assert_eq!(endpoint.host_str(), Some("127.0.0.1"));
    assert!(endpoint.port().is_some_and(|port| port > 0));
    assert_eq!(endpoint.path(), "/v1/responses");
    assert!(endpoint.username().is_empty() && endpoint.password().is_none());
    assert!(endpoint.query().is_none() && endpoint.fragment().is_none());
    struct Restore(Option<(Client, reqwest::Url)>);
    impl Drop for Restore {
        fn drop(&mut self) {
            TEST_TRANSPORT.with(|transport| *transport.borrow_mut() = self.0.take());
        }
    }
    let previous =
        TEST_TRANSPORT.with(|transport| transport.borrow_mut().replace((client, endpoint)));
    let _restore = Restore(previous);
    operation()
}

pub(crate) fn generate(client: &Client, access_token: &str, body: &Value) -> Result<Value> {
    let endpoint = RESPONSES_ENDPOINT;
    #[cfg(test)]
    let fixture = TEST_TRANSPORT.with(|transport| transport.borrow().clone());
    #[cfg(test)]
    let (client, endpoint, access_token) = match fixture.as_ref() {
        Some((client, url)) => {
            assert_eq!(endpoint, "https://api.openai.com/v1/responses");
            (client, url.as_str(), TEST_BEARER)
        }
        None => (client, endpoint, access_token),
    };
    if access_token.trim().is_empty() {
        bail!("Войдите через ChatGPT в настройках конспекта и карточек.");
    }
    // The client disables redirects; no endpoint override or alternate billing
    // path is accepted here. A failed inference is never automatically retried.
    let response = inference_request(client.post(endpoint), access_token, body)
        .send()
        .map_err(|_| {
            anyhow::anyhow!("Нет ответа от ChatGPT. Проверьте соединение; подключение сохранено.")
        })?;
    consume_response(response)
}

fn safe_media_type(media_type: &str) -> &'static str {
    // A response header is untrusted too: expose only a small fixed vocabulary,
    // never raw header values that could include credentials or user text.
    match media_type {
        "text/event-stream" => "text/event-stream",
        "application/json" => "application/json",
        "application/problem+json" => "application/problem+json",
        "text/html" => "text/html",
        "text/plain" => "text/plain",
        "application/octet-stream" => "application/octet-stream",
        "" => "missing",
        _ => "other",
    }
}

fn response_metadata(status: StatusCode, media_type: &str) -> String {
    format!(
        "ChatGPT: HTTP {} · Content-Type {}.",
        status.as_u16(),
        safe_media_type(media_type)
    )
}

fn response_format_error(status: StatusCode, media_type: &str) -> anyhow::Error {
    anyhow::anyhow!(
        "{} Неподходящий формат ответа Responses; исходные данные сохранены.",
        response_metadata(status, media_type)
    )
}

fn parse_answer(answer: &str) -> Result<Value> {
    let value: Value = serde_json::from_str(answer).map_err(|_| {
        anyhow::anyhow!("ChatGPT вернул ответ неподходящего формата JSON. Проверьте формат ответа; исходные данные сохранены.")
    })?;
    if !value.is_object() {
        bail!("ChatGPT вернул JSON без ожидаемого объекта. Исходные данные сохранены.");
    }
    Ok(value)
}

/// Extract finalized message parts without treating an omitted text snapshot as
/// an empty answer. Refusals and malformed/nonfinal messages remain failures.
fn validate_output_item_type(item: &Value) -> Result<()> {
    if !item.is_object() || !item["type"].is_string() {
        bail!("ChatGPT вернул некорректную часть результата Responses.");
    }
    if !["message", "reasoning"].contains(&item["type"].as_str().unwrap()) {
        bail!(
            "ChatGPT вернул неподдерживаемый тип результата Responses. Исходные данные сохранены."
        );
    }
    Ok(())
}

fn output_text_parts(item: &Value) -> Result<Vec<(usize, &str)>> {
    validate_output_item_type(item)?;
    if item
        .get("status")
        .is_some_and(|status| !status.is_null() && status != "completed")
    {
        bail!("ChatGPT не закончил часть ответа. Исходные данные сохранены.");
    }
    if item["type"] == "message"
        && (item["role"] != "assistant"
            || item["status"] != "completed"
            || !item["content"].is_array())
    {
        bail!("ChatGPT вернул некорректное сообщение Responses. Исходные данные сохранены.");
    }
    let content = match item.get("content") {
        Some(Value::Array(content)) => content,
        None | Some(Value::Null) if item["type"] != "message" => return Ok(Vec::new()),
        _ => bail!("ChatGPT вернул некорректное содержимое результата Responses."),
    };
    let mut parts = Vec::new();
    for (index, part) in content.iter().enumerate() {
        match part["type"].as_str() {
            Some("refusal") => {
                bail!("ChatGPT отказался обработать запрос. Исходные данные сохранены.")
            }
            Some("output_text") => {
                if item["type"] != "message" {
                    bail!("ChatGPT вернул некорректное сообщение Responses. Исходные данные сохранены.");
                }
                let text = part["text"].as_str().ok_or_else(|| {
                    anyhow::anyhow!("ChatGPT вернул некорректный текст результата.")
                })?;
                parts.push((index, text));
            }
            Some(_) => {}
            None => bail!("ChatGPT вернул некорректную часть содержимого Responses."),
        }
    }
    Ok(parts)
}

/// Common terminal validation for response.completed and buffered Responses
/// JSON. Only an SSE stream can supply text omitted from the terminal snapshot.
fn completed_text(
    response: &Value,
    status: StatusCode,
    max_answer: usize,
) -> Result<Option<String>> {
    if response.get("error").is_some_and(|error| !error.is_null()) {
        return Err(request_error(status, response["error"]["code"].as_str()));
    }
    if response["status"] != "completed"
        || response
            .get("incomplete_details")
            .is_some_and(|details| !details.is_null())
    {
        bail!("ChatGPT не подтвердил завершение ответа. Исходные данные сохранены.");
    }
    let Some(output) = response.get("output") else {
        return Ok(None);
    };
    let output = output
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("ChatGPT вернул некорректный результат Responses."))?;
    let mut text = String::new();
    let mut text_seen = false;
    for item in output {
        for (_, part) in output_text_parts(item)? {
            text_seen = true;
            if part.len() > max_answer.saturating_sub(text.len()) {
                bail!("Ответ ChatGPT превышает допустимый размер.");
            }
            text.push_str(part);
        }
    }
    // An explicit output_text:"" is authoritative and must not resurrect a
    // previous delta. No output_text part means a compact terminal snapshot.
    Ok(text_seen.then_some(text))
}

fn consume_response(mut response: Response) -> Result<Value> {
    let status = response.status();
    if !status.is_success() {
        let mut bytes = Vec::new();
        response
            .take((MAX_EVENT_BYTES + 1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|_| request_error(status, None))?;
        let value = if bytes.len() <= MAX_EVENT_BYTES {
            serde_json::from_slice::<Value>(&bytes).ok()
        } else {
            None
        };
        let code = value
            .as_ref()
            .and_then(|value| value["error"]["code"].as_str());
        return Err(request_error(status, code));
    }
    let media_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|header| header.to_str().ok())
        .and_then(|header| header.split(';').next())
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    let result = if media_type == "text/event-stream" {
        read_stream_value(&mut response, status)
    } else {
        // An intermediary may omit or mislabel the MIME type. Inspect at most
        // 4 KiB and then keep reading the same response, without a second call.
        let (prefix, format) = sniff_response(&mut response)
            .map_err(|_| response_format_error(status, &media_type))?;
        let mut reader = std::io::Cursor::new(prefix).chain(&mut response);
        match format {
            WireFormat::Events => read_stream_value(&mut reader, status),
            WireFormat::Json => read_json_response(&mut reader, status, &media_type),
            WireFormat::Unknown => Err(response_format_error(status, &media_type)),
        }
    };
    result.map_err(|error| {
        // Exact allowlisted error codes remain first so quota admission can
        // recognize them. Other failures expose only sanitized wire metadata.
        let diagnostics = error_diagnostics(&error).cloned().map(|mut diagnostics| {
            diagnostics.http_status = status.as_u16();
            diagnostics.content_type = safe_media_type(&media_type);
            diagnostics
        });
        let error = if error.to_string().starts_with("ChatGPT: HTTP ") {
            error
        } else {
            anyhow::anyhow!("{} {}", response_metadata(status, &media_type), error)
        };
        match diagnostics {
            Some(diagnostics) => with_diagnostics(error, diagnostics),
            None => error,
        }
    })
}

#[derive(Debug, PartialEq, Eq)]
enum WireFormat {
    Events,
    Json,
    Unknown,
}

fn sniff_response(reader: &mut impl Read) -> Result<(Vec<u8>, WireFormat)> {
    const PREFIX_LIMIT: usize = 4096;
    let mut prefix = Vec::new();
    let mut buffer = [0_u8; 64];
    loop {
        let mut content = prefix.as_slice();
        // A split UTF-8 BOM needs more bytes before a format decision.
        let partial_bom = content.len() < 3 && [0xef, 0xbb, 0xbf].starts_with(content);
        if content.starts_with(&[0xef, 0xbb, 0xbf]) {
            content = &content[3..];
        }
        content = content.trim_ascii_start();
        if !content.is_empty() && !partial_bom {
            if content.starts_with(b"{") || content.starts_with(b"[") {
                return Ok((content.to_vec(), WireFormat::Json));
            }
            let fields: [&[u8]; 5] = [b"data:", b"event:", b":", b"id:", b"retry:"];
            if fields.iter().any(|field| content.starts_with(field)) {
                return Ok((content.to_vec(), WireFormat::Events));
            }
            if !fields.iter().any(|field| field.starts_with(content)) {
                return Ok((prefix, WireFormat::Unknown));
            }
        }
        if prefix.len() >= PREFIX_LIMIT {
            return Ok((prefix, WireFormat::Unknown));
        }
        let limit = (PREFIX_LIMIT - prefix.len()).min(buffer.len());
        let count = reader.read(&mut buffer[..limit])?;
        if count == 0 {
            return Ok((prefix, WireFormat::Unknown));
        }
        prefix.extend_from_slice(&buffer[..count]);
    }
}

fn read_json_response(
    reader: &mut impl Read,
    status: StatusCode,
    media_type: &str,
) -> Result<Value> {
    // A complete Responses object may be buffered by a gateway. Plain generated
    // JSON, admission errors, partial responses and HTML are never success.
    let mut diagnostics = ChatGPTDiagnostics::new("json");
    let result = (|| {
        let mut bytes = Vec::new();
        let read = reader
            .take((MAX_STREAM_BYTES + 1) as u64)
            .read_to_end(&mut bytes);
        diagnostics.response_bytes = bytes.len();
        read.map_err(|_| {
            anyhow::anyhow!("Ответ ChatGPT прервался. Исходные данные сохранены; повторите позже.")
        })?;
        if bytes.len() > MAX_STREAM_BYTES {
            bail!("Ответ ChatGPT превышает допустимый размер.");
        }
        let value: Value = serde_json::from_slice(&bytes)
            .map_err(|_| response_format_error(status, media_type))?;
        diagnostics.terminal(&value);
        if value.get("error").is_some_and(|error| !error.is_null()) {
            return Err(request_error(status, value["error"]["code"].as_str()));
        }
        if value["object"] != "response" {
            return Err(response_format_error(status, media_type));
        }
        let answer = completed_text(&value, status, MAX_ANSWER_BYTES)?
            .ok_or_else(|| anyhow::anyhow!("ChatGPT завершил запрос без текста ответа."))?;
        diagnostics.accumulated_text_bytes = answer.len();
        parse_answer(&answer)
    })();
    result.map_err(|error| with_diagnostics(error, diagnostics))
}

fn read_stream_value(reader: &mut impl Read, http_status: StatusCode) -> Result<Value> {
    let (answer, diagnostics) = read_stream_with_diagnostics(reader, http_status)?;
    parse_answer(&answer).map_err(|error| with_diagnostics(error, diagnostics))
}

#[cfg(test)]
fn read_stream(reader: &mut impl Read, http_status: StatusCode) -> Result<String> {
    read_stream_with_diagnostics(reader, http_status).map(|(answer, _)| answer)
}

fn read_stream_with_diagnostics(
    reader: &mut impl Read,
    http_status: StatusCode,
) -> Result<(String, ChatGPTDiagnostics)> {
    let mut parser = EventStream::new(MAX_STREAM_BYTES, MAX_EVENT_BYTES, MAX_ANSWER_BYTES);
    parser.http_status = http_status;
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        let count = match reader.read(&mut buffer) {
            Ok(count) => count,
            Err(_) => {
                return Err(with_diagnostics(
                    anyhow::anyhow!(
                        "Ответ ChatGPT прервался. Исходные данные сохранены; повторите позже."
                    ),
                    parser.diagnostics(),
                ))
            }
        };
        let result = if count == 0 {
            parser.finish().map(Some)
        } else {
            parser.feed(&buffer[..count])
        };
        match result {
            Ok(Some(answer)) => return Ok((answer, parser.diagnostics())),
            Ok(None) => {}
            Err(error) => return Err(with_diagnostics(error, parser.diagnostics())),
        }
    }
}

/// Incremental SSE framing stores bytes until complete lines/events, so UTF-8
/// characters may safely cross arbitrary network boundaries. All allocations
/// are bounded independently of a server's newline or terminal-event behavior.
struct StreamText {
    text: String,
    finalized: bool,
}

struct EventStream {
    http_status: StatusCode,
    total: usize,
    max_total: usize,
    max_event: usize,
    max_answer: usize,
    line: Vec<u8>,
    first_line: bool,
    event_data: Vec<u8>,
    event_name: Vec<u8>,
    data_seen: bool,
    skip_lf: bool,
    text_parts: BTreeMap<(u64, u64), StreamText>,
    item_ids: BTreeMap<u64, String>,
    id_indices: BTreeMap<String, u64>,
    text_bytes: usize,
    diagnostics: ChatGPTDiagnostics,
}
impl EventStream {
    fn new(max_total: usize, max_event: usize, max_answer: usize) -> Self {
        Self {
            http_status: StatusCode::OK,
            total: 0,
            max_total,
            max_event,
            max_answer,
            line: Vec::new(),
            first_line: true,
            event_data: Vec::new(),
            event_name: Vec::new(),
            data_seen: false,
            skip_lf: false,
            text_parts: BTreeMap::new(),
            item_ids: BTreeMap::new(),
            id_indices: BTreeMap::new(),
            text_bytes: 0,
            diagnostics: ChatGPTDiagnostics::new("sse"),
        }
    }
    fn feed(&mut self, bytes: &[u8]) -> Result<Option<String>> {
        self.total = self
            .total
            .checked_add(bytes.len())
            .ok_or_else(|| anyhow::anyhow!("Поток ChatGPT превышает допустимый размер."))?;
        if self.total > self.max_total {
            bail!("Поток ChatGPT превышает допустимый размер.");
        }
        for &byte in bytes {
            if self.skip_lf {
                self.skip_lf = false;
                if byte == b'\n' {
                    continue;
                }
            }
            if byte == b'\n' || byte == b'\r' {
                self.skip_lf = byte == b'\r';
                if let Some(answer) = self.consume_line()? {
                    return Ok(Some(answer));
                }
            } else {
                if self.line.len() + self.event_data.len() + self.event_name.len() >= self.max_event
                {
                    bail!("Событие ChatGPT превышает допустимый размер.");
                }
                self.line.push(byte);
            }
        }
        Ok(None)
    }
    fn consume_line(&mut self) -> Result<Option<String>> {
        let mut line = std::mem::take(&mut self.line);
        if self.first_line {
            self.first_line = false;
            if line.starts_with(&[0xef, 0xbb, 0xbf]) {
                line.drain(..3);
            }
        }
        if line.is_empty() {
            if !self.data_seen {
                self.event_name.clear();
                return Ok(None);
            }
            let result = self.consume_event();
            self.event_data.clear();
            self.event_name.clear();
            self.data_seen = false;
            return result;
        }
        if line[0] == b':' {
            return Ok(None);
        }
        let colon = line
            .iter()
            .position(|&byte| byte == b':')
            .unwrap_or(line.len());
        let name = &line[..colon];
        let mut value = if colon < line.len() {
            &line[colon + 1..]
        } else {
            &[]
        };
        if value.first() == Some(&b' ') {
            value = &value[1..];
        }
        match name {
            b"data" => {
                if self.data_seen {
                    self.event_data.push(b'\n');
                }
                self.event_data.extend_from_slice(value);
                self.data_seen = true;
            }
            b"event" => {
                self.event_name.clear();
                self.event_name.extend_from_slice(value);
            }
            _ => {}
        }
        if self.event_data.len() + self.event_name.len() > self.max_event {
            bail!("Событие ChatGPT превышает допустимый размер.");
        }
        Ok(None)
    }
    fn consume_event(&mut self) -> Result<Option<String>> {
        if self.event_data == b"[DONE]" {
            bail!("ChatGPT завершил поток без подтверждения response.completed. Исходные данные сохранены.");
        }
        let event: Value = serde_json::from_slice(&self.event_data).map_err(|_| {
            anyhow::anyhow!(
                "ChatGPT вернул повреждённое событие Responses. Исходные данные сохранены."
            )
        })?;
        let kind = event["type"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("ChatGPT вернул событие без типа."))?;
        if !self.event_name.is_empty() && self.event_name != kind.as_bytes() {
            bail!("ChatGPT вернул противоречивое событие Responses.");
        }
        self.diagnostics.events += 1;
        match kind {
            "response.output_text.delta" => self.diagnostics.output_text_delta += 1,
            "response.output_text.done" => self.diagnostics.output_text_done += 1,
            "response.content_part.done" => self.diagnostics.content_part_done += 1,
            "response.output_item.done" => self.diagnostics.output_item_done += 1,
            "response.completed" => {
                self.diagnostics.completed += 1;
                self.diagnostics.terminal(&event["response"]);
            }
            "response.failed" | "response.incomplete" | "response.cancelled" => {
                self.diagnostics.other_events += 1;
                self.diagnostics.terminal(&event["response"]);
            }
            _ => self.diagnostics.other_events += 1,
        }
        match kind {
            "response.output_text.delta" | "response.output_text.done" => {
                let finalized = kind == "response.output_text.done";
                let text = event[if finalized { "text" } else { "delta" }]
                    .as_str()
                    .ok_or_else(|| anyhow::anyhow!("ChatGPT вернул некорректную часть текста."))?;
                let index = text_index(&event)?;
                self.record_identity(index.0, optional_id(event.get("item_id"))?)?;
                self.record_text(index, text, finalized)?;
            }
            "response.content_part.done" => match event["part"]["type"].as_str() {
                Some("output_text") => {
                    let text = event["part"]["text"].as_str().ok_or_else(|| {
                        anyhow::anyhow!("ChatGPT вернул некорректный текст результата.")
                    })?;
                    let index = text_index(&event)?;
                    self.record_identity(index.0, optional_id(event.get("item_id"))?)?;
                    self.record_text(index, text, true)?;
                }
                Some("refusal") => {
                    bail!("ChatGPT отказался обработать запрос. Исходные данные сохранены.")
                }
                Some(_) => {}
                None => bail!("ChatGPT вернул некорректную часть содержимого Responses."),
            },
            "response.output_item.added" => {
                let item = &event["item"];
                validate_output_item_type(item)?;
                if item["type"] == "message"
                    && (item["role"] != "assistant" || !item["content"].is_array())
                {
                    bail!("ChatGPT вернул некорректное сообщение Responses. Исходные данные сохранены.");
                }
                if item["content"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|part| part["type"] == "refusal")
                {
                    bail!("ChatGPT отказался обработать запрос. Исходные данные сохранены.");
                }
                let output_index = event["output_index"].as_u64().ok_or_else(|| {
                    anyhow::anyhow!("ChatGPT вернул некорректный индекс результата.")
                })?;
                self.record_identity(output_index, optional_id(item.get("id"))?)?;
            }
            "response.output_item.done" => {
                let output_index = event["output_index"].as_u64().ok_or_else(|| {
                    anyhow::anyhow!("ChatGPT вернул некорректный индекс результата.")
                })?;
                self.record_identity(output_index, optional_id(event["item"].get("id"))?)?;
                for (content_index, text) in output_text_parts(&event["item"])? {
                    self.record_text((output_index, content_index as u64), text, true)?;
                }
            }
            "response.content_part.added" if event["part"]["type"] == "refusal" => {
                bail!("ChatGPT отказался обработать запрос. Исходные данные сохранены.")
            }
            "response.refusal.delta" | "response.refusal.done" => {
                bail!("ChatGPT отказался обработать запрос. Исходные данные сохранены.")
            }
            "response.failed" => {
                return Err(request_error(
                    self.http_status,
                    event["response"]["error"]["code"].as_str(),
                ))
            }
            "error" => {
                return Err(request_error(
                    self.http_status,
                    event["code"]
                        .as_str()
                        .or_else(|| event["error"]["code"].as_str()),
                ))
            }
            "response.incomplete" | "response.cancelled" => {
                bail!("ChatGPT не закончил ответ. Исходные данные сохранены; повторите позже.")
            }
            "response.completed" => {
                let text = completed_text(&event["response"], self.http_status, self.max_answer)?;
                self.validate_terminal_text(&event["response"], text.is_some())?;
                let text = match text {
                    Some(text) => text,
                    // The completion event confirms success; finalized text
                    // events/deltas may carry the only text snapshot.
                    None => self
                        .text_parts
                        .values()
                        .map(|part| part.text.as_str())
                        .collect(),
                };
                if text.trim().is_empty() {
                    bail!("ChatGPT завершил запрос без текста ответа.");
                }
                return Ok(Some(text));
            }
            _ => {}
        }
        Ok(None)
    }
    fn record_text(&mut self, index: (u64, u64), text: &str, replace: bool) -> Result<()> {
        let previous = self.text_parts.get(&index);
        if let Some(previous) = previous.filter(|part| part.finalized) {
            if !replace || previous.text != text {
                bail!("ChatGPT вернул противоречивые части ответа Responses. Исходные данные сохранены.");
            }
            return Ok(());
        }
        let previous = previous.map_or(0, |part| part.text.len());
        let base = if replace {
            self.text_bytes - previous
        } else {
            self.text_bytes
        };
        let total = base
            .checked_add(text.len())
            .ok_or_else(|| anyhow::anyhow!("Ответ ChatGPT превышает допустимый размер."))?;
        if total > self.max_answer {
            bail!("Ответ ChatGPT превышает допустимый размер.");
        }
        let part = self.text_parts.entry(index).or_insert_with(|| StreamText {
            text: String::new(),
            finalized: false,
        });
        if replace {
            part.text.clear();
        }
        part.text.push_str(text);
        part.finalized = replace;
        self.text_bytes = total;
        Ok(())
    }
    fn record_identity(&mut self, index: u64, id: Option<&str>) -> Result<()> {
        let Some(id) = id else {
            return Ok(());
        };
        if self.item_ids.get(&index).is_some_and(|known| known != id)
            || self.id_indices.get(id).is_some_and(|known| *known != index)
        {
            bail!("ChatGPT вернул противоречивый индекс результата Responses. Исходные данные сохранены.");
        }
        self.item_ids.entry(index).or_insert_with(|| id.to_owned());
        self.id_indices.entry(id.to_owned()).or_insert(index);
        Ok(())
    }
    fn validate_terminal_text(&mut self, response: &Value, authoritative: bool) -> Result<()> {
        let mut seen = BTreeSet::new();
        for (output_index, item) in response["output"]
            .as_array()
            .into_iter()
            .flatten()
            .enumerate()
        {
            let output_index = output_index as u64;
            self.record_identity(output_index, optional_id(item.get("id"))?)?;
            for (content_index, text) in output_text_parts(item)? {
                let index = (output_index, content_index as u64);
                seen.insert(index);
                if self
                    .text_parts
                    .get(&index)
                    .is_some_and(|previous| previous.finalized && previous.text != text)
                {
                    bail!("ChatGPT вернул противоречивые части ответа Responses. Исходные данные сохранены.");
                }
            }
        }
        if authoritative
            && self
                .text_parts
                .iter()
                .any(|(index, part)| part.finalized && !seen.contains(index))
        {
            bail!(
                "ChatGPT вернул противоречивые части ответа Responses. Исходные данные сохранены."
            );
        }
        Ok(())
    }
    fn diagnostics(&self) -> ChatGPTDiagnostics {
        let mut diagnostics = self.diagnostics.clone();
        diagnostics.http_status = self.http_status.as_u16();
        diagnostics.response_bytes = self.total;
        diagnostics.accumulated_text_bytes = self.text_bytes;
        diagnostics
    }
    fn finish(&self) -> Result<String> {
        bail!("Ответ ChatGPT прервался без response.completed. Исходные данные сохранены; повторите позже.")
    }
}

fn optional_id(value: Option<&Value>) -> Result<Option<&str>> {
    match value {
        None => Ok(None),
        Some(Value::String(id)) if !id.is_empty() => Ok(Some(id)),
        _ => bail!("ChatGPT вернул некорректный идентификатор части результата."),
    }
}

fn text_index(event: &Value) -> Result<(u64, u64)> {
    match (
        event["output_index"].as_u64(),
        event["content_index"].as_u64(),
    ) {
        (Some(output), Some(content)) => Ok((output, content)),
        _ => bail!("ChatGPT вернул некорректный индекс части текста."),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn event(value: Value) -> Vec<u8> {
        format!(
            "event: {}\ndata: {}\n\n",
            value["type"].as_str().unwrap(),
            value
        )
        .into_bytes()
    }
    fn response_value(text: &str) -> Value {
        json!({"object":"response","status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":text}]}]})
    }
    fn completed(text: &str) -> Vec<u8> {
        event(json!({"type":"response.completed","response":response_value(text)}))
    }
    fn delta(text: &str) -> Vec<u8> {
        event(
            json!({"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":text}),
        )
    }

    #[test]
    fn request_contract_omits_all_unsupported_fields_and_keeps_user_text_untrusted() {
        let schema = json!({"type":"object","properties":{"ok":{"type":"boolean"}}});
        for output in ["schema", "json", "prompt"] {
            let body = request_body(
                "gpt-6-luna",
                "none",
                output,
                "SYSTEM",
                "PRIVATE_MEETING",
                &schema,
            )
            .unwrap();
            assert_eq!(body["store"], false);
            assert_eq!(body["stream"], true);
            assert_eq!(body["reasoning"], json!({"effort":"none"}));
            assert_eq!(
                body["input"],
                json!([{"role":"user","content":"PRIVATE_MEETING"}])
            );
            for field in [
                "background",
                "conversation",
                "max_output_tokens",
                "max_tool_calls",
                "metadata",
                "moderation",
                "multi_agent",
                "prompt",
                "prompt_cache_retention",
                "safety_identifier",
                "temperature",
                "top_logprobs",
                "top_p",
                "truncation",
                "user",
                "previous_response_id",
                "tools",
            ] {
                assert!(body.get(field).is_none(), "unsupported {field}");
            }
            let keys = body
                .as_object()
                .unwrap()
                .keys()
                .map(String::as_str)
                .collect::<Vec<_>>();
            assert_eq!(
                keys,
                if output == "prompt" {
                    vec![
                        "input",
                        "instructions",
                        "model",
                        "reasoning",
                        "store",
                        "stream",
                    ]
                } else {
                    vec![
                        "input",
                        "instructions",
                        "model",
                        "reasoning",
                        "store",
                        "stream",
                        "text",
                    ]
                }
            );
            if output == "prompt" {
                assert!(body["instructions"]
                    .as_str()
                    .unwrap()
                    .contains(&schema.to_string()));
            }
        }
        assert!(request_body("gpt-6-luna", "untrusted", "schema", "S", "P", &schema).is_err());
        assert!(request_body("", "none", "schema", "S", "P", &schema).is_err());
        let auto = request_body("account-model", "auto", "schema", "S", "P", &schema).unwrap();
        assert!(
            auto.get("reasoning").is_none(),
            "model-default setting must omit reasoning entirely"
        );
        assert_eq!(
            request_body("account-model", "minimal", "prompt", "S", "P", &schema).unwrap()
                ["reasoning"]["effort"],
            "minimal"
        );
    }
    #[test]
    fn fragmented_utf8_and_crlf_stream_requires_completed() {
        let text = r#"{"summary":"Обсудили café и 日本語"}"#;
        let mut stream = b": keepalive\r\n\r\n".to_vec();
        stream.extend(delta(text));
        stream.extend(completed(text));
        let stream = String::from_utf8(stream)
            .unwrap()
            .replace('\n', "\r\n")
            .into_bytes();
        for chunk_size in 1..=37 {
            let mut parser = EventStream::new(MAX_STREAM_BYTES, MAX_EVENT_BYTES, MAX_ANSWER_BYTES);
            let mut answer = None;
            for chunk in stream.chunks(chunk_size) {
                if let Some(text) = parser.feed(chunk).unwrap() {
                    answer = Some(text);
                    break;
                }
            }
            assert_eq!(answer.as_deref(), Some(text), "chunk size {chunk_size}");
        }
    }
    #[test]
    fn multiline_data_and_lone_cr_are_valid_sse() {
        let bytes = b"event: response.completed\rdata: {\"type\":\"response.completed\",\rdata: \"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"{}\"}]}]}}\r\r";
        assert_eq!(
            read_stream(&mut Cursor::new(bytes), StatusCode::OK).unwrap(),
            "{}"
        );
    }
    #[test]
    fn completed_response_is_authoritative_and_deltas_are_ordered_for_compact_terminal() {
        let mut stream = delta("partial");
        stream.extend(completed(r#"{"ok":true}"#));
        assert_eq!(
            read_stream(&mut Cursor::new(stream), StatusCode::OK).unwrap(),
            r#"{"ok":true}"#
        );
        let mut stream = event(
            json!({"type":"response.output_text.delta","output_index":1,"content_index":0,"delta":"}"}),
        );
        stream.extend(delta("{"));
        stream.extend(event(
            json!({"type":"response.completed","response":{"status":"completed"}}),
        ));
        assert_eq!(
            read_stream(&mut Cursor::new(stream), StatusCode::OK).unwrap(),
            "{}"
        );
        let mut stream = delta("{}");
        stream.extend(event(
            json!({"type":"response.completed","response":{"status":"completed","output":[]}}),
        ));
        assert_eq!(
            read_stream(&mut Cursor::new(stream), StatusCode::OK).unwrap(),
            "{}",
            "the completed event confirms previously streamed text"
        );
        let mut stream = delta("{}");
        stream.extend(completed(""));
        assert!(
            read_stream(&mut Cursor::new(stream), StatusCode::OK).is_err(),
            "an explicit empty output_text is authoritative"
        );
    }
    fn finalized_text_events(text: &str) -> Vec<Vec<u8>> {
        vec![
            event(
                json!({"type":"response.output_text.done","output_index":0,"content_index":0,"text":text}),
            ),
            event(
                json!({"type":"response.content_part.done","output_index":0,"content_index":0,"part":{"type":"output_text","text":text}}),
            ),
            event(
                json!({"type":"response.output_item.done","output_index":0,"item":response_value(text)["output"][0]}),
            ),
        ]
    }
    fn compact_terminal(output: Option<Value>) -> Vec<u8> {
        let mut response = json!({"status":"completed"});
        if let Some(output) = output {
            response["output"] = output;
        }
        event(json!({"type":"response.completed","response":response}))
    }
    #[test]
    fn finalized_lifecycle_text_is_retained_until_compact_completion_without_duplication() {
        let text = r#"{"overview":"Обсудили café и 日本語","items":[],"cards":[]}"#;
        for output in [
            None,
            Some(json!([])),
            Some(json!([{"type":"reasoning","summary":[]}])),
        ] {
            for snapshot in finalized_text_events(text) {
                let mut stream = delta("partial");
                stream.extend(snapshot);
                stream.extend(compact_terminal(output.clone()));
                for chunk_size in 1..=37 {
                    let mut parser =
                        EventStream::new(MAX_STREAM_BYTES, MAX_EVENT_BYTES, MAX_ANSWER_BYTES);
                    let mut answer = None;
                    for chunk in stream.chunks(chunk_size) {
                        if let Some(value) = parser.feed(chunk).unwrap() {
                            answer = Some(value);
                            break;
                        }
                    }
                    assert_eq!(answer.as_deref(), Some(text), "chunk size {chunk_size}");
                }
            }
        }
        let mut stream = delta("partial");
        for snapshot in finalized_text_events(text) {
            stream.extend(snapshot);
        }
        stream.extend(compact_terminal(Some(json!([]))));
        assert_eq!(
            read_stream(&mut Cursor::new(stream), StatusCode::OK).unwrap(),
            text,
            "nested done snapshots replace the same indexed text part"
        );
    }
    #[test]
    fn compact_completion_keeps_indexed_parts_in_order() {
        let mut stream = event(
            json!({"type":"response.output_text.done","output_index":1,"content_index":1,"text":"}"}),
        );
        stream.extend(event(json!({"type":"response.content_part.done","output_index":1,"content_index":0,"part":{"type":"output_text","text":"{"}})));
        stream.extend(compact_terminal(Some(
            json!([{"type":"reasoning","summary":[]}]),
        )));
        assert_eq!(
            read_stream(&mut Cursor::new(stream), StatusCode::OK).unwrap(),
            "{}"
        );
    }
    #[test]
    fn finalized_parts_never_publish_before_completion_or_rescue_invalid_terminals() {
        for snapshot in finalized_text_events("{}") {
            let error = read_stream(&mut Cursor::new(snapshot), StatusCode::OK).unwrap_err();
            assert!(error.to_string().contains("response.completed"));
        }
        let mut terminals = vec![
            compact_terminal(Some(Value::Null)),
            compact_terminal(Some(json!({"PRIVATE":"not an array"}))),
            compact_terminal(Some(json!(["PRIVATE"]))),
            compact_terminal(Some(
                json!([{"type":"message","role":"assistant","status":"completed","content":{}}]),
            )),
            compact_terminal(Some(
                json!([{"type":"message","role":"user","status":"completed","content":[]}]),
            )),
            compact_terminal(Some(
                json!([{"type":"message","role":"assistant","status":"in_progress","content":[]}]),
            )),
            completed(""),
            completed(" "),
            event(
                json!({"type":"response.completed","response":{"status":"completed","incomplete_details":{"reason":"PRIVATE"},"output":[]}}),
            ),
            event(
                json!({"type":"response.completed","response":{"status":"incomplete","output":[]}}),
            ),
            event(
                json!({"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"PRIVATE"}}}),
            ),
            event(json!({"type":"response.incomplete","response":{"status":"incomplete"}})),
            event(json!({"type":"response.cancelled","response":{"status":"cancelled"}})),
            event(json!({"type":"response.refusal.done","refusal":"PRIVATE"})),
            event(
                json!({"type":"response.content_part.done","output_index":0,"content_index":0,"part":{"type":"refusal","refusal":"PRIVATE"}}),
            ),
        ];
        let mut refused = response_value("{}");
        refused["output"][0]["content"] = json!([{"type":"refusal","refusal":"PRIVATE"}]);
        terminals.push(event(json!({"type":"response.output_item.done","output_index":0,"item":refused["output"][0]})));
        for terminal in terminals {
            let mut stream = finalized_text_events("{}").remove(0);
            stream.extend(terminal);
            let error = read_stream(&mut Cursor::new(stream), StatusCode::OK)
                .unwrap_err()
                .to_string();
            assert!(!error.contains("PRIVATE"));
        }
        for malformed in [
            json!({"type":"response.output_text.done","output_index":0,"content_index":0,"text":null}),
            json!({"type":"response.output_text.done","output_index":"PRIVATE","content_index":0,"text":"{}"}),
            json!({"type":"response.output_text.delta","output_index":0,"delta":"{}"}),
            json!({"type":"response.content_part.done","output_index":0,"content_index":0,"part":{"type":"output_text","text":42}}),
            json!({"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","status":"in_progress","content":[]}}),
        ] {
            let mut stream = delta("{}");
            stream.extend(event(malformed));
            stream.extend(compact_terminal(Some(json!([]))));
            assert!(read_stream(&mut Cursor::new(stream), StatusCode::OK).is_err());
        }
    }
    #[test]
    fn contradictory_finalized_text_indices_and_ids_never_succeed() {
        let done = finalized_text_events("{}").remove(0);
        let mut contradictions = finalized_text_events(r#"{"other":true}"#);
        contradictions.extend([
            delta(""),
            completed(r#"{"other":true}"#),
            compact_terminal(Some(json!([{"type":"function_call","status":"completed","name":"PRIVATE","arguments":"{}"}]))),
            compact_terminal(Some(json!([
                {"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"{}"}]},
                {"type":"function_call","status":"completed","name":"PRIVATE","arguments":"{}"}
            ]))),
            event(json!({"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","status":"completed","name":"PRIVATE","arguments":"{}"}})),
            event(json!({"type":"response.content_part.added","part":{"type":"refusal","refusal":"PRIVATE"}})),
        ]);
        for contradiction in contradictions {
            let mut stream = done.clone();
            stream.extend(contradiction);
            stream.extend(compact_terminal(Some(json!([]))));
            let error = read_stream(&mut Cursor::new(stream), StatusCode::OK)
                .unwrap_err()
                .to_string();
            assert!(!error.contains("PRIVATE"));
        }
        let identified = event(
            json!({"type":"response.output_text.done","item_id":"msg_first","output_index":0,"content_index":0,"text":"{}"}),
        );
        let mut changed_terminal = response_value("{}");
        changed_terminal["output"][0]["id"] = json!("msg_changed");
        for contradiction in [
            event(
                json!({"type":"response.output_text.done","item_id":"msg_changed","output_index":0,"content_index":0,"text":"{}"}),
            ),
            event(
                json!({"type":"response.content_part.done","item_id":"msg_first","output_index":1,"content_index":0,"part":{"type":"output_text","text":"{}"}}),
            ),
            event(
                json!({"type":"response.output_item.done","output_index":0,"item":{"id":"msg_changed","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"{}"}]}}),
            ),
            event(json!({"type":"response.completed","response":changed_terminal})),
            compact_terminal(Some(
                json!([{"id":"reasoning_changed","type":"reasoning","summary":[]}]),
            )),
        ] {
            let mut stream = identified.clone();
            stream.extend(contradiction);
            stream.extend(compact_terminal(Some(json!([]))));
            assert!(read_stream(&mut Cursor::new(stream), StatusCode::OK)
                .unwrap_err()
                .to_string()
                .contains("противоречив"));
        }
        let mut stream = identified;
        let mut matching = response_value("{}");
        matching["output"][0]["id"] = json!("msg_first");
        stream.extend(event(
            json!({"type":"response.completed","response":matching}),
        ));
        assert_eq!(
            read_stream(&mut Cursor::new(stream), StatusCode::OK).unwrap(),
            "{}"
        );
        let mut stream = done;
        stream.extend(event(json!({"type":"response.output_text.done","output_index":1,"content_index":0,"text":" "})));
        stream.extend(completed("{}"));
        assert!(
            read_stream(&mut Cursor::new(stream), StatusCode::OK).is_err(),
            "nonempty terminal output must account for all finalized parts"
        );
    }

    #[test]
    fn added_items_cannot_hide_tools_refusals_or_changed_message_identity() {
        for item in [
            json!({"type":"function_call","name":"PRIVATE","arguments":"{}"}),
            json!({"type":"message","role":"user","status":"in_progress","content":[]}),
            json!({"type":"message","role":"assistant","status":"in_progress","content":{"PRIVATE":true}}),
            json!({"type":"message","role":"assistant","status":"in_progress","content":[{"type":"refusal","refusal":"PRIVATE"}]}),
            json!({"type":42}),
        ] {
            let mut stream =
                event(json!({"type":"response.output_item.added","output_index":0,"item":item}));
            stream.extend(finalized_text_events("{}").remove(0));
            stream.extend(compact_terminal(Some(json!([]))));
            let error = read_stream(&mut Cursor::new(stream), StatusCode::OK)
                .unwrap_err()
                .to_string();
            assert!(!error.contains("PRIVATE"));
        }
        let added = event(
            json!({"type":"response.output_item.added","output_index":0,"item":{"id":"msg_first","type":"message","role":"assistant","status":"in_progress","content":[]}}),
        );
        let mut changed = added.clone();
        changed.extend(event(json!({"type":"response.output_text.done","item_id":"msg_other","output_index":0,"content_index":0,"text":"{}"})));
        changed.extend(compact_terminal(Some(json!([]))));
        assert!(read_stream(&mut Cursor::new(changed), StatusCode::OK)
            .unwrap_err()
            .to_string()
            .contains("противоречив"));
        let mut matching = added;
        matching.extend(event(json!({"type":"response.output_text.done","item_id":"msg_first","output_index":0,"content_index":0,"text":"{}"})));
        matching.extend(compact_terminal(Some(json!([]))));
        assert_eq!(
            read_stream(&mut Cursor::new(matching), StatusCode::OK).unwrap(),
            "{}"
        );
    }

    #[test]
    fn finalized_text_replacement_keeps_aggregate_answer_bounds() {
        let mut parser = EventStream::new(8192, 4096, 2);
        assert!(parser.feed(&delta("{")).unwrap().is_none());
        for snapshot in finalized_text_events("{}") {
            assert!(parser.feed(&snapshot).unwrap().is_none());
        }
        assert_eq!(parser.text_bytes, 2);
        assert_eq!(
            parser
                .feed(&compact_terminal(Some(json!([]))))
                .unwrap()
                .as_deref(),
            Some("{}")
        );
        for snapshot in finalized_text_events("abc") {
            let mut parser = EventStream::new(8192, 4096, 2);
            assert!(parser
                .feed(&snapshot)
                .unwrap_err()
                .to_string()
                .contains("размер"));
        }
        let mut parser = EventStream::new(8192, 4096, 2);
        parser.feed(&finalized_text_events("{}").remove(0)).unwrap();
        let other = event(
            json!({"type":"response.output_text.done","output_index":1,"content_index":0,"text":"x"}),
        );
        assert!(parser.feed(&other).is_err());
    }

    #[test]
    fn interrupted_incomplete_refused_and_failed_outputs_never_succeed() {
        let cases = vec![
            Vec::new(),
            delta("{}"),
            b"data: [DONE]\n\n".to_vec(),
            b"data: PRIVATE\n\n".to_vec(),
            event(json!({"type":"response.incomplete","response":{"status":"incomplete"}})),
            event(json!({"type":"response.completed","response":{"status":"incomplete"}})),
            event(
                json!({"type":"response.completed","response":{"status":"completed","output":[{"content":[{"type":"refusal","refusal":"PRIVATE"}]}]}}),
            ),
            event(json!({"type":"response.refusal.delta","delta":"PRIVATE"})),
            event(
                json!({"type":"response.failed","response":{"error":{"code":"PRIVATE","message":"SECRET"}}}),
            ),
            event(json!({"type":"error","code":"PRIVATE","message":"SECRET"})),
            b"event: response.completed\ndata: {\"type\":\"response.failed\"}\n\n".to_vec(),
            completed(""),
        ];
        for stream in cases {
            let error = read_stream(&mut Cursor::new(stream), StatusCode::OK)
                .unwrap_err()
                .to_string();
            assert!(!error.contains("PRIVATE"));
            assert!(!error.contains("SECRET"));
        }
    }
    #[test]
    fn total_line_event_and_accumulated_text_limits_are_bounded() {
        let mut parser = EventStream::new(8, 8, 8);
        assert!(parser.feed(b": 123456789").is_err());
        let mut parser = EventStream::new(1024, 8, 8);
        assert!(parser.feed(b"data: 123456789").is_err());
        let mut parser = EventStream::new(1024, 64, 8);
        assert!(parser
            .feed(b"data: 123456789012345678901234567890\ndata: 123456789012345678901234567890\n")
            .is_err());
        let mut parser = EventStream::new(4096, 1024, 2);
        assert!(parser.feed(&delta("abc")).is_err());
        let mut parser = EventStream::new(4096, 1024, 2);
        assert!(parser.feed(&completed("abc")).is_err());
    }
    fn http_fixture(
        status: u16,
        media_type: &str,
        body: Vec<u8>,
    ) -> (String, std::thread::JoinHandle<(String, Value)>) {
        use std::io::{Read, Write};
        use std::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}/v1/responses", listener.local_addr().unwrap());
        let media_type = media_type.to_owned();
        let handle = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(std::time::Duration::from_secs(2)))
                .unwrap();
            let mut bytes = Vec::new();
            let mut buffer = [0_u8; 2048];
            let (header_end, content_length) = loop {
                let count = stream.read(&mut buffer).unwrap();
                assert!(count > 0);
                bytes.extend_from_slice(&buffer[..count]);
                if let Some(index) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
                    let headers = std::str::from_utf8(&bytes[..index]).unwrap();
                    let length = headers
                        .lines()
                        .find_map(|line| {
                            let (key, value) = line.split_once(':')?;
                            key.eq_ignore_ascii_case("content-length")
                                .then(|| value.trim().parse::<usize>().unwrap())
                        })
                        .unwrap();
                    break (index + 4, length);
                }
            };
            while bytes.len() < header_end + content_length {
                let count = stream.read(&mut buffer).unwrap();
                assert!(count > 0);
                bytes.extend_from_slice(&buffer[..count]);
            }
            let headers = String::from_utf8(bytes[..header_end].to_vec()).unwrap();
            let request =
                serde_json::from_slice(&bytes[header_end..header_end + content_length]).unwrap();
            let redirect = if status == 302 {
                "Location: http://127.0.0.1:9/forbidden\r\n"
            } else {
                ""
            };
            let content_type = if media_type.is_empty() {
                String::new()
            } else {
                format!("Content-Type: {media_type}\r\n")
            };
            write!(stream, "HTTP/1.1 {status} fixture\r\n{content_type}Content-Length: {}\r\n{redirect}Connection: close\r\n\r\n", body.len()).unwrap();
            // Small writes also exercise HTTP buffering without relying on
            // the operating system preserving packet boundaries.
            let chunk_size = if body.len() > 64 * 1024 { 8192 } else { 97 };
            for chunk in body.chunks(chunk_size) {
                if stream.write_all(chunk).is_err() {
                    break;
                }
            }
            (headers, request)
        });
        (endpoint, handle)
    }
    #[test]
    fn actual_http_stream_transport_accepts_only_completed_json_and_rejects_late_failure() {
        let client = fixture_client();
        let body =
            request_body("gpt-6-luna", "none", "prompt", "S", "PRIVATE", &json!({})).unwrap();
        let mut successful = delta(r#"{"ok":true}"#);
        successful.extend(completed(r#"{"ok":true}"#));
        let (url, server) = http_fixture(200, "text/event-stream; charset=utf-8", successful);
        let response = inference_request(client.post(url), "fixture-secret", &body)
            .send()
            .unwrap();
        assert_eq!(consume_response(response).unwrap(), json!({"ok":true}));
        let (headers, request) = server.join().unwrap();
        assert!(headers
            .to_lowercase()
            .contains("authorization: bearer fixture-secret"));
        assert!(headers.to_lowercase().contains("accept: text/event-stream"));
        assert_eq!(request, body);
        let mut failed = delta(r#"{"ok":true}"#);
        failed.extend(event(json!({"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"fixture-secret PRIVATE"}}})));
        let (url, server) = http_fixture(200, "text/event-stream", failed);
        let error = consume_response(client.post(url).json(&body).send().unwrap())
            .unwrap_err()
            .to_string();
        assert!(error.contains("HTTP 200"));
        assert!(error.contains("subscription_sharing_usage_limit_exceeded"));
        assert!(!error.contains("fixture-secret"));
        assert!(!error.contains("PRIVATE"));
        server.join().unwrap();
    }
    #[test]
    fn actual_http_admission_errors_do_not_redirect_retry_or_echo_private_body() {
        let client = fixture_client();
        let body = request_body("gpt-6-luna", "auto", "prompt", "S", "P", &json!({})).unwrap();
        for (status, bytes, expected) in [
            (401, br#"{"detail":"PRIVATE_MEETING_AND_TOKEN"}"#.to_vec(), "Войдите"),
            (403, br#"{"error":{"code":"subscription_sharing_user_not_eligible","message":"PRIVATE"}}"#.to_vec(), "не поддерживает"),
            (503, br#"{"error":{"code":"subscription_sharing_usage_unavailable","message":"PRIVATE"}}"#.to_vec(), "Подключение сохранено"),
            (302, br#"{"detail":"PRIVATE"}"#.to_vec(), "перенаправление"),
            (400, vec![b'X'; MAX_EVENT_BYTES + 8], "не поддерживает"),
        ] {
            let (url, server) = http_fixture(status, "application/json", bytes);
            let error = consume_response(client.post(url).json(&body).send().unwrap()).unwrap_err().to_string();
            assert!(error.contains(&format!("HTTP {status}"))); assert!(error.contains(expected), "{error}");
            assert!(!error.contains("PRIVATE")); server.join().unwrap();
        }
        let (url, server) = http_fixture(200, "application/json", br#"{"ok":true}"#.to_vec());
        assert!(
            consume_response(client.post(url).json(&body).send().unwrap())
                .unwrap_err()
                .to_string()
                .contains("формат")
        );
        server.join().unwrap();
    }
    fn fixture_client() -> Client {
        Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(std::time::Duration::from_secs(3))
            .build()
            .unwrap()
    }
    fn http_result(client: &Client, mime: &str, bytes: Vec<u8>) -> Result<Value> {
        let (url, server) = http_fixture(200, mime, bytes);
        let body = request_body(
            "gpt-6-luna",
            "none",
            "schema",
            "S",
            "PRIVATE_MEETING",
            &json!({}),
        )
        .unwrap();
        let response = inference_request(client.post(url), "fixture-secret", &body)
            .send()
            .unwrap();
        let result = consume_response(response);
        let (headers, request) = server.join().unwrap();
        assert!(headers.to_lowercase().contains("accept: text/event-stream"));
        assert_eq!(request["model"], "gpt-6-luna");
        assert_eq!(request["stream"], true);
        assert_eq!(request["store"], false);
        assert_eq!(request["reasoning"]["effort"], "none");
        assert!(request["input"].is_array());
        assert!(request.get("max_output_tokens").is_none());
        result
    }
    #[test]
    fn actual_http_completed_responses_json_is_compatible_without_a_second_request() {
        let client = fixture_client();
        let value = response_value(r#"{"overview":"Обсудили пилот","items":[],"cards":[]}"#);
        for mime in [
            "application/json",
            "Application/JSON; charset=utf-8",
            "application/octet-stream",
            "",
        ] {
            let result = http_result(&client, mime, serde_json::to_vec(&value).unwrap()).unwrap();
            assert_eq!(
                result,
                json!({"overview":"Обсудили пилот","items":[],"cards":[]})
            );
        }
    }
    #[test]
    fn actual_http_json_rejects_partial_refused_malformed_and_bare_generated_objects() {
        let client = fixture_client();
        let mut cases = vec![
            json!({"ok":true}),
            json!({"object":"response","status":"completed"}),
            response_value("PRIVATE_NOT_JSON"),
            response_value("[]"),
        ];
        for status in ["queued", "in_progress", "incomplete", "failed", "cancelled"] {
            let mut value = response_value(r#"{"ok":true}"#);
            value["status"] = json!(status);
            cases.push(value);
        }
        let mut value = response_value(r#"{"ok":true}"#);
        value["incomplete_details"] = json!({"reason":"PRIVATE"});
        cases.push(value);
        let mut value = response_value(r#"{"ok":true}"#);
        value["output"][0]["status"] = json!("incomplete");
        cases.push(value);
        let mut value = response_value(r#"{"ok":true}"#);
        value["output"][0]["role"] = json!("user");
        cases.push(value);
        let mut value = response_value(r#"{"ok":true}"#);
        value["output"][0]["type"] = json!("function_call");
        cases.push(value);
        let mut value = response_value("{}");
        value["output"] = json!([]);
        cases.push(value);
        let mut value = response_value("{}");
        value["output"] = json!({"PRIVATE":"not an array"});
        cases.push(value);
        let mut value = response_value("{}");
        value["output"][0]["content"] = json!([{"type":"refusal","refusal":"PRIVATE"}]);
        cases.push(value);
        let mut value = response_value("{}");
        value["output"][0]["content"]
            .as_array_mut()
            .unwrap()
            .push(json!({"type":"refusal","refusal":"PRIVATE"}));
        cases.push(value);
        let mut value = response_value("{}");
        value["output"][0].as_object_mut().unwrap().remove("status");
        cases.push(value);
        for value in cases {
            let error = http_result(
                &client,
                "application/json",
                serde_json::to_vec(&value).unwrap(),
            )
            .unwrap_err()
            .to_string();
            assert!(error.contains("HTTP 200"), "{error}");
            assert!(!error.contains("PRIVATE"));
            assert!(!error.contains("fixture-secret"));
        }
    }
    #[test]
    fn actual_http_json_200_preserves_allowlisted_errors_and_redacts_diagnostics() {
        let client = fixture_client();
        for code in [
            "subscription_sharing_usage_limit_exceeded",
            "subscription_sharing_user_not_eligible",
            "subscription_sharing_usage_unavailable",
        ] {
            for mime in ["application/json", "application/problem+json"] {
                let value =
                    json!({"error":{"code":code,"message":"PRIVATE_MEETING fixture-secret"}});
                let error = http_result(&client, mime, serde_json::to_vec(&value).unwrap())
                    .unwrap_err()
                    .to_string();
                assert!(error.starts_with("ChatGPT: HTTP 200 · "));
                assert!(error.contains(code));
                assert!(!error.contains("PRIVATE"));
                assert!(!error.contains("fixture-secret"));
            }
        }
        let mut value = response_value("{}");
        value["error"] = json!({"code":"PRIVATE_TOKEN","message":"PRIVATE_MEETING"});
        let error = http_result(
            &client,
            "application/json",
            serde_json::to_vec(&value).unwrap(),
        )
        .unwrap_err()
        .to_string();
        assert!(error.contains("request_failed"));
        assert!(!error.contains("PRIVATE"));
    }
    #[test]
    fn actual_http_html_and_unknown_bodies_expose_only_safe_wire_metadata() {
        let client = fixture_client();
        for (mime, bytes, category) in [
            (
                "application/json",
                b"{PRIVATE invalid JSON".to_vec(),
                "application/json",
            ),
            (
                "application/json",
                b"<!doctype html><html>PRIVATE fixture-secret</html>".to_vec(),
                "application/json",
            ),
            (
                "text/html",
                b"<!doctype html><html>PRIVATE fixture-secret</html>".to_vec(),
                "text/html",
            ),
            (
                "text/plain",
                b"PRIVATE fixture-secret".to_vec(),
                "text/plain",
            ),
            (
                "application/PRIVATE_TOKEN",
                b"PRIVATE fixture-secret".to_vec(),
                "other",
            ),
            ("", Vec::new(), "missing"),
        ] {
            let error = http_result(&client, mime, bytes).unwrap_err().to_string();
            assert!(error.contains("HTTP 200"));
            assert!(error.contains(&format!("Content-Type {category}")));
            assert!(!error.contains("PRIVATE"));
            assert!(!error.contains("fixture-secret"));
        }
    }
    #[test]
    fn actual_http_mislabeled_or_missing_sse_mime_preserves_the_terminal_contract() {
        let client = fixture_client();
        for mime in [
            "text/plain",
            "application/octet-stream",
            "application/json",
            "",
            "TEXT/EVENT-STREAM; charset=UTF-8",
        ] {
            let mut stream = b"\xef\xbb\xbf\n \r\n: keepalive\n\n".to_vec();
            stream.extend(delta(r#"{"ok":true}"#));
            stream.extend(completed(r#"{"ok":true}"#));
            assert_eq!(
                http_result(&client, mime, stream).unwrap(),
                json!({"ok":true})
            );
            let error = http_result(&client, mime, delta(r#"{"ok":true}"#))
                .unwrap_err()
                .to_string();
            assert!(error.contains("response.completed"));
            assert!(error.contains("HTTP 200"));
            let mut failed = delta(r#"{"ok":true}"#);
            failed.extend(event(json!({"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"PRIVATE"}}})));
            let error = http_result(&client, mime, failed).unwrap_err().to_string();
            assert!(error.contains("subscription_sharing_usage_limit_exceeded"));
            assert!(!error.contains("PRIVATE"));
            let refusal = event(json!({"type":"response.refusal.delta","delta":"PRIVATE"}));
            assert!(http_result(&client, mime, refusal)
                .unwrap_err()
                .to_string()
                .contains("отказался"));
        }
    }
    #[test]
    fn actual_http_missing_mime_keeps_done_text_until_compact_response_completed() {
        let client = fixture_client();
        for output in [
            None,
            Some(json!([])),
            Some(json!([{"type":"reasoning","summary":[]}])),
        ] {
            for snapshot in finalized_text_events(r#"{"ok":true}"#) {
                let mut stream = delta("partial");
                stream.extend(snapshot);
                stream.extend(compact_terminal(output.clone()));
                assert_eq!(
                    http_result(&client, "", stream).unwrap(),
                    json!({"ok":true})
                );
            }
        }
        let mut stream = delta(r#"{"ok":true}"#);
        stream.extend(compact_terminal(Some(json!([]))));
        assert_eq!(
            http_result(&client, "", stream).unwrap(),
            json!({"ok":true})
        );
        for bytes in [
            finalized_text_events(r#"{"ok":true}"#).remove(0),
            compact_terminal(Some(json!([]))),
            serde_json::to_vec(&json!({"object":"response","status":"completed","output":[]}))
                .unwrap(),
        ] {
            assert!(http_result(&client, "", bytes).is_err());
        }
        let mut malformed_answer = finalized_text_events("[]").remove(0);
        malformed_answer.extend(compact_terminal(Some(json!([]))));
        assert!(http_result(&client, "", malformed_answer)
            .unwrap_err()
            .to_string()
            .contains("объекта"));
    }
    #[test]
    fn typed_failure_diagnostics_contain_only_fixed_shapes_and_counters() {
        let client = fixture_client();
        const CANARY: &str = "PRIVATE_MEETING_fixture-secret_ACCESS_TOKEN";
        let mut stream = event(json!({"type":CANARY,"private":CANARY}));
        stream.extend(delta(CANARY));
        for snapshot in finalized_text_events(CANARY) {
            stream.extend(snapshot);
        }
        stream.extend(compact_terminal(Some(json!([]))));
        let error = http_result(&client, "", stream.clone()).unwrap_err();
        assert!(!error.to_string().contains(CANARY));
        let diagnostics = error_diagnostics(&error).unwrap();
        let serialized = serde_json::to_string(diagnostics).unwrap();
        assert!(!serialized.contains(CANARY));
        assert!(!serialized.contains("fixture-secret"));
        assert_eq!(diagnostics.http_status, 200);
        assert_eq!(diagnostics.content_type, "missing");
        assert_eq!(diagnostics.wire, "sse");
        assert_eq!(diagnostics.response_bytes, stream.len());
        assert_eq!(diagnostics.events, 6);
        assert_eq!(diagnostics.output_text_delta, 1);
        assert_eq!(diagnostics.output_text_done, 1);
        assert_eq!(diagnostics.content_part_done, 1);
        assert_eq!(diagnostics.output_item_done, 1);
        assert_eq!(diagnostics.completed, 1);
        assert_eq!(diagnostics.other_events, 1);
        assert_eq!(diagnostics.terminal_status, "completed");
        assert_eq!(diagnostics.terminal_output, "array");
        assert_eq!(diagnostics.terminal_output_items, 0);
        assert_eq!(diagnostics.accumulated_text_bytes, CANARY.len());
        let mut value = response_value(CANARY);
        value["output"][0]["content"]
            .as_array_mut()
            .unwrap()
            .extend([
                json!({"type":"refusal","refusal":CANARY}),
                json!({"type":CANARY,"text":CANARY}),
            ]);
        value["status"] = json!(CANARY);
        let error = http_result(
            &client,
            "application/PRIVATE_TOKEN",
            serde_json::to_vec(&value).unwrap(),
        )
        .unwrap_err();
        let diagnostics = error_diagnostics(&error).unwrap();
        assert_eq!(diagnostics.content_type, "other");
        assert_eq!(diagnostics.wire, "json");
        assert_eq!(diagnostics.terminal_status, "other");
        assert_eq!(diagnostics.terminal_output_items, 1);
        assert_eq!(diagnostics.terminal_text_parts, 1);
        assert_eq!(diagnostics.terminal_refusal_parts, 1);
        assert_eq!(diagnostics.terminal_other_parts, 1);
        assert!(!serde_json::to_string(diagnostics)
            .unwrap()
            .contains("PRIVATE"));
        assert!(!error.to_string().contains("PRIVATE"));
        let mut failed = delta("{}");
        failed.extend(event(json!({"type":"response.failed","response":{"status":"failed","error":{"code":"subscription_sharing_usage_limit_exceeded","message":CANARY}}})));
        let error = http_result(&client, "", failed).unwrap_err();
        assert!(error
            .to_string()
            .starts_with("ChatGPT: HTTP 200 · subscription_sharing_usage_limit_exceeded."));
        assert_eq!(error_diagnostics(&error).unwrap().terminal_status, "failed");
        assert!(!serde_json::to_string(error_diagnostics(&error).unwrap())
            .unwrap()
            .contains("PRIVATE"));
    }
    #[test]
    fn test_transport_scope_is_loopback_only_and_restored_after_panic() {
        assert!(TEST_TRANSPORT.with(|transport| transport.borrow().is_none()));
        let result = std::panic::catch_unwind(|| {
            with_test_transport(
                fixture_client(),
                "http://127.0.0.1:49152/v1/responses".parse().unwrap(),
                || {
                    assert!(TEST_TRANSPORT.with(|transport| transport.borrow().is_some()));
                    panic!("fixture cancellation");
                },
            );
        });
        assert!(result.is_err());
        assert!(TEST_TRANSPORT.with(|transport| transport.borrow().is_none()));
        for endpoint in [
            "https://api.openai.com/v1/responses",
            "http://example.com:49152/v1/responses",
            "http://127.0.0.1:49152/other",
            "http://token@127.0.0.1:49152/v1/responses",
            "http://127.0.0.1:49152/v1/responses?token=PRIVATE",
        ] {
            assert!(std::panic::catch_unwind(|| {
                with_test_transport(fixture_client(), endpoint.parse().unwrap(), || {
                    panic!("must not run")
                });
            })
            .is_err());
        }
        assert!(TEST_TRANSPORT.with(|transport| transport.borrow().is_none()));
    }

    #[test]
    fn sniffing_is_bounded_and_handles_fragmented_bom_and_field_names() {
        struct OneByte(Cursor<Vec<u8>>);
        impl Read for OneByte {
            fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
                self.0.read(&mut buffer[..1])
            }
        }
        for bytes in [
            b"\xef\xbb\xbf  \n event: response.completed\n".to_vec(),
            b"data: {}\n".to_vec(),
            b": comment\n".to_vec(),
            b"id: 123\n".to_vec(),
            b"retry: 100\n".to_vec(),
        ] {
            let (_, format) = sniff_response(&mut OneByte(Cursor::new(bytes))).unwrap();
            assert_eq!(format, WireFormat::Events);
        }
        let mut source = Cursor::new(vec![b' '; 5000]);
        assert_eq!(sniff_response(&mut source).unwrap().1, WireFormat::Unknown);
        assert_eq!(source.position(), 4096);
    }
    #[test]
    fn actual_http_complete_json_and_answer_size_limits_remain_bounded() {
        let client = fixture_client();
        let value = response_value(&"x".repeat(MAX_ANSWER_BYTES + 1));
        assert!(http_result(
            &client,
            "application/json",
            serde_json::to_vec(&value).unwrap()
        )
        .unwrap_err()
        .to_string()
        .contains("размер"));
        let mut bytes = b"{".to_vec();
        bytes.resize(MAX_STREAM_BYTES + 1, b' ');
        assert!(http_result(&client, "application/json", bytes)
            .unwrap_err()
            .to_string()
            .contains("размер"));
    }
    #[test]
    fn subscription_errors_have_specific_recovery_and_never_leak_body() {
        for (code, hint) in [
            ("subscription_sharing_usage_limit_exceeded", "Использование"),
            ("subscription_sharing_user_not_eligible", "не поддерживает"),
            (
                "subscription_sharing_usage_unavailable",
                "Подключение сохранено",
            ),
            ("subscription_sharing_invalid_user", "Войдите"),
        ] {
            let stream = event(
                json!({"type":"response.failed","response":{"error":{"code":code,"message":"SECRET_MEETING_AND_TOKEN"}}}),
            );
            let error = read_stream(&mut Cursor::new(stream), StatusCode::OK)
                .unwrap_err()
                .to_string();
            assert!(error.contains(code));
            assert!(error.contains(hint));
            assert!(!error.contains("SECRET"));
        }
        assert!(request_error(StatusCode::UNAUTHORIZED, None)
            .to_string()
            .contains("Войдите"));
        assert!(
            !request_error(StatusCode::BAD_REQUEST, Some("PRIVATE_PROMPT"))
                .to_string()
                .contains("PRIVATE_PROMPT")
        );
    }
}

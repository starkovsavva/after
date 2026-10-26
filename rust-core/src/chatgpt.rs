//! ChatGPT plan usage is a distinct credential and billing route. Keep its
//! public endpoint and streaming contract separate from API-key providers.
use anyhow::{bail, Result};
use reqwest::blocking::{Client, Response};
use reqwest::StatusCode;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::io::Read;

pub(crate) const RESPONSES_ENDPOINT: &str = "https://api.openai.com/v1/responses";
const MAX_STREAM_BYTES: usize = 8 * 1024 * 1024;
const MAX_EVENT_BYTES: usize = 1024 * 1024;
const MAX_ANSWER_BYTES: usize = 4 * 1024 * 1024;

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

pub(crate) fn generate(client: &Client, access_token: &str, body: &Value) -> Result<Value> {
    if access_token.trim().is_empty() {
        bail!("Войдите через ChatGPT в настройках конспекта и карточек.");
    }
    // The client disables redirects; no endpoint override or alternate billing
    // path is accepted here. A failed inference is never automatically retried.
    let response = client
        .post(RESPONSES_ENDPOINT)
        .bearer_auth(access_token.trim())
        .json(body)
        .send()
        .map_err(|_| {
            anyhow::anyhow!("Нет ответа от ChatGPT. Проверьте соединение; подключение сохранено.")
        })?;
    consume_response(response)
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
        .unwrap_or("");
    if !media_type.trim().eq_ignore_ascii_case("text/event-stream") {
        bail!("ChatGPT вернул неожиданный формат ответа. Ожидался поток Responses; исходные данные сохранены.");
    }
    let answer = read_stream(&mut response, status)?;
    serde_json::from_str(&answer)
        .map_err(|_| anyhow::anyhow!("ChatGPT вернул ответ неподходящего формата JSON. Проверьте формат ответа; исходные данные сохранены."))
}

fn read_stream(reader: &mut impl Read, http_status: StatusCode) -> Result<String> {
    let mut parser = EventStream::new(MAX_STREAM_BYTES, MAX_EVENT_BYTES, MAX_ANSWER_BYTES);
    parser.http_status = http_status;
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        let count = reader.read(&mut buffer).map_err(|_| {
            anyhow::anyhow!("Ответ ChatGPT прервался. Исходные данные сохранены; повторите позже.")
        })?;
        if count == 0 {
            return parser.finish();
        }
        if let Some(answer) = parser.feed(&buffer[..count])? {
            return Ok(answer);
        }
    }
}

/// Incremental SSE framing stores bytes until complete lines/events, so UTF-8
/// characters may safely cross arbitrary network boundaries. All allocations
/// are bounded independently of a server's newline or terminal-event behavior.
struct EventStream {
    http_status: StatusCode,
    total: usize,
    max_total: usize,
    max_event: usize,
    max_answer: usize,
    line: Vec<u8>,
    event_data: Vec<u8>,
    event_name: Vec<u8>,
    data_seen: bool,
    skip_lf: bool,
    deltas: BTreeMap<(u64, u64), String>,
    delta_bytes: usize,
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
            event_data: Vec::new(),
            event_name: Vec::new(),
            data_seen: false,
            skip_lf: false,
            deltas: BTreeMap::new(),
            delta_bytes: 0,
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
        let line = std::mem::take(&mut self.line);
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
        match kind {
            "response.output_text.delta" => {
                let delta = event["delta"]
                    .as_str()
                    .ok_or_else(|| anyhow::anyhow!("ChatGPT вернул некорректную часть текста."))?;
                self.delta_bytes = self
                    .delta_bytes
                    .checked_add(delta.len())
                    .ok_or_else(|| anyhow::anyhow!("Ответ ChatGPT превышает допустимый размер."))?;
                if self.delta_bytes > self.max_answer {
                    bail!("Ответ ChatGPT превышает допустимый размер.");
                }
                let index = (
                    event["output_index"].as_u64().unwrap_or(0),
                    event["content_index"].as_u64().unwrap_or(0),
                );
                self.deltas.entry(index).or_default().push_str(delta);
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
                let response = &event["response"];
                if response["status"] != "completed"
                    || response.get("error").is_some_and(|error| !error.is_null())
                {
                    bail!("ChatGPT не подтвердил завершение ответа. Исходные данные сохранены.");
                }
                let mut text = String::new();
                if let Some(output) = response.get("output") {
                    let output = output.as_array().ok_or_else(|| {
                        anyhow::anyhow!("ChatGPT вернул некорректный результат Responses.")
                    })?;
                    for item in output {
                        if item
                            .get("status")
                            .is_some_and(|status| status != "completed")
                        {
                            bail!("ChatGPT не закончил часть ответа. Исходные данные сохранены.");
                        }
                        for part in item["content"].as_array().into_iter().flatten() {
                            match part["type"].as_str() {
                                Some("refusal") => bail!("ChatGPT отказался обработать запрос. Исходные данные сохранены."),
                                Some("output_text") => {
                                    let part = part["text"].as_str().ok_or_else(|| anyhow::anyhow!("ChatGPT вернул некорректный текст результата."))?;
                                    if text.len() + part.len() > self.max_answer { bail!("Ответ ChatGPT превышает допустимый размер."); }
                                    text.push_str(part);
                                },
                                _ => {},
                            }
                        }
                    }
                }
                if response.get("output").is_none() {
                    // A compact terminal may omit the full output, but an
                    // explicitly empty/malformed final output is authoritative.
                    text = std::mem::take(&mut self.deltas).into_values().collect();
                }
                if text.trim().is_empty() {
                    bail!("ChatGPT завершил запрос без текста ответа.");
                }
                return Ok(Some(text));
            }
            _ => {}
        }
        Ok(None)
    }
    fn finish(self) -> Result<String> {
        bail!("Ответ ChatGPT прервался без response.completed. Исходные данные сохранены; повторите позже.")
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
    fn completed(text: &str) -> Vec<u8> {
        event(
            json!({"type":"response.completed","response":{"status":"completed","output":[{"type":"message","status":"completed","content":[{"type":"output_text","text":text}]}]}}),
        )
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
        let bytes = b"event: response.completed\rdata: {\"type\":\"response.completed\",\rdata: \"response\":{\"status\":\"completed\",\"output\":[{\"content\":[{\"type\":\"output_text\",\"text\":\"{}\"}]}]}}\r\r";
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
        assert!(
            read_stream(&mut Cursor::new(stream), StatusCode::OK).is_err(),
            "explicitly empty final output must not publish earlier deltas"
        );
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
            write!(stream, "HTTP/1.1 {status} fixture\r\nContent-Type: {media_type}\r\nContent-Length: {}\r\n{redirect}Connection: close\r\n\r\n", body.len()).unwrap();
            // Small writes also exercise HTTP buffering without relying on
            // the operating system preserving packet boundaries.
            for chunk in body.chunks(97) {
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
        let client = Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(std::time::Duration::from_secs(3))
            .build()
            .unwrap();
        let body =
            request_body("gpt-6-luna", "none", "prompt", "S", "PRIVATE", &json!({})).unwrap();
        let mut successful = delta(r#"{"ok":true}"#);
        successful.extend(completed(r#"{"ok":true}"#));
        let (url, server) = http_fixture(200, "text/event-stream; charset=utf-8", successful);
        let response = client
            .post(url)
            .bearer_auth("fixture-secret")
            .json(&body)
            .send()
            .unwrap();
        assert_eq!(consume_response(response).unwrap(), json!({"ok":true}));
        let (headers, request) = server.join().unwrap();
        assert!(headers
            .to_lowercase()
            .contains("authorization: bearer fixture-secret"));
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
        let client = Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(std::time::Duration::from_secs(3))
            .build()
            .unwrap();
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

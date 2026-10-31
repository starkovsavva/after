//! Disposable bounded cosine index over canonical, revalidated sources. No
//! vector server, Python process, implicit downloads or API keys on disk.
use anyhow::{ensure, Context, Result};
use reqwest::{blocking::Client, redirect::Policy, Url};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::fs::{self, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;
const MAX_DOCS: usize = 10_000;
const CHUNK_BYTES: usize = 3000;
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields, rename_all = "camelCase")]
pub struct Config {
    pub enabled: bool,
    pub provider: String,
    pub endpoint: String,
    pub model: String,
    pub model_revision: String,
    pub dimensions: usize,
    pub query_prefix: String,
    pub document_prefix: String,
    pub allow_cloud: bool,
}
impl Default for Config {
    fn default() -> Self {
        Self{enabled:false,provider:"managed".into(),endpoint:String::new(),model:"qwen3-embedding:0.6b".into(),model_revision:String::new(),dimensions:1024,query_prefix:"Instruct: Given a search query, retrieve relevant passages from personal notes, tasks, meetings and code.\nQuery: ".into(),document_prefix:String::new(),allow_cloud:false}
    }
}
#[derive(Clone, Debug)]
pub(crate) struct EmbeddingDocument {
    pub id: String,
    pub content_hash: String,
    pub text: String,
    pub source: Value,
    pub cloud_allowed: bool,
}
impl EmbeddingDocument {
    pub(crate) fn new(id: String, text: String, source: Value, cloud_allowed: bool) -> Self {
        let content_hash = hash(&json!([text, source]));
        Self {
            id,
            content_hash,
            text,
            source,
            cloud_allowed,
        }
    }
}
fn hash(value: &Value) -> String {
    format!("{:x}", Sha256::digest(value.to_string().as_bytes()))
}
fn private(path: &Path) -> Result<()> {
    if let Ok(m) = fs::symlink_metadata(path) {
        ensure!(
            m.is_dir() && !m.file_type().is_symlink(),
            "Индекс не должен быть ссылкой"
        );
    }
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)?;
    Ok(())
}
fn folder(root: &Path) -> Result<PathBuf> {
    ensure!(root.is_absolute(), "Нужен абсолютный путь библиотеки");
    private(root)?;
    let cache = root.join("cache");
    private(&cache)?;
    let dir = cache.join("semantic");
    private(&dir)?;
    Ok(dir)
}
fn safe_file(path: &Path) -> Result<fs::File> {
    if let Ok(m) = fs::symlink_metadata(path) {
        ensure!(
            m.is_file() && !m.file_type().is_symlink(),
            "Индекс не должен быть ссылкой"
        );
    }
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    file.set_permissions(fs::Permissions::from_mode(0o600))?;
    Ok(file)
}
fn connection(root: &Path) -> Result<Connection> {
    let dir = folder(root)?;
    let path = dir.join("index.sqlite");
    drop(safe_file(&path)?);
    for suffix in ["-journal", "-wal", "-shm"] {
        let p = dir.join(format!("index.sqlite{suffix}"));
        if p.exists() {
            drop(safe_file(&p)?);
        }
    }
    let c = Connection::open(path)?;
    c.busy_timeout(Duration::from_secs(2))?;
    c.execute_batch("PRAGMA secure_delete=ON;PRAGMA journal_mode=DELETE;
    CREATE TABLE IF NOT EXISTS generations(id TEXT PRIMARY KEY,manifest TEXT NOT NULL,complete INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS vectors(generation TEXT NOT NULL,id TEXT NOT NULL,content_hash TEXT NOT NULL,source TEXT NOT NULL,vector BLOB NOT NULL,PRIMARY KEY(generation,id));
    CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY,value TEXT NOT NULL);")?;
    Ok(c)
}
fn config_path(root: &Path) -> PathBuf {
    root.join("semantic-settings.json")
}
pub fn config(root: &Path) -> Result<Config> {
    let path = config_path(root);
    if !path.exists() {
        return Ok(Config::default());
    }
    let mut f = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    ensure!(
        f.metadata()?.len() <= 16384,
        "Настройки индекса слишком большие"
    );
    let mut b = Vec::new();
    (&mut f).take(16385).read_to_end(&mut b)?;
    ensure!(b.len() <= 16384, "Настройки индекса слишком большие");
    let c: Config = serde_json::from_slice(&b)?;
    validate(&c)?;
    Ok(c)
}
fn endpoint(c: &Config) -> Result<Url> {
    if c.provider == "managed" {
        return Ok(Url::parse("http://127.0.0.1/").unwrap());
    }
    let url = Url::parse(c.endpoint.trim()).context("Неверный адрес модели поиска")?;
    ensure!(
        !url.cannot_be_a_base()
            && url.host_str().is_some()
            && url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none()
            && url.fragment().is_none(),
        "Адрес не должен содержать пароль или параметры"
    );
    let local = is_local(&url);
    ensure!(
        url.scheme() == "https" || (url.scheme() == "http" && local),
        "Нужен HTTPS или localhost"
    );
    ensure!(
        local || c.allow_cloud,
        "Отправка текстов в облачную модель поиска не разрешена"
    );
    Ok(url)
}
fn is_local(url: &Url) -> bool {
    matches!(
        url.host_str(),
        Some("localhost" | "127.0.0.1" | "[::1]" | "::1")
    )
}
fn validate(c: &Config) -> Result<()> {
    if c.provider == "managed" {
        ensure!(
            c.endpoint.is_empty()
                && !c.allow_cloud
                && c.model == crate::managed_embeddings::MODEL
                && c.dimensions == 1024
                && (c.model_revision.is_empty()
                    || c.model_revision == crate::managed_embeddings::REVISION),
            "Неверные настройки встроенной модели поиска"
        );
    }
    endpoint(c)?;
    ensure!(
        ["managed", "ollama", "openai"].contains(&c.provider.as_str()),
        "Неизвестный API embeddings"
    );
    ensure!(
        !c.model.trim().is_empty()
            && c.model.len() <= 256
            && !c.model.chars().any(char::is_control),
        "Укажите ID embedding-модели"
    );
    ensure!(
        (2..=4096).contains(&c.dimensions),
        "Размерность от 2 до 4096"
    );
    ensure!(
        c.model_revision.len() <= 256
            && c.query_prefix.len() <= 1024
            && c.document_prefix.len() <= 1024,
        "Слишком длинный manifest модели"
    );
    Ok(())
}
fn manifest(c: &Config) -> String {
    hash(
        &json!({"format":1,"model":c.model,"revision":c.model_revision,"endpoint":c.endpoint,"provider":c.provider,"dimensions":c.dimensions,"normalization":"l2-f32-le","chunker":"utf8-3000-v1","query":c.query_prefix,"document":c.document_prefix,"allowCloud":c.allow_cloud}),
    )
}
/// A credential belongs to the exact endpoint/model/consent snapshot that
/// native code read from Keychain. Reject a stale caller BEFORE any request.
fn credential_binding(c: &Config, key: &str, binding: Option<&str>) -> Result<()> {
    if let Some(expected) = binding {
        ensure!(
            expected == manifest(c),
            "Настройки модели поиска изменились. Повторите запрос."
        );
    } else {
        ensure!(
            key.is_empty(),
            "Для ключа поиска нужна версия настроек. Повторите запрос."
        );
    }
    Ok(())
}
fn supplied_binding<'a>(input: &'a Value, explicit: bool, computed: &'a str) -> Option<&'a str> {
    input["configFingerprint"]
        .as_str()
        .or(if explicit { Some(computed) } else { None })
}
fn client(timeout: u64) -> Result<Client> {
    Ok(Client::builder()
        .timeout(Duration::from_secs(timeout))
        .connect_timeout(Duration::from_secs(5))
        .redirect(Policy::none())
        .no_proxy()
        .build()?)
}
fn api_url(c: &Config, suffix: &str) -> Result<String> {
    let mut url = endpoint(c)?;
    let base = url.path().trim_end_matches('/');
    url.set_path(&format!("{base}/{suffix}"));
    Ok(url.to_string())
}
fn response(mut r: reqwest::blocking::Response) -> Result<Value> {
    ensure!(
        r.status().is_success(),
        "Модель поиска вернула HTTP {}",
        r.status().as_u16()
    );
    ensure!(
        r.content_length().is_none_or(|n| n <= 2 * 1024 * 1024),
        "Ответ embeddings слишком большой"
    );
    let mut bytes = Vec::new();
    (&mut r).take(2 * 1024 * 1024 + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= 2 * 1024 * 1024,
        "Ответ embeddings слишком большой"
    );
    serde_json::from_slice(&bytes).context("Модель вернула неверный JSON embeddings")
}
fn authenticated(
    r: reqwest::blocking::RequestBuilder,
    key: &str,
) -> Result<reqwest::blocking::RequestBuilder> {
    ensure!(
        key.len() <= 8192 && !key.chars().any(char::is_control),
        "Некорректный ключ модели поиска"
    );
    Ok(if key.is_empty() {
        r
    } else {
        r.bearer_auth(key)
    })
}
fn ollama_revision(c: &Config, key: &str) -> Result<String> {
    let data = response(
        authenticated(client(10)?.get(api_url(c, "api/tags")?), key)?
            .send()
            .context("Не удалось подключиться к Ollama")?,
    )?;
    data["models"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|m| m["name"].as_str() == Some(&c.model) || m["model"].as_str() == Some(&c.model))
        .and_then(|m| m["digest"].as_str())
        .filter(|s| !s.is_empty() && s.len() <= 256)
        .map(str::to_owned)
        .context("Модель поиска не установлена в Ollama")
}
fn normalize(values: &Value, dimensions: usize) -> Result<Vec<f32>> {
    let a = values.as_array().context("Нет вектора embeddings")?;
    ensure!(
        a.len() == dimensions,
        "Модель вернула размерность {}, ожидалась {}",
        a.len(),
        dimensions
    );
    let mut v = a
        .iter()
        .map(|n| {
            n.as_f64()
                .filter(|x| x.is_finite() && x.abs() <= 1e20)
                .map(|x| x as f32)
                .context("Невалидное число embeddings")
        })
        .collect::<Result<Vec<_>>>()?;
    let norm = v.iter().map(|x| (*x as f64).powi(2)).sum::<f64>().sqrt();
    ensure!(
        norm.is_finite() && norm > 1e-12,
        "Модель вернула нулевой вектор"
    );
    for x in &mut v {
        *x = (*x as f64 / norm) as f32;
    }
    Ok(v)
}
fn embed(
    root: &Path,
    c: &Config,
    texts: &[String],
    query: bool,
    key: &str,
) -> Result<Vec<Vec<f32>>> {
    embed_request(root, c, texts, query, key, false)
}
fn embed_request(
    root: &Path,
    c: &Config,
    texts: &[String],
    query: bool,
    key: &str,
    discover_dimensions: bool,
) -> Result<Vec<Vec<f32>>> {
    validate(c)?;
    ensure!(
        !texts.is_empty() && texts.len() <= 8 && texts.iter().all(|s| s.len() <= 5000),
        "Слишком большой пакет embeddings"
    );
    if c.provider == "ollama" {
        ensure!(
            ollama_revision(c, key)? == c.model_revision,
            "Embedding-модель изменилась. Проверьте подключение и перестройте индекс"
        );
    }
    let prefix = if query {
        &c.query_prefix
    } else {
        &c.document_prefix
    };
    let inputs = texts
        .iter()
        .map(|s| format!("{prefix}{s}"))
        .collect::<Vec<_>>();
    let (url, mut body) = if c.provider == "ollama" {
        (
            api_url(c, "api/embed")?,
            json!({"model":c.model,"input":inputs,"truncate":false,"keep_alive":"30s","dimensions":c.dimensions}),
        )
    } else {
        (
            if c.provider == "managed" {
                String::new()
            } else {
                api_url(c, "embeddings")?
            },
            json!({"model":c.model,"input":inputs,"encoding_format":"float","dimensions":c.dimensions}),
        )
    };
    if discover_dimensions {
        body.as_object_mut().unwrap().remove("dimensions");
    }
    let data = if c.provider == "managed" {
        ensure!(key.is_empty(), "Встроенная модель не использует API-ключ");
        ensure!(
            c.model_revision == crate::managed_embeddings::REVISION,
            "Проверьте встроенную модель перед поиском"
        );
        crate::managed_embeddings::embed(root, &inputs, || {
            !crate::ai::live_features(root).is_ok_and(|f| f.semantic_search)
                || (!discover_dimensions
                    && !config(root)
                        .is_ok_and(|saved| saved.enabled && manifest(&saved) == manifest(c)))
        })?
    } else {
        response(
            authenticated(
                client(if query { 15 } else { 45 })?.post(url).json(&body),
                key,
            )?
            .send()
            .context("Embedding-модель недоступна; текстовый поиск продолжает работать")?,
        )?
    };
    let vectors = if c.provider == "ollama" {
        data["embeddings"]
            .as_array()
            .context("Нет embeddings в ответе")?
            .clone()
    } else {
        let rows = data["data"].as_array().context("Нет data embeddings")?;
        ensure!(rows.len() == texts.len(), "Неверное количество embeddings");
        let mut slots = vec![None; texts.len()];
        for row in rows {
            let index = row["index"].as_u64().context("Нет индекса embeddings")? as usize;
            ensure!(
                index < slots.len() && slots[index].is_none(),
                "Повторный индекс embeddings"
            );
            slots[index] = Some(row["embedding"].clone());
        }
        slots
            .into_iter()
            .map(|v| v.context("Пропущен embedding"))
            .collect::<Result<Vec<_>>>()?
    };
    ensure!(
        vectors.len() == texts.len(),
        "Неверное количество embeddings"
    );
    let dimensions = if discover_dimensions {
        vectors
            .first()
            .and_then(Value::as_array)
            .map(Vec::len)
            .context("Нет размерности embeddings")?
    } else {
        c.dimensions
    };
    ensure!(
        (2..=4096).contains(&dimensions),
        "Модель поиска должна возвращать от 2 до 4096 измерений"
    );
    vectors.iter().map(|v| normalize(v, dimensions)).collect()
}
fn blob(v: &[f32]) -> Vec<u8> {
    v.iter().flat_map(|x| x.to_le_bytes()).collect()
}
fn decode(bytes: &[u8], dim: usize) -> Result<Vec<f32>> {
    ensure!(bytes.len() == dim * 4, "Повреждён вектор индекса");
    let v = bytes
        .chunks_exact(4)
        .map(|b| f32::from_le_bytes(b.try_into().unwrap()))
        .collect::<Vec<_>>();
    ensure!(v.iter().all(|x| x.is_finite()), "Повреждён вектор индекса");
    Ok(v)
}
pub(crate) fn chunk_source(
    id: &str,
    text: &str,
    source: &Value,
    cloud: bool,
) -> Vec<EmbeddingDocument> {
    let mut docs = Vec::new();
    let mut start = 0;
    let mut chunk = 0;
    while start < text.len() {
        let mut end = (start + CHUNK_BYTES).min(text.len());
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        let content = &text[start..end];
        let mut s = source.clone();
        s["excerpt"] = json!(content);
        docs.push(EmbeddingDocument::new(
            format!("{id}:{chunk}"),
            format!("{}\n{}", source["title"].as_str().unwrap_or(""), content),
            s,
            cloud,
        ));
        start = end;
        chunk += 1;
    }
    docs
}
fn enabled_features(root: &Path) -> Result<crate::ai::AppFeatures> {
    let features = crate::ai::live_features(root)?;
    ensure!(
        features.semantic_search,
        "Включите «Смысловой поиск» в настройках → Возможности."
    );
    Ok(features)
}
fn unchanged_features(root: &Path, expected: &crate::ai::AppFeatures) -> Result<()> {
    let current = enabled_features(root)?;
    ensure!(
        current.cards == expected.cards && current.tasks == expected.tasks,
        "Настройки возможностей изменились: обновление индекса остановлено."
    );
    Ok(())
}
fn corpus(root: &Path, c: &Config) -> Result<(Vec<EmbeddingDocument>, Vec<String>)> {
    let features = enabled_features(root)?;
    let (mut docs, mut warnings) = crate::knowledge::embedding_documents(root)?;
    if features.tasks {
        let (code, code_warnings) = crate::code_index::semantic_documents(root)?;
        docs.extend(code);
        warnings.extend(code_warnings);
    }
    if !is_local(&endpoint(c)?) {
        docs.retain(|d| d.cloud_allowed);
    }
    docs.sort_by(|a, b| a.id.cmp(&b.id));
    docs.dedup_by(|a, b| a.id == b.id);
    if docs.len() > MAX_DOCS {
        docs.truncate(MAX_DOCS);
        warnings.push("Индекс ограничен первыми 10000 фрагментами; текстовый поиск остаётся доступен для остальных.".into());
    }
    Ok((docs, warnings))
}
fn current(root: &Path, s: &Value) -> bool {
    if !crate::ai::live_features_for_input(root, s).is_ok_and(|features| features.semantic_search) {
        return false;
    }
    if s["kind"] == "code" {
        crate::code_index::source_current(root, s).unwrap_or(false)
    } else {
        crate::knowledge::validate_source(root, &json!({"source":s}))
            .is_ok_and(|v| v["valid"] == true)
    }
}
fn generation(c: &Config, docs: &[EmbeddingDocument]) -> String {
    hash(&json!([
        manifest(c),
        docs.iter()
            .map(|d| (&d.id, &d.content_hash))
            .collect::<Vec<_>>()
    ]))
}

/// Reuse only an already published index. This path never generates embeddings,
/// contacts a provider or expands the caller's explicitly permitted note set.
/// Source fingerprints fence old vectors; the caller also rechecks workspace
/// and policy revisions after ranking. Four chunks per note bound CPU and RAM.
fn cached_note_vectors(
    root: &Path,
    allowed: &BTreeMap<String, String>,
) -> Result<Option<(BTreeMap<String, Vec<Vec<f32>>>, String)>> {
    if !crate::ai::live_features(root)?.semantic_search {
        return Ok(None);
    }
    let c = config(root)?;
    if !c.enabled || allowed.is_empty() {
        return Ok(None);
    }
    let cache = root.join("cache");
    let directory = cache.join("semantic");
    for path in [&cache, &directory] {
        match fs::symlink_metadata(path) {
            Ok(meta) => ensure!(
                meta.is_dir() && !meta.file_type().is_symlink(),
                "Некорректный индекс поиска"
            ),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.into()),
        }
    }
    let path = directory.join("index.sqlite");
    match fs::symlink_metadata(&path) {
        Ok(meta) => ensure!(
            meta.is_file() && !meta.file_type().is_symlink(),
            "Некорректный индекс поиска"
        ),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.into()),
    }
    for suffix in ["-journal", "-wal", "-shm"] {
        match fs::symlink_metadata(directory.join(format!("index.sqlite{suffix}"))) {
            Ok(meta) => ensure!(
                meta.is_file() && !meta.file_type().is_symlink(),
                "Некорректные файлы индекса поиска"
            ),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
    }
    let db = Connection::open_with_flags(
        &path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    db.busy_timeout(Duration::from_secs(2))?;
    let active: Option<(String,String)> = db.query_row("SELECT g.id,g.manifest FROM generations g JOIN state s ON s.value=g.id WHERE s.key='active' AND g.complete=1", [], |r| Ok((r.get(0)?,r.get(1)?))).optional()?;
    let Some((generation, expected_manifest)) = active else {
        return Ok(None);
    };
    if expected_manifest != manifest(&c) {
        return Ok(None);
    }
    let mut statement =
        db.prepare("SELECT source,vector FROM vectors WHERE generation=?1 ORDER BY id LIMIT ?2")?;
    let rows = statement.query_map(params![generation, MAX_DOCS as i64], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, Vec<u8>>(1)?))
    })?;
    let mut vectors: BTreeMap<String, Vec<Vec<f32>>> = BTreeMap::new();
    for row in rows {
        let (source, bytes) = row?;
        let s: Value = serde_json::from_str(&source)?;
        if s["kind"] != "note" {
            continue;
        }
        let Some(id) = s["noteID"].as_str() else {
            continue;
        };
        if allowed.get(id).map(String::as_str) != s["sourceFingerprint"].as_str() {
            continue;
        }
        let chunks = vectors.entry(id.to_owned()).or_default();
        if chunks.len() < 4 {
            chunks.push(decode(&bytes, c.dimensions)?);
        }
    }
    let latest = config(root)?;
    ensure!(
        latest.enabled
            && manifest(&latest) == expected_manifest
            && crate::ai::live_features(root)?.semantic_search,
        "Настройки смыслового поиска изменились. Обновите подсказки."
    );
    Ok(Some((vectors, expected_manifest)))
}

/// Cached, fresh vectors for the caller's permitted library snapshot. Typed
/// keys distinguish notes from meetings; title-only vectors are never included.
/// One normalized centroid is retained per source, bounded to four note chunks
/// and sixteen transcript/summary chunks. No inference or download occurs here.
pub(crate) fn cached_library_centroids(
    root: &Path,
    allowed_notes: &BTreeMap<String, String>,
    allowed_meetings: &BTreeSet<String>,
) -> Result<Option<(BTreeMap<String, Vec<f32>>, String)>> {
    if !crate::ai::live_features(root)?.semantic_search {
        return Ok(None);
    }
    let c = config(root)?;
    if !c.enabled || (allowed_notes.is_empty() && allowed_meetings.is_empty()) {
        return Ok(None);
    }
    ensure!(
        allowed_notes.len() + allowed_meetings.len() <= 10_000,
        "Слишком много источников для построения тем"
    );
    let cache = root.join("cache");
    let directory = cache.join("semantic");
    for path in [&cache, &directory] {
        match fs::symlink_metadata(path) {
            Ok(meta) => ensure!(
                meta.is_dir() && !meta.file_type().is_symlink(),
                "Некорректный индекс поиска"
            ),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.into()),
        }
    }
    let path = directory.join("index.sqlite");
    match fs::symlink_metadata(&path) {
        Ok(meta) => ensure!(
            meta.is_file() && !meta.file_type().is_symlink(),
            "Некорректный индекс поиска"
        ),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.into()),
    }
    for suffix in ["-journal", "-wal", "-shm"] {
        match fs::symlink_metadata(directory.join(format!("index.sqlite{suffix}"))) {
            Ok(meta) => ensure!(
                meta.is_file() && !meta.file_type().is_symlink(),
                "Некорректные файлы индекса поиска"
            ),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
    }
    let db = Connection::open_with_flags(
        &path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    db.busy_timeout(Duration::from_secs(2))?;
    let active: Option<(String,String)> = db.query_row("SELECT g.id,g.manifest FROM generations g JOIN state s ON s.value=g.id WHERE s.key='active' AND g.complete=1", [], |r| Ok((r.get(0)?,r.get(1)?))).optional()?;
    let Some((generation, expected_manifest)) = active else {
        return Ok(None);
    };
    if expected_manifest != manifest(&c) {
        return Ok(None);
    }
    let mut statement =
        db.prepare("SELECT source,vector FROM vectors WHERE generation=?1 ORDER BY id LIMIT ?2")?;
    let rows = statement.query_map(params![generation, MAX_DOCS as i64], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, Vec<u8>>(1)?))
    })?;
    let mut sums: BTreeMap<String, (usize, Vec<f64>)> = BTreeMap::new();
    let mut freshness: BTreeMap<String, bool> = BTreeMap::new();
    for row in rows {
        let (source, bytes) = row?;
        let s: Value = serde_json::from_str(&source)?;
        let (key, maximum) = if s["kind"] == "note" {
            let Some(id) = s["noteID"].as_str() else {
                continue;
            };
            if allowed_notes.get(id).map(String::as_str) != s["sourceFingerprint"].as_str() {
                continue;
            }
            (format!("note:{id}"), 4)
        } else if ["transcript", "summary"].contains(&s["kind"].as_str().unwrap_or("")) {
            let Some(id) = s["meetingID"].as_str() else {
                continue;
            };
            if !allowed_meetings.contains(id) {
                continue;
            }
            let source_key = format!("{id}:{}:{}", s["kind"], s["sourceFingerprint"]);
            if !*freshness
                .entry(source_key)
                .or_insert_with(|| current(root, &s))
            {
                continue;
            }
            (format!("meeting:{id}"), 16)
        } else {
            continue;
        };
        let (count, sum) = sums
            .entry(key)
            .or_insert_with(|| (0, vec![0.0; c.dimensions]));
        if *count >= maximum {
            continue;
        }
        let vector = decode(&bytes, c.dimensions)?;
        for (total, value) in sum.iter_mut().zip(vector) {
            *total += value as f64;
        }
        *count += 1;
    }
    ensure!(
        cached_manifest_is_current(root, &expected_manifest),
        "Настройки смыслового поиска изменились. Обновите подсказки."
    );
    let mut result = BTreeMap::new();
    for (id, (_, sum)) in sums {
        let norm = sum.iter().map(|v| v * v).sum::<f64>().sqrt();
        if norm.is_finite() && norm > 1e-12 {
            result.insert(id, sum.into_iter().map(|v| (v / norm) as f32).collect());
        }
    }
    if result.is_empty() {
        return Ok(None);
    }
    Ok(Some((result, expected_manifest)))
}

pub(crate) fn cached_note_similarities(
    root: &Path,
    source_id: &str,
    allowed: &BTreeMap<String, String>,
) -> Result<Option<(BTreeMap<String, f64>, String)>> {
    if !allowed.contains_key(source_id) {
        return Ok(None);
    }
    let Some((vectors, expected_manifest)) = cached_note_vectors(root, allowed)? else {
        return Ok(None);
    };
    let Some(source_vectors) = vectors.get(source_id) else {
        return Ok(None);
    };
    let mut scores = BTreeMap::new();
    for (id, chunks) in &vectors {
        if id == source_id {
            continue;
        }
        let score = source_vectors
            .iter()
            .flat_map(|a| {
                chunks.iter().map(move |b| {
                    a.iter()
                        .zip(b)
                        .map(|(x, y)| *x as f64 * *y as f64)
                        .sum::<f64>()
                })
            })
            .fold(-1.0f64, f64::max);
        if score.is_finite() {
            scores.insert(id.clone(), score.clamp(-1.0, 1.0));
        }
    }
    Ok(Some((scores, expected_manifest)))
}

/// Load the permitted, fresh cached vectors once and form one normalized
/// centroid per note. At most 1000 × 4 × 4096 inputs are retained. Topic
/// grouping never downloads a model, indexes documents or calls a provider.
pub(crate) fn cached_topic_vectors(
    root: &Path,
    allowed: &BTreeMap<String, String>,
) -> Result<Option<(BTreeMap<String, Vec<f32>>, String)>> {
    ensure!(
        allowed.len() <= 1000,
        "Слишком много заметок для построения тем"
    );
    let Some((vectors, manifest)) = cached_note_vectors(root, allowed)? else {
        return Ok(None);
    };
    let mut result = BTreeMap::new();
    for (id, chunks) in vectors {
        let Some(first) = chunks.first() else {
            continue;
        };
        let mut centroid = vec![0.0f64; first.len()];
        for chunk in &chunks {
            for (v, x) in centroid.iter_mut().zip(chunk) {
                *v += *x as f64;
            }
        }
        let norm = centroid.iter().map(|v| v * v).sum::<f64>().sqrt();
        if norm.is_finite() && norm > 1e-12 {
            result.insert(
                id,
                centroid.into_iter().map(|x| (x / norm) as f32).collect(),
            );
        }
    }
    if result.is_empty() {
        return Ok(None);
    }
    Ok(Some((result, manifest)))
}
pub(crate) fn cached_manifest_is_current(root: &Path, expected: &str) -> bool {
    crate::ai::live_features(root).is_ok_and(|f| f.semantic_search)
        && config(root).is_ok_and(|c| c.enabled && manifest(&c) == expected)
}

/// Model-specific cut-off used only for suggestions explicitly confirmed by
/// the user. The exact digest and input format were evaluated on separate
/// small synthetic calibration/holdout fixtures; these are not a quality
/// guarantee for user data. Automatic topic edges must not use this cut-off.
pub(crate) fn manual_suggestion_threshold(root: &Path, expected_manifest: &str) -> f64 {
    const EVALUATED_QWEN_DIGEST: &str =
        "ac6da0dfba84a81fdbfbaf330198c33cd77c4cdfc53e8bc50eb581914a15621d";
    let Ok(current) = config(root) else {
        return 0.82;
    };
    let evaluated_model = (current.provider == "ollama"
        && current.model_revision == EVALUATED_QWEN_DIGEST)
        || (current.provider == "managed"
            && current.model_revision == crate::managed_embeddings::REVISION);
    if current.enabled
        && evaluated_model
        && current.model == "qwen3-embedding:0.6b"
        && current.dimensions == 1024
        && current.document_prefix.is_empty()
        && manifest(&current) == expected_manifest
    {
        0.43
    } else {
        0.82
    }
}

fn refresh(root: &Path, input: &Value) -> Result<Value> {
    let feature_snapshot = enabled_features(root)?;
    let c = config(root)?;
    ensure!(c.enabled, "Сначала включите смысловой поиск");
    if input["paused"] == true {
        return Ok(json!({"paused":true,"complete":false}));
    }
    ensure!(
        !c.model_revision.is_empty(),
        "Сначала проверьте подключение embedding-модели"
    );
    let key = input["apiKey"].as_str().unwrap_or("");
    credential_binding(&c, key, input["configFingerprint"].as_str())?;
    let lock = safe_file(&folder(root)?.join(".index.lock"))?;
    lock.try_lock().context("Индекс уже обновляется")?;
    let pending = crate::workspace_repository::pending_events(root, "semantic-index", 500)?;
    let (docs, warnings) = corpus(root, &c)?;
    let m = manifest(&c);
    let g = generation(&c, &docs);
    unchanged_features(root, &feature_snapshot)?;
    let mut db = connection(root)?;
    db.execute(
        "INSERT OR IGNORE INTO generations(id,manifest) VALUES(?1,?2)",
        params![g, m],
    )?;
    // Reuse unchanged vectors ONLY for the exact model/template/chunker manifest.
    let transaction = db.transaction()?;
    for d in &docs {
        transaction.execute("INSERT OR IGNORE INTO vectors(generation,id,content_hash,source,vector) SELECT ?1,id,content_hash,?2,vector FROM vectors WHERE id=?3 AND content_hash=?4 AND generation IN (SELECT id FROM generations WHERE manifest=?5) LIMIT 1",params![g,d.source.to_string(),d.id,d.content_hash,m])?;
    }
    // Keep at most one active and one staging generation. A source edit during
    // indexing must not accumulate abandoned private text or unbounded vectors.
    transaction.execute("DELETE FROM vectors WHERE generation<>?1 AND generation<>COALESCE((SELECT value FROM state WHERE key='active'),'')",[&g])?;
    transaction.execute("DELETE FROM generations WHERE id<>?1 AND id<>COALESCE((SELECT value FROM state WHERE key='active'),'')",[&g])?;
    unchanged_features(root, &feature_snapshot)?;
    transaction.commit()?;
    let present: HashSet<String> = db
        .prepare("SELECT id FROM vectors WHERE generation=?1")?
        .query_map([&g], |r| r.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    let maximum = input["maxDocuments"].as_u64().unwrap_or(32).clamp(1, 32) as usize;
    let missing = docs
        .iter()
        .filter(|d| !present.contains(&d.id))
        .take(maximum)
        .collect::<Vec<_>>();
    let mut added = 0;
    for pending_batch in missing.chunks(8) {
        unchanged_features(root, &feature_snapshot)?;
        // Revocation applies before each new network request, not merely before
        // committing returned vectors. An in-flight batch cannot grant later ones.
        ensure!(
            config(root)?.enabled && manifest(&config(root)?) == m,
            "Настройки поиска изменились: пакет отменён"
        );
        let cloud = !is_local(&endpoint(&c)?);
        let batch = pending_batch
            .iter()
            .copied()
            .filter(|d| {
                current(root, &d.source)
                    && (!cloud
                        || d.source["kind"] != "code"
                        || crate::code_index::cloud_allowed(root, &d.source))
            })
            .collect::<Vec<_>>();
        if batch.is_empty() {
            continue;
        }
        let texts = batch.iter().map(|d| d.text.clone()).collect::<Vec<_>>();
        unchanged_features(root, &feature_snapshot)?;
        let vectors = embed(root, &c, &texts, false, key)?;
        unchanged_features(root, &feature_snapshot)?;
        ensure!(
            manifest(&config(root)?) == m && config(root)?.enabled,
            "Настройки поиска изменились: пакет отменён"
        );
        let transaction = db.transaction()?;
        for (d, v) in batch.iter().zip(vectors) {
            if current(root, &d.source) {
                transaction.execute("INSERT OR REPLACE INTO vectors(generation,id,content_hash,source,vector) VALUES(?1,?2,?3,?4,?5)",params![g,d.id,d.content_hash,d.source.to_string(),blob(&v)])?;
                added += 1;
            }
        }
        unchanged_features(root, &feature_snapshot)?;
        transaction.commit()?;
    }
    let count = db.query_row(
        "SELECT COUNT(*) FROM vectors WHERE generation=?1",
        [&g],
        |r| r.get::<_, i64>(0),
    )? as usize;
    let complete = count == docs.len();
    if complete {
        ensure!(
            manifest(&config(root)?) == m && config(root)?.enabled,
            "Настройки поиска изменились"
        );
        let tx = db.transaction()?;
        tx.execute("UPDATE generations SET complete=1 WHERE id=?1", [&g])?;
        tx.execute(
            "INSERT OR REPLACE INTO state(key,value) VALUES('active',?1)",
            [&g],
        )?;
        tx.execute("DELETE FROM vectors WHERE generation<>?1", [&g])?;
        tx.execute("DELETE FROM generations WHERE id<>?1", [&g])?;
        unchanged_features(root, &feature_snapshot)?;
        tx.commit()?;
        // Delivery is acknowledged only after the derived generation is durable.
        // Changes arriving after this snapshot keep their own pending event.
        for event in &pending {
            crate::workspace_repository::acknowledge_event(root, "semantic-index", &event.id)?;
        }
    }
    let has_new_changes = complete
        && !crate::workspace_repository::pending_events(root, "semantic-index", 1)?.is_empty();
    Ok(
        json!({"complete":complete && !has_new_changes,"indexed":count,"total":docs.len(),"added":added,"generation":g,"warnings":warnings}),
    )
}
/// Read only cosine results. Disabled/unavailable embeddings degrade to lexical
/// retrieval at the caller; every source is validated again after model output.
pub fn search(
    root: &Path,
    query: &str,
    limit: usize,
    key: &str,
    binding: Option<&str>,
) -> Result<Value> {
    if !crate::ai::live_features(root)?.semantic_search {
        return Ok(json!({"hits":[],"enabled":false}));
    }
    let c = config(root)?;
    if !c.enabled {
        return Ok(json!({"hits":[],"enabled":false}));
    }
    ensure!(
        !query.trim().is_empty() && query.len() <= 4000,
        "Сократите запрос поиска"
    );
    credential_binding(&c, key, binding)?;
    let db = connection(root)?;
    let active:Option<(String,String)>=db.query_row("SELECT g.id,g.manifest FROM generations g JOIN state s ON s.value=g.id WHERE s.key='active' AND g.complete=1",[],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
    let Some((g, m)) = active else {
        return Ok(json!({"hits":[],"enabled":true,"needsRefresh":true}));
    };
    if m != manifest(&c) {
        return Ok(json!({"hits":[],"enabled":true,"needsRefresh":true}));
    }
    enabled_features(root)?;
    let q = embed(root, &c, &[query.into()], true, key)?.remove(0);
    enabled_features(root)?;
    ensure!(
        config(root)?.enabled && manifest(&config(root)?) == m,
        "Настройки поиска изменились"
    );
    let mut top = Vec::<(f64, Value)>::new();
    let mut statement =
        db.prepare("SELECT source,vector FROM vectors WHERE generation=?1 ORDER BY id LIMIT ?2")?;
    let rows = statement.query_map(params![g, MAX_DOCS as i64], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, Vec<u8>>(1)?))
    })?;
    for row in rows {
        let (source, bytes) = row?;
        let s: Value = serde_json::from_str(&source)?;
        let v = decode(&bytes, c.dimensions)?;
        let cosine = q
            .iter()
            .zip(v)
            .map(|(a, b)| *a as f64 * b as f64)
            .sum::<f64>();
        if cosine < 0.15 {
            continue;
        }
        top.push((cosine, s));
    }
    top.sort_by(|a, b| b.0.total_cmp(&a.0));
    let mut hits = Vec::new();
    let mut seen = HashSet::new();
    for (cosine, s) in top {
        if seen.contains(s["id"].as_str().unwrap_or("")) || !current(root, &s) {
            continue;
        }
        seen.insert(s["id"].as_str().unwrap_or("").to_owned());
        hits.push(json!({"source":s,"cosine":cosine,"rank":hits.len()+1}));
        if hits.len() >= limit.clamp(1, 60) {
            break;
        }
    }
    Ok(json!({"hits":hits,"enabled":true,"generation":g,"model":c.model}))
}
pub fn dispatch(root: &Path, input: &Value) -> Result<Value> {
    if ["semantic-check", "semantic-models", "semantic-pull"]
        .contains(&input["command"].as_str().unwrap_or(""))
    {
        enabled_features(root)?;
    }
    ensure!(root.is_absolute(), "Нужен абсолютный путь библиотеки");
    match input["command"].as_str().unwrap_or("") {
        "semantic-config" => {
            if let Some(value) = input.get("config") {
                let c: Config = serde_json::from_value(value.clone())?;
                validate(&c)?;
                crate::storage::atomic_json(&config_path(root), &serde_json::to_value(&c)?)?;
                Ok(json!({"config":c,"fingerprint":manifest(&c)}))
            } else {
                {
                    let c = config(root)?;
                    Ok(json!({"config":c,"fingerprint":manifest(&c)}))
                }
            }
        }
        "semantic-runtime-activity" => {
            let active = input["recording"]
                .as_bool()
                .context("Нужно состояние записи")?;
            crate::managed_embeddings::set_recording(root, active)?;
            Ok(json!({"recording":active}))
        }
        "semantic-runtime-status" => crate::managed_embeddings::status(root),
        "semantic-status" => {
            let c = config(root)?;
            let db = connection(root)?;
            let active: Option<String> = db
                .query_row("SELECT value FROM state WHERE key='active'", [], |r| {
                    r.get(0)
                })
                .optional()?;
            let n: usize = if let Some(g) = &active {
                db.query_row(
                    "SELECT COUNT(*) FROM vectors WHERE generation=?1",
                    [g],
                    |r| r.get::<_, i64>(0),
                )? as usize
            } else {
                0
            };
            Ok(json!({"config":c,"fingerprint":manifest(&c),"indexed":n,"generation":active}))
        }
        "semantic-check" => {
            let mut c: Config = if let Some(value) = input.get("config") {
                serde_json::from_value(value.clone())?
            } else {
                config(root)?
            };
            validate(&c)?;
            let key = input["apiKey"].as_str().unwrap_or("");
            let binding = manifest(&c);
            credential_binding(
                &c,
                key,
                supplied_binding(input, input.get("config").is_some(), &binding),
            )?;
            if c.provider == "managed" {
                c.model_revision = crate::managed_embeddings::REVISION.into();
            } else if c.provider == "ollama" {
                enabled_features(root)?;
                c.model_revision = ollama_revision(&c, key)?;
            } else if c.model_revision.is_empty() || c.model_revision.starts_with("confirmed-") {
                c.model_revision = format!("confirmed-{}", uuid::Uuid::new_v4());
            }
            enabled_features(root)?;
            let probe = embed_request(
                root,
                &c,
                &["Connection test / Проверка подключения".into()],
                false,
                key,
                true,
            )?;
            enabled_features(root)?;
            c.dimensions = probe[0].len();
            Ok(json!({"config":c,"fingerprint":manifest(&c),"connected":true}))
        }
        "semantic-models" => {
            let c: Config = if let Some(value) = input.get("config") {
                serde_json::from_value(value.clone())?
            } else {
                config(root)?
            };
            validate(&c)?;
            let key = input["apiKey"].as_str().unwrap_or("");
            let binding = manifest(&c);
            credential_binding(
                &c,
                key,
                supplied_binding(input, input.get("config").is_some(), &binding),
            )?;
            if c.provider == "managed" {
                let state = crate::managed_embeddings::status(root)?;
                return Ok(
                    json!({"models":if state["ready"]==true {json!([{"id":crate::managed_embeddings::MODEL}])} else {json!([])},"runtime":state}),
                );
            }
            let url = api_url(
                &c,
                if c.provider == "ollama" {
                    "api/tags"
                } else {
                    "models"
                },
            )?;
            enabled_features(root)?;
            let data = response(authenticated(client(10)?.get(url), key)?.send()?)?;
            enabled_features(root)?;
            Ok(
                json!({"models":if c.provider=="ollama"{data["models"].clone()}else{data["data"].clone()}}),
            )
        }
        "semantic-pull" => {
            let c: Config = if let Some(value) = input.get("config") {
                serde_json::from_value(value.clone())?
            } else {
                config(root)?
            };
            validate(&c)?;
            if c.provider == "managed" {
                return crate::managed_embeddings::prepare(root);
            }
            ensure!(
                c.provider == "ollama" && is_local(&endpoint(&c)?),
                "Скачивание доступно в локальной Ollama"
            );
            ensure!(
                c.model == "qwen3-embedding:0.6b",
                "Кнопка скачивает только компактную qwen3-embedding:0.6b"
            );
            let key = input["apiKey"].as_str().unwrap_or("");
            let binding = manifest(&c);
            credential_binding(
                &c,
                key,
                supplied_binding(input, input.get("config").is_some(), &binding),
            )?;
            enabled_features(root)?;
            let data = response(
                authenticated(
                    client(600)?
                        .post(api_url(&c, "api/pull")?)
                        .json(&json!({"model":c.model,"stream":false})),
                    input["apiKey"].as_str().unwrap_or(""),
                )?
                .send()?,
            )?;
            enabled_features(root)?;
            ensure!(
                data["status"] == "success",
                "Ollama не подтвердила скачивание"
            );
            Ok(json!({"downloaded":true}))
        }
        "semantic-refresh" => refresh(root, input),
        "semantic-search" => search(
            root,
            input["query"].as_str().unwrap_or(""),
            input["limit"].as_u64().unwrap_or(30) as usize,
            input["apiKey"].as_str().unwrap_or(""),
            input["configFingerprint"].as_str(),
        ),
        _ => anyhow::bail!("Неизвестная команда смыслового поиска"),
    }
}

#[cfg(test)]
#[path = "semantic/tests.rs"]
mod tests;

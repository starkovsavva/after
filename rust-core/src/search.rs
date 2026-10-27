//! Derived, local-only full-text index. Meeting JSON is the source of truth.
//! Only the three named JSON files inside ordinary meeting directories are read.
//! Search never sends meeting text to a model or a network endpoint.
use anyhow::{ensure, Context, Result};
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use rust_stemmers::{Algorithm, Stemmer};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::time::Duration;
use unicode_normalization::{char::is_combining_mark, UnicodeNormalization};

const INDEX_VERSION: i64 = 3;
const MAX_META: u64 = 1_048_576;
const MAX_SUMMARY: u64 = 8 * 1_048_576;
const MAX_TRANSCRIPT: u64 = 64 * 1_048_576;
const MAX_DOCUMENT: usize = 200_000;
const MAX_ROWS_PER_MEETING: usize = 100_000;

#[cfg(test)]
thread_local! {
    static SYNC_CALLS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

fn private_directory(path: &Path) -> Result<()> {
    DirBuilder::new().recursive(true).mode(0o700).create(path)?;
    let info = fs::symlink_metadata(path)?;
    ensure!(info.is_dir() && !info.file_type().is_symlink(), "Папка поиска не должна быть символической ссылкой");
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}
fn regular_private(path: &Path) -> Result<File> {
    if let Ok(info) = fs::symlink_metadata(path) {
        ensure!(info.is_file() && !info.file_type().is_symlink(), "Некорректный файл индекса поиска");
    }
    let file = OpenOptions::new().read(true).write(true).create(true).truncate(false)
        .mode(0o600).custom_flags(libc::O_NOFOLLOW).open(path)?;
    file.set_permissions(fs::Permissions::from_mode(0o600))?;
    Ok(file)
}
fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 128 && id.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
}
fn stamp(path: &Path) -> String {
    match fs::symlink_metadata(path) {
        Ok(m) if m.is_file() && !m.file_type().is_symlink() =>
            format!("{}:{}:{}:{}:{}:{}", m.ino(), m.len(), m.mtime(), m.mtime_nsec(), m.ctime(), m.ctime_nsec()),
        Ok(_) => "not-regular".into(),
        Err(_) => "missing".into(),
    }
}
fn source_stamp(directory: &Path) -> String {
    ["meta.json", "transcript.json", "summary.json"].iter().map(|name| format!("{name}:{}", stamp(&directory.join(name))))
        .collect::<Vec<_>>().join("|")
}
fn snapshot(path: &Path, max_bytes: u64) -> Result<Option<Value>> {
    let info = match fs::symlink_metadata(path) {
        Ok(info) => info,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    ensure!(info.is_file() && !info.file_type().is_symlink(), "Ожидался обычный JSON-файл");
    ensure!(info.len() <= max_bytes, "JSON-файл слишком большой для поиска");
    let mut file = OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(path)?;
    let opened = file.metadata()?;
    ensure!(opened.is_file() && opened.len() <= max_bytes, "JSON-файл слишком большой для поиска");
    let mut bytes = Vec::with_capacity(opened.len() as usize);
    (&mut file).take(max_bytes + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() as u64 <= max_bytes, "JSON-файл слишком большой для поиска");
    Ok(Some(serde_json::from_slice(&bytes).context("Повреждён JSON-файл")?))
}
fn optional_source(directory: &Path, name: &str, max: u64, warnings: &mut Vec<String>) -> Option<Value> {
    match snapshot(&directory.join(name), max) {
        Ok(value) => value,
        Err(_) => { warnings.push(format!("Встреча {}: файл {name} пропущен; проверьте данные встречи.", directory.file_name().unwrap_or_default().to_string_lossy())); None }
    }
}

struct Lexicon { russian: Stemmer, english: Stemmer }
impl Lexicon {
    fn new() -> Self { Self { russian: Stemmer::create(Algorithm::Russian), english: Stemmer::create(Algorithm::English) } }
    fn tokens(&self, text: &str) -> Vec<String> {
        // NFKD handles equivalent composed accents and full-width text; map ё/е
        // equally so Russian keyboard/spelling variation does not hide results.
        let normalized: String = text.nfkd().filter(|c| !is_combining_mark(*c))
            .flat_map(char::to_lowercase).map(|c| if c == 'ё' { 'е' } else { c }).collect();
        normalized.split(|c: char| !c.is_alphanumeric()).filter(|s| !s.is_empty())
            .map(str::to_owned).collect()
    }
    fn stem(&self, token: &str) -> String {
        if token.chars().any(|c| ('а'..='я').contains(&c)) { self.russian.stem(token).into_owned() }
        else if token.chars().all(|c| c.is_ascii_alphabetic()) { self.english.stem(token).into_owned() }
        else { token.to_owned() }
    }
    fn columns(&self, text: &str) -> (String, String) {
        let tokens = self.tokens(text);
        let stems = tokens.iter().map(|word| self.stem(word)).collect::<Vec<_>>().join(" ");
        (tokens.join(" "), stems)
    }
    fn query(&self, query: &str) -> Result<(String, Vec<String>)> {
        ensure!(query.chars().count() <= 512, "Поисковый запрос слишком длинный: не более 512 символов");
        let tokens = self.tokens(query);
        ensure!(tokens.len() <= 24, "Уточните запрос: не более 24 слов");
        let mut terms = BTreeSet::new();
        let mut expression = Vec::new();
        for token in tokens {
            let stem = self.stem(&token);
            if !terms.insert(stem.clone()) { continue; }
            // Only alphanumeric tokens enter MATCH, always quoted. User input
            // cannot introduce FTS operators, column filters, SQL or wildcards.
            expression.push(if stem == token { format!("\"{token}\"*") }
                else { format!("(\"{token}\"* OR \"{stem}\"*)") });
        }
        Ok((expression.join(" AND "), terms.into_iter().collect()))
    }
}
/// Shared lexical matching for user notes. No network/model/index duplication.
pub(crate) struct QueryMatcher { lexicon: Lexicon, terms: Vec<String> }
impl QueryMatcher {
    pub(crate) fn new(query: &str) -> Result<Self> {
        let lexicon=Lexicon::new(); let (_,terms)=lexicon.query(query)?;
        Ok(Self { lexicon,terms })
    }
    pub(crate) fn matches(&self,text:&str) -> bool {
        if self.terms.is_empty() { return true; }
        let tokens=self.lexicon.tokens(text);
        self.terms.iter().all(|term| tokens.iter().any(|word|word.starts_with(term) || self.lexicon.stem(word).starts_with(term)))
    }
}
#[derive(Debug)]
struct Document {
    key: String, kind: &'static str, text: String, search_text: Option<String>, refs: Vec<u64>, start: Option<f64>,
    item_index: Option<usize>, card_id: Option<String>,
}
fn text(value: &Value, key: &str) -> String { value[key].as_str().unwrap_or("").to_owned() }
fn bounded(text: String) -> Option<String> {
    if text.trim().is_empty() || text.len() > MAX_DOCUMENT { None } else { Some(text) }
}
fn valid_refs(value: &Value, segments: &BTreeMap<u64, f64>) -> Option<Vec<u64>> {
    let input = value.as_array()?;
    if input.is_empty() || input.len() > 10_000 { return None; }
    let mut refs = Vec::new();
    for value in input {
        let id = value.as_u64()?;
        if id > i64::MAX as u64 || !segments.contains_key(&id) { return None; }
        if !refs.contains(&id) { refs.push(id); }
    }
    Some(refs)
}
fn documents(meta: &Value, transcript: Option<&Value>, summary: Option<&Value>) -> Vec<Document> {
    let mut docs = Vec::new();
    if let Some(title) = bounded(text(meta, "title")) {
        docs.push(Document { key:"title".into(), kind:"title", text:title, search_text:None, refs:vec![], start:None, item_index:None, card_id:None });
    }
    let mut segments = BTreeMap::new();
    let mut duplicate_ids = HashSet::new();
    if let Some(values) = transcript.and_then(|t| t["segments"].as_array()) {
        // Duplicate IDs cannot be used for reliable navigation or citations.
        for value in values.iter().take(MAX_ROWS_PER_MEETING) {
            let (Some(id), Some(start), Some(end)) = (value["id"].as_u64(), value["start"].as_f64(), value["end"].as_f64()) else { continue };
            if id > i64::MAX as u64 || !start.is_finite() || !end.is_finite() || start < 0.0 || end < start { continue; }
            if segments.insert(id, start).is_some() { duplicate_ids.insert(id); }
        }
        for id in duplicate_ids { segments.remove(&id); }
        for value in values.iter().take(MAX_ROWS_PER_MEETING) {
            let Some(id) = value["id"].as_u64() else { continue };
            let Some(start) = segments.get(&id).copied() else { continue };
            let Some(content) = bounded(text(value, "text")) else { continue };
            docs.push(Document { key:format!("segment-{id}"), kind:"transcript", text:content, search_text:None, refs:vec![id], start:Some(start), item_index:None, card_id:None });
        }
    }
    if let Some(summary) = summary.filter(|v| v.is_object()) {
        if let Some(content) = bounded(text(summary, "overview")) {
            docs.push(Document { key:"overview".into(), kind:"overview", text:content, search_text:None, refs:vec![], start:None, item_index:None, card_id:None });
        }
        if let Some(items) = summary["items"].as_array() {
            for (index, item) in items.iter().take(10_000).enumerate() {
                let Some(refs) = valid_refs(&item["segmentIDs"], &segments) else { continue };
                let raw = text(item, "text");
                if bounded(raw.clone()).is_none() { continue; }
                let mut content = raw.clone();
                for key in ["owner", "due"] { let value = text(item, key); if !value.is_empty() { content.push_str(" · "); content.push_str(&value); } }
                let Some(content) = bounded(content) else { continue };
                let start = refs.iter().filter_map(|id| segments.get(id)).copied().min_by(f64::total_cmp);
                docs.push(Document { key:format!("item-{index}"), kind:"item", text:raw, search_text:Some(content), refs, start, item_index:Some(index), card_id:None });
            }
        }
        if let Some(cards) = summary["cards"].as_array() {
            let mut used_ids = HashSet::new();
            for card in cards.iter().take(10_000) {
                let id = text(card, "id");
                if id.is_empty() || id.len() > 256 || !used_ids.insert(id.clone()) { continue; }
                let refs = if meta["libraryKind"]=="cards" && meta["source"]=="cards.tsv" && card["segmentIDs"].as_array().is_some_and(Vec::is_empty) {
                    vec![] // A text-imported deck has no meeting source to cite.
                } else { let Some(refs)=valid_refs(&card["segmentIDs"],&segments) else { continue }; refs };
                let content = ["front", "back", "context"].iter().map(|key| text(card,key)).collect::<Vec<_>>().join("\n");
                let Some(content) = bounded(content) else { continue };
                let start = refs.iter().filter_map(|id| segments.get(id)).copied().min_by(f64::total_cmp);
                docs.push(Document { key:format!("card-{id}"), kind:"card", text:content, search_text:None, refs, start, item_index:None, card_id:Some(id) });
            }
        }
    }
    docs
}
fn initialize(connection: &Connection) -> Result<()> {
    connection.busy_timeout(Duration::from_secs(10))?;
    connection.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA secure_delete=ON; PRAGMA foreign_keys=ON;")?;
    let version: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
    if version != INDEX_VERSION {
        connection.execute_batch("BEGIN IMMEDIATE; DROP TABLE IF EXISTS documents_fts; DROP TABLE IF EXISTS documents; DROP TABLE IF EXISTS sources; COMMIT;")?;
    }
    connection.execute_batch("CREATE TABLE IF NOT EXISTS sources (meeting_id TEXT PRIMARY KEY, stamp TEXT NOT NULL, warnings TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS documents (
        rowid INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, meeting_id TEXT NOT NULL, title TEXT NOT NULL,
        created_at REAL NOT NULL, kind TEXT NOT NULL, text TEXT NOT NULL, refs TEXT NOT NULL,
        start REAL, item_index INTEGER, card_id TEXT, fingerprint TEXT NOT NULL, excerpt_text TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS documents_meeting ON documents(meeting_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(body, stems, tokenize='unicode61 remove_diacritics 2', prefix='2 3 4');")?;
    connection.pragma_update(None, "user_version", INDEX_VERSION)?;
    Ok(())
}
/// This database is disposable; source JSON is never part of recovery.
fn open_index(database:&Path) -> Result<(Connection,bool)> {
    let open=|| -> Result<Connection> {
        let connection=Connection::open(database).context("Не удалось открыть локальный индекс поиска")?;
        initialize(&connection)?;
        Ok(connection)
    };
    match open() {
        Ok(connection)=>Ok((connection,false)),
        Err(error) if error.chain().any(|cause| cause.downcast_ref::<rusqlite::Error>().is_some_and(|error| {
            matches!(error,rusqlite::Error::SqliteFailure(failure,_) if matches!(failure.code,rusqlite::ErrorCode::DatabaseCorrupt|rusqlite::ErrorCode::NotADatabase))
        }))=> {
            // The caller holds the index lock and already rejects symlinked
            // database sidecars. Re-check ownership before removing only cache.
            for suffix in ["","-journal","-wal","-shm"] {
                let path=database.with_file_name(format!("{}{}",database.file_name().unwrap().to_string_lossy(),suffix));
                match fs::symlink_metadata(&path) {
                    Ok(info)=> { ensure!(info.is_file()&&!info.file_type().is_symlink(),"Некорректный файл индекса поиска"); fs::remove_file(path)?; },
                    Err(error) if error.kind()==std::io::ErrorKind::NotFound=>{},
                    Err(error)=>return Err(error.into()),
                }
            }
            drop(regular_private(database)?);
            Ok((open()?,true))
        },
        Err(error)=>Err(error),
    }
}

fn remove_meeting(connection: &Connection, id: &str) -> Result<()> {
    connection.execute("DELETE FROM documents_fts WHERE rowid IN (SELECT rowid FROM documents WHERE meeting_id=?1)", [id])?;
    connection.execute("DELETE FROM documents WHERE meeting_id=?1", [id])?;
    connection.execute("DELETE FROM sources WHERE meeting_id=?1", [id])?;
    Ok(())
}
fn sync(connection: &mut Connection, root: &Path, lexicon: &Lexicon) -> Result<Vec<String>> {
    #[cfg(test)]
    SYNC_CALLS.with(|calls| calls.set(calls.get() + 1));
    let library = root.join("meetings");
    private_directory(&library)?;
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let mut seen = BTreeSet::new();
    let mut warnings = Vec::new();
    for entry in fs::read_dir(&library)? {
        let Ok(entry) = entry else { continue };
        let Some(id) = entry.file_name().to_str().map(str::to_owned) else { continue };
        if !valid_id(&id) { continue; }
        let Ok(kind) = entry.file_type() else { continue };
        if !kind.is_dir() || kind.is_symlink() { continue; }
        let directory = entry.path();
        let before = source_stamp(&directory);
        let previous: Option<(String,String)> = transaction.query_row("SELECT stamp,warnings FROM sources WHERE meeting_id=?1", [&id], |row| Ok((row.get(0)?,row.get(1)?))).optional()?;
        if let Some((stamp, cached_warnings)) = previous {
            if stamp == before {
                seen.insert(id);
                warnings.extend(serde_json::from_str::<Vec<String>>(&cached_warnings).unwrap_or_default());
                continue;
            }
        }
        // Delete old rows even when replacement data is malformed or removed.
        // No stale search result survives a failed reindex of this meeting.
        remove_meeting(&transaction, &id)?;
        let mut meeting_warnings = Vec::new();
        let meta = optional_source(&directory, "meta.json", MAX_META, &mut meeting_warnings);
        let valid_meta = meta.as_ref().filter(|meta| meta["id"].as_str() == Some(&id)
            && meta["title"].as_str().is_some_and(|s| !s.trim().is_empty() && s.len() <= MAX_DOCUMENT)
            && meta["createdAt"].as_f64().is_some_and(f64::is_finite));
        let Some(meta) = valid_meta else {
            warnings.push(format!("Встреча {id}: поиск пропустил некорректные метаданные."));
            continue;
        };
        let transcript = optional_source(&directory, "transcript.json", MAX_TRANSCRIPT, &mut meeting_warnings);
        let summary = optional_source(&directory, "summary.json", MAX_SUMMARY, &mut meeting_warnings);
        let docs = documents(meta, transcript.as_ref(), summary.as_ref());
        // An atomic source replacement during reading is retried next search.
        // Do not publish a mixed snapshot from different transcript generations.
        if before != source_stamp(&directory) {
            warnings.push(format!("Встреча {id} обновляется. Повторите поиск через мгновение."));
            continue;
        }
        let fingerprint = format!("{:x}", Sha256::digest(before.as_bytes()));
        for doc in docs {
            let excerpt_text = doc.search_text.as_deref().unwrap_or(&doc.text);
            let (body, stems) = lexicon.columns(excerpt_text);
            transaction.execute("INSERT INTO documents(key,meeting_id,title,created_at,kind,text,refs,start,item_index,card_id,fingerprint,excerpt_text) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)",
                params![format!("{id}:{}",doc.key), id, meta["title"].as_str().unwrap(), meta["createdAt"].as_f64().unwrap(), doc.kind, doc.text,
                    serde_json::to_string(&doc.refs)?, doc.start, doc.item_index.map(|i|i as i64), doc.card_id, fingerprint, excerpt_text])?;
            let rowid = transaction.last_insert_rowid();
            transaction.execute("INSERT INTO documents_fts(rowid,body,stems) VALUES(?1,?2,?3)", params![rowid,body,stems])?;
        }
        transaction.execute("INSERT INTO sources(meeting_id,stamp,warnings) VALUES(?1,?2,?3)",params![id,before,serde_json::to_string(&meeting_warnings)?])?;
        seen.insert(id);
        warnings.extend(meeting_warnings);
    }
    let old: Vec<String> = transaction.prepare("SELECT meeting_id FROM sources")?.query_map([],|row|row.get(0))?.collect::<rusqlite::Result<_>>()?;
    for id in old { if !seen.contains(&id) { remove_meeting(&transaction,&id)?; } }
    transaction.commit()?;
    warnings.truncate(50);
    Ok(warnings)
}
fn excerpt(text: &str, terms: &[String], lexicon: &Lexicon) -> String {
    let plain = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let chars: Vec<char> = plain.chars().collect();
    if chars.len() <= 240 { return plain; }
    let mut match_at = 0;
    let mut word_start = None;
    for (i, character) in chars.iter().enumerate().chain(std::iter::once((chars.len(), &' '))) {
        if character.is_alphanumeric() { if word_start.is_none() { word_start = Some(i); } }
        else if let Some(start) = word_start.take() {
            let word: String = chars[start..i].iter().collect();
            if lexicon.tokens(&word).iter().any(|token| terms.iter().any(|term| token.starts_with(term) || lexicon.stem(token).starts_with(term))) { match_at=start; break; }
        }
    }
    let start = match_at.saturating_sub(70);
    let end = (start+236).min(chars.len());
    format!("{}{}{}", if start>0 {"… "} else {""}, chars[start..end].iter().collect::<String>(), if end<chars.len() {" …"} else {""})
}

pub(crate) fn query_excerpt(text:&str,query:&str) -> Result<String> {
    let lexicon=Lexicon::new(); let (_,terms)=lexicon.query(query)?;
    Ok(excerpt(text,&terms,&lexicon))
}

/// Search is blocking; callers should run this off their UI thread. The private
/// file lock serializes index synchronization across FFI and worker processes.
pub fn search(root: &Path, query: &str, scope: &str, limit: usize) -> Result<Value> {
    Ok(search_batch(root, &[(query.into(), scope.into(), limit)])?.remove(0))
}

struct SearchRequest {
    query: String,
    scope: String,
    limit: usize,
    expression: String,
    terms: Vec<String>,
}

fn empty_result() -> Value {
    json!({"hits":[],"total":0,"truncated":false,"warnings":[]})
}

/// Run several lexical searches against one synchronized index session. The
/// returned values follow request order; the lock is released before returning
/// evidence to the caller, including callers that subsequently invoke a model.
pub(crate) fn search_batch(root: &Path, requests: &[(String, String, usize)]) -> Result<Vec<Value>> {
    ensure!(root.is_absolute(), "Папка данных должна иметь абсолютный путь");
    let lexicon = Lexicon::new();
    // Validate the complete batch before opening or updating the derived index.
    let requests = requests.iter().map(|(query, scope, limit)| {
        ensure!(["all","notes","transcript","cards","meetings"].contains(&scope.as_str()), "Неизвестная область поиска");
        let (expression, terms) = lexicon.query(query)?;
        Ok(SearchRequest { query: query.clone(), scope: scope.clone(), limit: (*limit).clamp(1, 100), expression, terms })
    }).collect::<Result<Vec<_>>>()?;
    if requests.iter().all(|request| request.expression.is_empty()) {
        return Ok(requests.iter().map(|_| empty_result()).collect());
    }
    private_directory(root)?;
    let cache = root.join("cache"); private_directory(&cache)?;
    let folder = cache.join("search"); private_directory(&folder)?;
    let lock = regular_private(&folder.join(".index.lock"))?;
    lock.lock().context("Не удалось заблокировать индекс поиска")?;
    let database = folder.join("index.sqlite");
    drop(regular_private(&database)?);
    for suffix in ["-journal","-wal","-shm"] {
        let sidecar = folder.join(format!("index.sqlite{suffix}"));
        if fs::symlink_metadata(&sidecar).is_ok() { drop(regular_private(&sidecar)?); }
    }
    let (mut connection,rebuilt) = open_index(&database)?;
    let mut warnings = sync(&mut connection,root,&lexicon)?;
    if rebuilt { warnings.push("Повреждённый индекс поиска восстановлен по исходным заметкам и встречам.".into()); }
    let transaction = connection.transaction()?;
    let results = requests.iter().map(|request| {
        if request.expression.is_empty() { return Ok(empty_result()); }
        query_index(&transaction, root, request, &lexicon, warnings.clone())
    }).collect::<Result<Vec<_>>>()?;
    transaction.commit()?;
    Ok(results)
}

fn query_index(connection: &Connection, root: &Path, request: &SearchRequest, lexicon: &Lexicon, mut warnings: Vec<String>) -> Result<Value> {
    let SearchRequest { query, scope, limit, expression, terms } = request;
    let filter = match scope.as_str() {
        "notes" => "d.kind IN ('overview','item')", "transcript" => "d.kind='transcript'",
        "cards" => "d.kind='card'", "meetings" => "d.kind='title'", _=>"1=1",
    };
    let count_sql = format!("SELECT COUNT(*) FROM documents_fts JOIN documents d ON d.rowid=documents_fts.rowid WHERE documents_fts MATCH ?1 AND {filter}");
    let mut total: i64 = connection.query_row(&count_sql, [expression], |row|row.get(0))?;
    let sql = format!("SELECT d.key,d.meeting_id,d.title,d.created_at,d.kind,d.text,d.refs,d.start,d.item_index,d.card_id,d.fingerprint,d.excerpt_text FROM documents_fts JOIN documents d ON d.rowid=documents_fts.rowid WHERE documents_fts MATCH ?1 AND {filter} ORDER BY bm25(documents_fts,1.0,0.8) * CASE d.kind WHEN 'title' THEN 4.0 WHEN 'overview' THEN 2.8 WHEN 'item' THEN 2.4 WHEN 'card' THEN 1.2 ELSE 1.0 END ASC,d.created_at DESC,d.meeting_id ASC,d.key ASC LIMIT ?2");
    let mut hits = connection.prepare(&sql)?.query_map(params![expression,*limit as i64],|row| {
        let content: String = row.get(5)?;
        let refs: String = row.get(6)?;
        Ok(json!({"id":row.get::<_,String>(0)?,"meetingID":row.get::<_,String>(1)?,"meetingTitle":row.get::<_,String>(2)?,
            "createdAt":row.get::<_,f64>(3)?,"kind":row.get::<_,String>(4)?,"snippet":excerpt(&row.get::<_,String>(11)?,terms,lexicon),"text":content,
            "segmentIDs":serde_json::from_str::<Vec<u64>>(&refs).unwrap_or_default(),"start":row.get::<_,Option<f64>>(7)?,
            "itemIndex":row.get::<_,Option<i64>>(8)?,"cardID":row.get::<_,Option<String>>(9)?,"sourceFingerprint":row.get::<_,String>(10)?}))
    })?.collect::<rusqlite::Result<Vec<_>>>()?;
    if ["all","notes"].contains(&scope.as_str()) {
        let manual = match crate::notes::search_hits(root,query) {
            Ok(hits)=>hits,
            Err(_)=>{ warnings.push("Ручные заметки недоступны для поиска. Проверьте библиотеку заметок.".into()); vec![] }
        };
        total += manual.len() as i64;
        // Keep BM25 order within meeting results; recent manual captures precede
        // them, giving source notes a predictable place without inventing scores.
        let mut combined=manual; combined.extend(hits); combined.truncate(*limit); hits=combined;
    }
    // The ordinal preserves the actual lexical result order for rank fusion;
    // it is not a comparable raw score across different queries or scopes.
    for (index, hit) in hits.iter_mut().enumerate() { hit["rank"] = json!(index + 1); }
    Ok(json!({"total":total,"truncated":total as usize>hits.len(),"hits":hits,"warnings":warnings}))
}

/// Revalidate a result before navigation without opening the derived index.
pub fn validate(root: &Path, id: &str, fingerprint: &str) -> Result<Value> {
    ensure!(root.is_absolute() && valid_id(id), "Некорректный путь встречи");
    if fingerprint.len() != 64 || !fingerprint.bytes().all(|b| b.is_ascii_hexdigit()) { return Ok(json!({"valid":false})); }
    for path in [root.to_owned(), root.join("meetings"), root.join("meetings").join(id)] {
        let Ok(info) = fs::symlink_metadata(path) else { return Ok(json!({"valid":false})); };
        if !info.is_dir() || info.file_type().is_symlink() { return Ok(json!({"valid":false})); }
    }
    let directory = root.join("meetings").join(id);
    let Some(meta) = snapshot(&directory.join("meta.json"), MAX_META).ok().flatten() else { return Ok(json!({"valid":false})); };
    if meta["id"].as_str() != Some(id) { return Ok(json!({"valid":false})); }
    let current = format!("{:x}", Sha256::digest(source_stamp(&directory).as_bytes()));
    Ok(json!({"valid":current == fingerprint}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::atomic_json;
    fn meeting(root: &Path, id:&str, title:&str) -> std::path::PathBuf {
        let dir=root.join("meetings").join(id);
        atomic_json(&dir.join("meta.json"),&json!({"id":id,"title":title,"createdAt":123.0,"source":"source.mp3"})).unwrap();
        dir
    }
    fn transcript(dir:&Path, content:&str) {
        atomic_json(&dir.join("transcript.json"),&json!({"segments":[{"id":7,"start":12.5,"end":19.0,"text":content}]})).unwrap();
    }
    #[test]
    fn batch_matches_single_searches_and_synchronizes_once() {
        let root = tempfile::tempdir().unwrap();
        let dir = meeting(root.path(), "one", "Migration planning");
        transcript(&dir, "Planning migration milestones and checking migration dependencies");
        atomic_json(&dir.join("summary.json"), &json!({
            "overview":"Migration plan",
            "items":[{"text":"Check migration dependencies","segmentIDs":[7]}],
            "cards":[{"id":"c1","front":"Migration","back":"Перенос","context":"Migration plan","segmentIDs":[7]}]
        })).unwrap();
        let requests: [(String, String, usize); 5] = [
            ("migration".into(), "all".into(), 3),
            ("migration".into(), "transcript".into(), 10),
            ("migration".into(), "cards".into(), 10),
            ("migration".into(), "notes".into(), 10),
            ("!!!".into(), "all".into(), 10),
        ];
        let singles: Vec<_> = requests.iter().map(|(query, scope, limit)| search(root.path(), query, scope, *limit).unwrap()).collect();
        let before = SYNC_CALLS.with(std::cell::Cell::get);
        let batch = search_batch(root.path(), &requests).unwrap();
        assert_eq!(SYNC_CALLS.with(std::cell::Cell::get) - before, 1);
        assert_eq!(batch, singles, "batching preserves IDs, fingerprints, BM25 order, scopes and limits");
        for result in &batch {
            for (index, hit) in result["hits"].as_array().unwrap().iter().enumerate() {
                assert_eq!(hit["rank"], index + 1);
            }
        }
    }
    #[test]
    fn batch_synchronizes_source_changes_between_calls() {
        let root = tempfile::tempdir().unwrap();
        let dir = meeting(root.path(), "one", "Batch source");
        transcript(&dir, "Original evidence");
        let requests = [("original".into(), "transcript".into(), 10), ("replacement".into(), "transcript".into(), 10)];
        let before = search_batch(root.path(), &requests).unwrap();
        let fingerprint = before[0]["hits"][0]["sourceFingerprint"].as_str().unwrap();
        assert_eq!(before[0]["total"], 1);
        assert_eq!(before[1]["total"], 0);
        transcript(&dir, "Replacement evidence");
        let after = search_batch(root.path(), &requests).unwrap();
        assert_eq!(after[0]["total"], 0);
        assert_eq!(after[1]["total"], 1);
        assert_ne!(after[1]["hits"][0]["sourceFingerprint"], fingerprint);
        assert_eq!(validate(root.path(), "one", fingerprint).unwrap()["valid"], false);
    }
    #[test]
    fn invalid_batches_and_empty_queries_do_not_open_the_index() {
        let root = tempfile::tempdir().unwrap();
        let valid = ("normal".into(), "all".into(), 10);
        for invalid in [("normal".into(), "unknown".into(), 10), ("x".repeat(513), "all".into(), 10)] {
            assert!(search_batch(root.path(), &[valid.clone(), invalid]).is_err());
            assert!(!root.path().join("cache").exists());
        }
        assert!(search_batch(root.path(), &[("word ".repeat(25), "all".into(), 10)]).is_err());
        assert!(search_batch(Path::new("relative"), &[]).is_err());
        assert_eq!(search_batch(root.path(), &[]).unwrap(), Vec::<Value>::new());
        let before = SYNC_CALLS.with(std::cell::Cell::get);
        assert_eq!(search_batch(root.path(), &[("!!!".into(), "all".into(), 10)]).unwrap(), vec![empty_result()]);
        assert_eq!(SYNC_CALLS.with(std::cell::Cell::get), before);
        assert!(!root.path().join("cache").exists());
    }
    #[test] fn corrupt_derived_index_is_rebuilt_without_touching_source_notes() {
        let root=tempfile::tempdir().unwrap(); let directory=meeting(root.path(),"one","Поставка");
        transcript(&directory,"Поставка контрольногоМаркер завтра");
        assert_eq!(search(root.path(),"контрольногоМаркер","all",20).unwrap()["total"],1);
        let original=fs::read(directory.join("transcript.json")).unwrap();
        let index=root.path().join("cache/search/index.sqlite");
        fs::write(&index,b"truncated or damaged SQLite cache").unwrap();
        let result=search(root.path(),"контрольногоМаркер","all",20).unwrap();
        assert_eq!(result["total"],1,"derived cache damage must not permanently disable library search");
        assert_eq!(fs::read(directory.join("transcript.json")).unwrap(),original);
        assert_eq!(fs::metadata(index).unwrap().permissions().mode()&0o777,0o600);
    }
    #[test] fn russian_english_numbers_prefix_and_scope() {
        let root=tempfile::tempdir().unwrap(); let dir=meeting(root.path(),"one","Бюджеты команды");
        transcript(&dir,"Обсудили бюджеты, отчёты и running migrations для версии 2026.");
        atomic_json(&dir.join("summary.json"),&json!({"overview":"Проверка бюджета","items":[{"text":"Отчёты проверены","owner":"Анна","due":"в пятницу","segmentIDs":[7]}],"cards":[{"id":"c1","front":"Running migrations","back":"Запуск миграций","context":"running migrations","segmentIDs":[7]}]})).unwrap();
        for query in ["БЮДЖЕТ", "отчет", "run", "migrating", "2026", "миграц"] {
            assert!(search(root.path(),query,"all",60).unwrap()["total"].as_i64().unwrap()>0,"{query}");
        }
        assert_eq!(search(root.path(),"Анна пятниц","notes",60).unwrap()["hits"][0]["itemIndex"],0);
        assert_eq!(search(root.path(),"2026","notes",60).unwrap()["total"],0);
        assert_eq!(search(root.path(),"budget","all",60).unwrap()["total"],0); // no semantic translation claim
        assert_eq!(search(root.path(),"running","cards",60).unwrap()["hits"][0]["cardID"],"c1");
        assert_eq!(search(root.path(),"бюджет","meetings",60).unwrap()["hits"][0]["kind"],"title");
    }
    #[test] fn replacement_corruption_deletion_and_valid_navigation() {
        let root=tempfile::tempdir().unwrap(); let dir=meeting(root.path(),"one","Исследование"); transcript(&dir,"Первоначальный протокол");
        atomic_json(&dir.join("summary.json"),&json!({"overview":"Обзор первоначального протокола","items":[{"text":"Старое правило","segmentIDs":[7]},{"text":"Несуществующая ссылка","segmentIDs":[999]}]})).unwrap();
        let result=search(root.path(),"правило","all",60).unwrap();
        assert_eq!(result["hits"][0]["segmentIDs"],json!([7])); assert_eq!(result["hits"][0]["start"],12.5);
        assert_eq!(search(root.path(),"несуществ","all",60).unwrap()["total"],0);
        transcript(&dir,"Обновлённый новый протокол");
        assert_eq!(search(root.path(),"первоначальный","transcript",60).unwrap()["total"],0);
        assert_eq!(search(root.path(),"новый","transcript",60).unwrap()["total"],1);
        fs::write(dir.join("summary.json"),b"{bad").unwrap();
        assert_eq!(search(root.path(),"правило","all",60).unwrap()["total"],0);
        fs::remove_file(dir.join("transcript.json")).unwrap();
        assert_eq!(search(root.path(),"протокол","all",60).unwrap()["total"],0);
        fs::remove_dir_all(dir).unwrap();
        assert_eq!(search(root.path(),"исследование","all",60).unwrap()["total"],0);
    }
    #[test] fn query_operators_are_data_and_empty_query_is_safe() {
        let root=tempfile::tempdir().unwrap(); let dir=meeting(root.path(),"one","Normal title"); transcript(&dir,"normal token");
        for query in ["\" OR 1=1 --", "normal* NOT token", "body:normal", "'; DROP TABLE documents;--", "\0"] {
            search(root.path(),query,"all",60).unwrap();
        }
        assert_eq!(search(root.path(),"normal","all",60).unwrap()["total"],2);
        assert_eq!(search(root.path(),"  !!! ","all",60).unwrap()["total"],0);
        assert!(search(root.path(),"normal","bad",60).is_err());
    }
    #[test] fn symlinks_and_damaged_entry_do_not_leak_or_block_library() {
        use std::os::unix::fs::symlink;
        let root=tempfile::tempdir().unwrap(); let dir=meeting(root.path(),"one","Ordinary meeting"); transcript(&dir,"Allowed text");
        let outside=tempfile::tempdir().unwrap(); fs::write(outside.path().join("secret.json"),br#"{"overview":"private token"}"#).unwrap();
        symlink(outside.path().join("secret.json"),dir.join("summary.json")).unwrap();
        let bad=meeting(root.path(),"bad","Broken"); fs::write(bad.join("meta.json"),b"{bad").unwrap();
        symlink(&dir,root.path().join("meetings/linked")).unwrap();
        assert_eq!(search(root.path(),"private","all",60).unwrap()["total"],0);
        assert_eq!(search(root.path(),"Allowed","all",60).unwrap()["total"],1);
        let index=root.path().join("cache/search/index.sqlite");
        assert_eq!(fs::metadata(index).unwrap().permissions().mode() & 0o777,0o600);
        assert_eq!(fs::metadata(root.path().join("cache/search")).unwrap().permissions().mode() & 0o777,0o700);
    }
    #[test] fn concurrent_index_sync_is_serialized_and_deterministic() {
        let root=tempfile::tempdir().unwrap(); let dir=meeting(root.path(),"one","Concurrent meeting"); transcript(&dir,"Concurrent content");
        let mut threads=Vec::new();
        for _ in 0..5 { let path=root.path().to_owned(); threads.push(std::thread::spawn(move||search(&path,"concurrent","all",1).unwrap())); }
        for thread in threads { let result=thread.join().unwrap(); assert_eq!(result["total"],2); assert_eq!(result["hits"].as_array().unwrap().len(),1); assert_eq!(result["truncated"],true); }
    }

    #[test] fn navigation_fingerprint_and_exact_text_are_preserved() {
        let root=tempfile::tempdir().unwrap(); let dir=meeting(root.path(),"one","Exact meeting"); transcript(&dir,"Recorded fact");
        atomic_json(&dir.join("summary.json"),&json!({"overview":"  Exact overview  ","items":[{"text":"  Exact note  ","owner":"Owner","due":"Friday","segmentIDs":[7]}],"cards":[{"id":"c1","front":"Front","back":"","context":"Recorded fact","segmentIDs":[7]}]})).unwrap();
        let result=search(root.path(),"Owner","all",60).unwrap();
        assert_eq!(result["hits"][0]["text"],"  Exact note  ");
        assert!(result["hits"][0]["snippet"].as_str().unwrap().contains("Friday"));
        let fp=result["hits"][0]["sourceFingerprint"].as_str().unwrap();
        assert_eq!(validate(root.path(),"one",fp).unwrap()["valid"],true);
        assert_eq!(search(root.path(),"front","cards",60).unwrap()["hits"][0]["text"],"Front\n\nRecorded fact");
        atomic_json(&dir.join("summary.json"),&json!({"overview":"Edited overview"})).unwrap();
        assert_eq!(validate(root.path(),"one",fp).unwrap()["valid"],false);
        assert_eq!(search(root.path(),"Owner","all",60).unwrap()["total"],0);
        assert_eq!(search(root.path(),"Edited","notes",60).unwrap()["total"],1);
        assert!(validate(root.path(),"../one",fp).is_err());
        fs::remove_dir_all(dir).unwrap();
        assert_eq!(validate(root.path(),"one",fp).unwrap()["valid"],false);
    }
    #[test] fn duplicate_segment_ids_and_oversized_json_cannot_keep_stale_refs() {
        let root=tempfile::tempdir().unwrap(); let dir=meeting(root.path(),"one","Valid title"); transcript(&dir,"Allowed evidence");
        atomic_json(&dir.join("summary.json"),&json!({"items":[{"text":"Grounded note","segmentIDs":[7]}]})).unwrap();
        assert_eq!(search(root.path(),"Grounded","all",60).unwrap()["total"],1);
        atomic_json(&dir.join("transcript.json"),&json!({"segments":[{"id":7,"start":0.0,"end":1.0,"text":"Duplicate first"},{"id":7,"start":2.0,"end":3.0,"text":"Duplicate second"}]})).unwrap();
        assert_eq!(search(root.path(),"duplicate","all",60).unwrap()["total"],0);
        assert_eq!(search(root.path(),"Grounded","all",60).unwrap()["total"],0);
        File::create(dir.join("transcript.json")).unwrap().set_len(MAX_TRANSCRIPT+1).unwrap();
        let result=search(root.path(),"valid","all",60).unwrap();
        assert_eq!(result["total"],1); assert!(!result["warnings"].as_array().unwrap().is_empty());
    }
    #[test] fn index_sidecar_symlink_is_rejected_without_touching_target() {
        use std::os::unix::fs::symlink;
        let root=tempfile::tempdir().unwrap(); meeting(root.path(),"one","Index title");
        search(root.path(),"Index","all",60).unwrap();
        let outside=tempfile::tempdir().unwrap(); let target=outside.path().join("untouched"); fs::write(&target,b"keep").unwrap();
        symlink(&target,root.path().join("cache/search/index.sqlite-journal")).unwrap();
        assert!(search(root.path(),"Index","all",60).is_err());
        assert_eq!(fs::read(target).unwrap(),b"keep");
    }

    #[test] fn snippets_unicode_and_equivalent_accents() {
        let root=tempfile::tempdir().unwrap(); let dir=meeting(root.path(),"one","Café Задачи");
        transcript(&dir,&format!("{} Ёжики выполнили согласованные задачи {}","начало ".repeat(100),"дальше ".repeat(100)));
        let result=search(root.path(),"ежик","transcript",60).unwrap();
        assert!(result["hits"][0]["snippet"].as_str().unwrap().contains("Ёжики"));
        assert!(result["hits"][0]["snippet"].as_str().unwrap().chars().count()<=240);
        assert_eq!(search(root.path(),"Cafe\u{301}","all",60).unwrap()["total"],1);
    }
}

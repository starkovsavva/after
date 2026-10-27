//! Explicit task-material code indexing. Never follows symlinks, opens arbitrary
//! caller paths, or grants the MCP agent filesystem access. The derived index is
//! rebuilt from current grants; every result is checked against originals.
use anyhow::{ensure, Context, Result};
use ignore::WalkBuilder;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::ffi::CString;
use std::fs::{self, OpenOptions};
use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};

const MAX_FILES: usize = 5_000;
const MAX_BYTES: usize = 32 * 1_048_576;
const MAX_FILE: u64 = 256 * 1024;
const MAX_CHUNKS: usize = 10_000;
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Grant {
    task_id: String,
    material_id: String,
    path: String,
    device: u64,
    inode: u64,
    #[serde(default)]
    revision: String,
    #[serde(default)]
    allow_cloud: bool,
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn config_path(root: &Path) -> PathBuf {
    root.join("code-index-grants.json")
}
fn grants(root: &Path) -> Result<Vec<Grant>> {
    let path = config_path(root);
    if !path.exists() {
        return Ok(vec![]);
    }
    let bytes = safe_read(&path, 256 * 1024)?;
    Ok(serde_json::from_slice(&bytes)?)
}
fn material(root: &Path, task: &str, id: &str) -> Result<Value> {
    let context =
        crate::task_workspace::dispatch(root, &json!({"command":"task-context","taskID":task}))?;
    context["materials"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|m| {
            m["id"].as_str() == Some(id)
                && ["folder", "repository"].contains(&m["kind"].as_str().unwrap_or(""))
                && m["available"] == true
        })
        .cloned()
        .context("Прикреплённая папка недоступна")
}
fn current_directory(root: &Path, grant: &Grant) -> Result<PathBuf> {
    let m = material(root, &grant.task_id, &grant.material_id)?;
    ensure!(
        m["path"].as_str() == Some(&grant.path),
        "Папка задачи изменилась: включите индексирование заново"
    );
    let path = PathBuf::from(&grant.path);
    ensure!(path.is_absolute(), "Нужна локальная папка");
    // Reject aliases in every ancestor, including the selected directory.
    let mut parent = path.as_path();
    loop {
        let info = fs::symlink_metadata(parent)?;
        ensure!(
            info.is_dir() && !info.file_type().is_symlink(),
            "Папка индекса не должна содержать символических ссылок"
        );
        if let Some(next) = parent.parent() {
            parent = next;
        } else {
            break;
        }
    }
    let info = fs::metadata(&path)?;
    ensure!(
        info.dev() == grant.device && info.ino() == grant.inode,
        "Выбранная папка была заменена"
    );
    Ok(path)
}
fn safe_read(path: &Path, maximum: u64) -> Result<Vec<u8>> {
    let info = fs::symlink_metadata(path)?;
    ensure!(
        info.is_file() && !info.file_type().is_symlink() && info.len() <= maximum,
        "Файл недоступен для индекса"
    );
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    let opened = file.metadata()?;
    ensure!(
        opened.is_file()
            && opened.dev() == info.dev()
            && opened.ino() == info.ino()
            && opened.len() <= maximum,
        "Файл изменился"
    );
    let mut out = Vec::new();
    file.take(maximum + 1).read_to_end(&mut out)?;
    ensure!(out.len() as u64 <= maximum, "Файл слишком большой");
    Ok(out)
}
/// Read relative to an already-opened authorized root. O_NOFOLLOW on every
/// openat component prevents an ancestor replacement from escaping the grant.
fn read_source(directory: &Path, grant: &Grant, relative: &str) -> Result<Vec<u8>> {
    let rel = Path::new(relative);
    ensure!(
        rel.components().all(|c| matches!(c, Component::Normal(_))),
        "Недопустимый путь исходника"
    );
    let mut parent = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(directory)?;
    let opened = parent.metadata()?;
    ensure!(
        opened.dev() == grant.device && opened.ino() == grant.inode,
        "Папка была заменена"
    );
    let parts = rel.components().collect::<Vec<_>>();
    ensure!(!parts.is_empty(), "Нет файла");
    for (index, component) in parts.iter().enumerate() {
        use std::os::unix::ffi::OsStrExt;
        let name = CString::new(component.as_os_str().as_bytes())?;
        let last = index + 1 == parts.len();
        let flags = libc::O_RDONLY
            | libc::O_NOFOLLOW
            | libc::O_CLOEXEC
            | if last { 0 } else { libc::O_DIRECTORY };
        let fd = unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), flags) };
        ensure!(fd >= 0, "Исходник недоступен или путь содержит ссылку");
        let mut file = unsafe { fs::File::from_raw_fd(fd) };
        if last {
            let info = file.metadata()?;
            ensure!(
                info.is_file() && info.nlink() == 1 && info.len() <= MAX_FILE,
                "Исходник слишком большой"
            );
            let mut bytes = Vec::new();
            (&mut file).take(MAX_FILE + 1).read_to_end(&mut bytes)?;
            ensure!(bytes.len() as u64 <= MAX_FILE, "Исходник слишком большой");
            return Ok(bytes);
        }
        parent = file;
    }
    anyhow::bail!("Нет файла исходника")
}
fn excluded(path: &Path, directory: bool) -> bool {
    let name = path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_lowercase();
    if name.starts_with('.')
        || [
            "node_modules",
            "vendor",
            "target",
            "dist",
            "build",
            "deriveddata",
            "pods",
            ".git",
            ".svn",
            ".hg",
            ".venv",
            "venv",
            "__pycache__",
            "secrets",
            "credentials",
        ]
        .contains(&name.as_str())
    {
        return true;
    }
    if directory {
        return false;
    }
    if [
        "credentials",
        "id_rsa",
        "id_ed25519",
        "authorized_keys",
        "known_hosts",
        "package-lock.json",
        "cargo.lock",
        "yarn.lock",
        "pnpm-lock.yaml",
    ]
    .contains(&name.as_str())
        || name.contains("secret")
        || name.contains("credential")
        || name.contains("private-key")
        || name.ends_with(".min.js")
        || name.ends_with(".map")
    {
        return true;
    }
    let ext = path
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_lowercase();
    ![
        "rs", "swift", "py", "js", "jsx", "ts", "tsx", "go", "java", "kt", "kts", "c", "h", "cpp",
        "hpp", "cs", "rb", "php", "sh", "bash", "zsh", "sql", "html", "css", "scss", "md", "txt",
        "toml", "yaml", "yml", "json", "xml", "proto", "graphql", "vue", "svelte",
    ]
    .contains(&ext.as_str())
        && !["dockerfile", "makefile", "justfile", "cmakelists.txt"].contains(&name.as_str())
}
fn secret_content(text: &str) -> bool {
    // Never persist obvious credentials, even in ordinary source files. This is
    // a conservative guard, not a claim to detect all possible secrets.
    let lower = text.to_lowercase();
    [
        "-----begin private key",
        "-----begin rsa private key",
        "-----begin openssh private key",
        "aws_secret_access_key",
        "\"private_key\":",
        "ghp_",
        "github_pat_",
        "sk-proj-",
    ]
    .iter()
    .any(|s| lower.contains(s))
}
fn walker(directory: &Path) -> ignore::Walk {
    walker_to(directory, None)
}
fn walker_to(directory: &Path, target: Option<PathBuf>) -> ignore::Walk {
    let mut builder = WalkBuilder::new(directory);
    builder
        .follow_links(false)
        .hidden(true)
        .git_ignore(true)
        .git_exclude(true)
        .git_global(true)
        .parents(true)
        .require_git(false)
        .add_custom_ignore_filename(".posleignore")
        .max_depth(Some(40))
        .filter_entry(move |e| {
            e.depth() == 0
                || (target
                    .as_ref()
                    .is_none_or(|wanted| wanted.starts_with(e.path()))
                    && !excluded(e.path(), e.file_type().is_some_and(|f| f.is_dir())))
        });
    builder.build()
}
fn file_permitted(directory: &Path, relative: &str) -> Result<PathBuf> {
    let rel = Path::new(relative);
    ensure!(
        !rel.as_os_str().is_empty() && rel.components().all(|c| matches!(c, Component::Normal(_))),
        "Недопустимый путь исходника"
    );
    let wanted = directory.join(rel);
    // WalkBuilder applies nested gitignore, .ignore and .posleignore with the
    // same rules as indexing. Policy changes take effect before a result opens.
    ensure!(
        walker_to(directory, Some(wanted.clone()))
            .take(MAX_FILES * 4)
            .filter_map(Result::ok)
            .any(|entry| entry.path() == wanted && entry.file_type().is_some_and(|f| f.is_file())),
        "Исходник исключён из индекса"
    );
    Ok(wanted)
}
pub(crate) fn documents(root:&Path)->Result<(Vec<crate::semantic::EmbeddingDocument>,Vec<String>)> { collect_documents(root,false) }
pub(crate) fn semantic_documents(root:&Path)->Result<(Vec<crate::semantic::EmbeddingDocument>,Vec<String>)> { collect_documents(root,true) }
fn collect_documents(root: &Path, semantic_only:bool) -> Result<(Vec<crate::semantic::EmbeddingDocument>, Vec<String>)> {
    if !crate::ai::live_features(root)?.tasks { return Ok((vec![], vec![])); }
    let mut out = Vec::new();
    let mut warnings = Vec::new();
    let mut bytes = 0usize;
    let mut files = 0usize;
    let mut entries = 0usize;
    for grant in grants(root)? {
        let scoped=crate::ai::live_features_for_input(root,&json!({"taskID":grant.task_id}))?;
        if !scoped.tasks || (semantic_only && !scoped.semantic_search) { continue; }
        if !crate::ai::live_features(root)?.tasks { return Ok((vec![], vec![])); }
        let directory = match current_directory(root, &grant) {
            Ok(p) => p,
            Err(_) => {
                warnings.push(
                    "Индекс папки пропущен: доступ отозван, материал удалён или папка перемещена."
                        .into(),
                );
                continue;
            }
        };
        for entry in walker(&directory) {
            if !crate::ai::live_features(root)?.tasks { return Ok((vec![], vec![])); }
            entries += 1;
            if entries > 20_000 {
                warnings.push("Достигнут лимит обхода папок: уточните .posleignore.".into());
                return Ok((out, warnings));
            }
            let Ok(entry) = entry else { continue };
            if !entry.file_type().is_some_and(|f| f.is_file()) {
                continue;
            }
            files += 1;
            if files > MAX_FILES || bytes >= MAX_BYTES || out.len() >= MAX_CHUNKS {
                warnings.push("Достигнут лимит индекса папок: 5000 файлов, 32 МБ текста или 10000 фрагментов. Исключите лишнее через .posleignore.".into());
                return Ok((out, warnings));
            }
            let relative = entry
                .path()
                .strip_prefix(&directory)?
                .to_string_lossy()
                .into_owned();
            let Ok(raw) = read_source(&directory, &grant, &relative) else {
                continue;
            };
            bytes += raw.len();
            let Ok(text) = std::str::from_utf8(&raw) else {
                continue;
            };
            if text.contains('\0') || secret_content(text) {
                continue;
            }
            let fp = digest(format!("{}:{}", grant.revision, digest(&raw)).as_bytes());
            let lines: Vec<_> = text.lines().collect();
            let mut index = 0usize;
            while index < lines.len() && out.len() < MAX_CHUNKS {
                let start = index;
                let mut chunk = String::new();
                while index < lines.len()
                    && (chunk.len() + lines[index].len() + 1 <= 3000 || index == start)
                {
                    // An enormous generated line is skipped, not silently truncated.
                    if lines[index].len() > 3000 {
                        index += 1;
                        break;
                    }
                    chunk.push_str(lines[index]);
                    chunk.push('\n');
                    index += 1;
                }
                if chunk.trim().is_empty() {
                    continue;
                }
                let id = format!(
                    "code_{}",
                    &digest(
                        format!(
                            "{}:{}:{}:{}",
                            grant.task_id, grant.material_id, relative, start
                        )
                        .as_bytes()
                    )[..32]
                );
                let source = json!({"id":format!("s_{}",&digest(id.as_bytes())[..24]),"kind":"code","title":relative,"excerpt":chunk,"sourceFingerprint":fp,"taskID":grant.task_id,"materialID":grant.material_id,"relativePath":relative,"lineStart":start+1,"lineEnd":index});
                out.push(crate::semantic::EmbeddingDocument::new(
                    id,
                    format!("{}\n{}", relative, chunk),
                    source,
                    grant.allow_cloud,
                ));
            }
        }
    }
    Ok((out, warnings))
}
pub(crate) fn source_current(root: &Path, source: &Value) -> Result<bool> {
    if !crate::ai::live_features_for_input(root,source)?.tasks { return Ok(false); }
    let (Some(task), Some(material), Some(relative), Some(fp)) = (
        source["taskID"].as_str(),
        source["materialID"].as_str(),
        source["relativePath"].as_str(),
        source["sourceFingerprint"].as_str(),
    ) else {
        return Ok(false);
    };
    let Some(grant) = grants(root)?
        .into_iter()
        .find(|g| g.task_id == task && g.material_id == material)
    else {
        return Ok(false);
    };
    let directory = current_directory(root, &grant)?;
    file_permitted(&directory, relative)?;
    let raw = read_source(&directory, &grant, relative)?;
    let text = std::str::from_utf8(&raw)?;
    if secret_content(text) {
        return Ok(false);
    }
    if digest(format!("{}:{}", grant.revision, digest(&raw)).as_bytes()) != fp
        || source["kind"] != "code"
        || source["title"].as_str() != Some(relative)
    {
        return Ok(false);
    }
    // Bind the excerpt and line span to the canonical chunk. A copied valid
    // file hash must never authenticate invented text in an answer or link.
    let lines = text.lines().collect::<Vec<_>>();
    let mut index = 0;
    while index < lines.len() {
        let start = index;
        let mut chunk = String::new();
        while index < lines.len()
            && (chunk.len() + lines[index].len() + 1 <= 3000 || index == start)
        {
            if lines[index].len() > 3000 {
                index += 1;
                break;
            }
            chunk.push_str(lines[index]);
            chunk.push('\n');
            index += 1;
        }
        if chunk.trim().is_empty() {
            continue;
        }
        if source["lineStart"].as_u64() == Some((start + 1) as u64)
            && source["lineEnd"].as_u64() == Some(index as u64)
        {
            let id = format!(
                "code_{}",
                &digest(
                    format!(
                        "{}:{}:{}:{}",
                        grant.task_id, grant.material_id, relative, start
                    )
                    .as_bytes()
                )[..32]
            );
            return Ok(source["excerpt"].as_str() == Some(&chunk)
                && source["id"].as_str() == Some(&format!("s_{}", &digest(id.as_bytes())[..24])));
        }
    }
    Ok(false)
}
pub fn dispatch(root: &Path, input: &Value) -> Result<Value> {
    ensure!(root.is_absolute(), "Нужен абсолютный путь библиотеки");
    match input["command"].as_str().unwrap_or("") {
        "code-index-grants" => Ok(
            json!({"grants":grants(root)?.iter().map(|g|json!({"taskID":g.task_id,"materialID":g.material_id,"allowCloud":g.allow_cloud,"available":current_directory(root,g).is_ok()})).collect::<Vec<_>>()}),
        ),
        "code-index-grant" => {
            // Serialize read-modify-write grants independently of task locks;
            // domain validation below acquires its own canonical workspace lock.
            let lock_path = root.join(".code-index.lock");
            let lock = OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(false)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(lock_path)?;
            lock.lock()?;
            let task = input["taskID"].as_str().context("Нет задачи")?;
            let id = input["materialID"].as_str().context("Нет материала")?;
            let enabled = input["enabled"]
                .as_bool()
                .context("Нет выбора индексирования")?;
            if enabled { ensure!(crate::ai::live_features_for_input(root,input)?.tasks, "Включите «Задачи и проекты» в профиле папки."); }
            let mut all = grants(root)?;
            all.retain(|g| g.task_id != task || g.material_id != id);
            if enabled {
                let m = material(root, task, id)?;
                let path = m["path"]
                    .as_str()
                    .context("Сначала прикрепите локальную папку")?;
                let info = fs::symlink_metadata(path)?;
                ensure!(
                    info.is_dir() && !info.file_type().is_symlink(),
                    "Выберите обычную папку"
                );
                let grant = Grant {
                    task_id: task.into(),
                    material_id: id.into(),
                    path: path.into(),
                    device: info.dev(),
                    inode: info.ino(),
                    revision: uuid::Uuid::new_v4().to_string(),
                    allow_cloud: input["allowCloud"].as_bool().unwrap_or(false),
                };
                current_directory(root, &grant)?;
                ensure!(all.len() < 64, "Не больше 64 папок");
                all.push(grant);
            }
            if enabled { ensure!(crate::ai::live_features_for_input(root,input)?.tasks, "Включите «Задачи и проекты» в профиле папки."); }
            crate::storage::atomic_json(&config_path(root), &serde_json::to_value(all)?)?;
            Ok(json!({"enabled":enabled,"rebuildRequired":true}))
        }
        "code-index-search" => {
            let q = input["query"].as_str().unwrap_or("");
            ensure!(!q.is_empty() && q.len() <= 512, "Введите короткий запрос");
            let matcher = crate::search::QueryMatcher::new(q)?;
            let (docs, warnings) = documents(root)?;
            let hits = docs
                .into_iter()
                .filter(|d| matcher.matches(&d.text))
                .take(30)
                .map(|d| d.source)
                .collect::<Vec<_>>();
            Ok(json!({"hits":hits,"warnings":warnings}))
        }
        "code-index-validate" => Ok(
            json!({"valid":source_current(root,input.get("source").unwrap_or(input)).unwrap_or(false)}),
        ),
        "code-index-open" => {
            let source = input.get("source").unwrap_or(input);
            ensure!(
                source_current(root, source)?,
                "Исходник изменён или доступ отозван"
            );
            let grant = grants(root)?
                .into_iter()
                .find(|g| {
                    Some(g.task_id.as_str()) == source["taskID"].as_str()
                        && Some(g.material_id.as_str()) == source["materialID"].as_str()
                })
                .context("Нет доступа")?;
            Ok(
                json!({"path":file_permitted(&current_directory(root,&grant)?,source["relativePath"].as_str().unwrap_or(""))?,"line":source["lineStart"]}),
            )
        }
        _ => anyhow::bail!("Неизвестная команда индекса папок"),
    }
}

pub(crate) fn cloud_allowed(root: &Path, source: &Value) -> bool {
    if !crate::ai::live_features_for_input(root,source).is_ok_and(|features| features.tasks) { return false; }
    grants(root).is_ok_and(|all| {
        all.iter().any(|g| {
            Some(g.task_id.as_str()) == source["taskID"].as_str()
                && Some(g.material_id.as_str()) == source["materialID"].as_str()
                && g.allow_cloud
        })
    })
}
pub(crate) fn answer_allowed(root: &Path, source: &Value) -> bool {
    if !crate::ai::live_features_for_input(root,source).is_ok_and(|features| features.tasks) { return false; }
    let cloud = crate::ai::settings_for_input(root,source)
        .map(|s| s.mode == "cloud")
        .unwrap_or(true);
    !cloud
        || grants(root).is_ok_and(|all| {
            all.iter().any(|g| {
                Some(g.task_id.as_str()) == source["taskID"].as_str()
                    && Some(g.material_id.as_str()) == source["materialID"].as_str()
                    && g.allow_cloud
            })
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    fn task(root: &Path, folder: &Path) -> (String, String) {
        crate::storage::atomic_json(&root.join("settings.json"), &json!({"features":{"tasks":true}})).unwrap();
        let t=crate::task_workspace::dispatch(root,&json!({"command":"task-create","title":"Review source","operationID":uuid::Uuid::new_v4().to_string()})).unwrap();
        let t=crate::task_workspace::dispatch(root,&json!({"command":"task-material-link","taskID":t["id"],"expectedRevision":t["revision"],"operationID":uuid::Uuid::new_v4().to_string(),"material":{"kind":"repository","title":"Example project","path":folder}})).unwrap();
        (
            t["id"].as_str().unwrap().into(),
            t["materials"][0]["id"].as_str().unwrap().into(),
        )
    }
    fn grant(root: &Path, task: &str, id: &str, on: bool) {
        dispatch(
            root,
            &json!({"command":"code-index-grant","taskID":task,"materialID":id,"enabled":on}),
        )
        .unwrap();
    }
    #[test]
    fn explicit_grant_gitignore_nested_rules_secrets_symlink_and_changed_deleted_sources() {
        let temp = tempfile::tempdir().unwrap();
        let base = temp.path().canonicalize().unwrap();
        let root = base.join("library");
        let code = base.join("project");
        fs::create_dir_all(code.join("sub")).unwrap();
        fs::create_dir_all(code.join("ignored")).unwrap();
        fs::write(code.join("main.rs"), "fn source() { resilience(); }\n").unwrap();
        fs::write(code.join(".gitignore"), "ignored/\n*.generated.rs\n").unwrap();
        fs::write(code.join("ignored/hidden.rs"), "secret omitted").unwrap();
        fs::write(code.join("sub/.gitignore"), "local.rs\n").unwrap();
        fs::write(code.join("sub/local.rs"), "not indexed").unwrap();
        fs::write(code.join(".posleignore"), "local-only.rs\n").unwrap();
        fs::write(code.join("local-only.rs"), "excluded").unwrap();
        fs::write(code.join("app.generated.rs"), "generated").unwrap();
        fs::write(code.join(".env"), "SECRET=abc").unwrap();
        fs::write(
            code.join("token.rs"),
            "let key = \"sk-proj-never-persist-this\";",
        )
        .unwrap();
        let outside = base.join("outside.rs");
        fs::write(&outside, "outside contents").unwrap();
        fs::hard_link(&outside, code.join("hardlink.rs")).unwrap();
        symlink(&outside, code.join("alias.rs")).unwrap();
        symlink(&base, code.join("escape")).unwrap();
        let (t, m) = task(&root, &code);
        assert!(
            documents(&root).unwrap().0.is_empty(),
            "attaching a folder alone does not authorize reading"
        );
        grant(&root, &t, &m, true);
        let (docs, _) = documents(&root).unwrap();
        assert_eq!(docs.len(), 1);
        let source = docs[0].source.clone();
        assert_eq!(source["relativePath"], "main.rs");
        assert!(source_current(&root, &source).unwrap());
        let mut forged = source.clone();
        forged["excerpt"] = json!("Invented fact");
        assert!(!source_current(&root, &forged).unwrap());
        let mut forged = source.clone();
        forged["lineStart"] = json!(999);
        assert!(!source_current(&root, &forged).unwrap());
        assert!(
            !answer_allowed(&root, &source) || crate::ai::settings(&root).unwrap().mode == "local"
        );
        fs::write(code.join("main.rs"), "fn changed() {}\n").unwrap();
        assert!(!source_current(&root, &source).unwrap());
        let current = documents(&root).unwrap().0[0].source.clone();
        fs::remove_file(code.join("main.rs")).unwrap();
        assert!(!source_current(&root, &current).unwrap_or(false));
    }
    #[test]
    fn grant_revoke_then_reenable_invalidates_old_results_and_detach_revokes() {
        let temp = tempfile::tempdir().unwrap();
        let base = temp.path().canonicalize().unwrap();
        let root = base.join("library");
        let code = base.join("project");
        fs::create_dir_all(&code).unwrap();
        fs::write(code.join("file.swift"), "let score = 42\n").unwrap();
        let (t, m) = task(&root, &code);
        grant(&root, &t, &m, true);
        let old = documents(&root).unwrap().0[0].source.clone();
        grant(&root, &t, &m, false);
        assert!(!source_current(&root, &old).unwrap());
        grant(&root, &t, &m, true);
        assert!(!source_current(&root, &old).unwrap());
        let new = documents(&root).unwrap().0[0].source.clone();
        assert!(source_current(&root, &new).unwrap());
        let current =
            crate::task_workspace::dispatch(&root, &json!({"command":"task-get","taskID":t}))
                .unwrap();
        crate::task_workspace::dispatch(&root,&json!({"command":"task-material-unlink","taskID":t,"materialID":m,"expectedRevision":current["revision"],"operationID":uuid::Uuid::new_v4().to_string()})).unwrap();
        assert!(!source_current(&root, &new).unwrap_or(false));
        assert!(documents(&root).unwrap().0.is_empty());
    }
    #[test]
    fn local_navigation_keeps_code_even_when_summary_model_is_cloud() {
        let temp = tempfile::tempdir().unwrap();
        let base = temp.path().canonicalize().unwrap();
        let root = base.join("library");
        let code = base.join("project");
        fs::create_dir_all(&code).unwrap();
        fs::write(code.join("file.rs"), "fn recovery() {}\n").unwrap();
        let (t, m) = task(&root, &code);
        grant(&root, &t, &m, true);
        crate::storage::atomic_json(&root.join("settings.json"), &json!({"mode":"cloud","features":{"tasks":true,"assistant":true}})).unwrap();
        let input = json!({"text":"recovery","query":"recovery","kinds":["code"]});
        let lookup = crate::knowledge::lookup(&root, &input).unwrap();
        assert_eq!(
            lookup["sources"].as_array().unwrap().len(),
            1,
            "local navigation does not transmit evidence to the summary model"
        );
        let answer = crate::knowledge::answer(&root, &input).unwrap();
        assert!(
            answer["sources"].as_array().unwrap().is_empty(),
            "local-only source cannot become cloud model evidence"
        );
    }

    #[test]
    fn exclusions_changed_after_index_immediately_invalidate_navigation() {
        let temp = tempfile::tempdir().unwrap();
        let base = temp.path().canonicalize().unwrap();
        let root = base.join("library");
        let code = base.join("project");
        fs::create_dir_all(&code).unwrap();
        fs::write(code.join("file.rs"), "fn source() {}\n").unwrap();
        let (t, m) = task(&root, &code);
        grant(&root, &t, &m, true);
        let old = documents(&root).unwrap().0[0].source.clone();
        fs::write(code.join(".gitignore"), "file.rs\n").unwrap();
        assert!(!source_current(&root, &old).unwrap_or(false));
        assert!(dispatch(&root, &json!({"command":"code-index-open","source":old})).is_err());
        assert!(dispatch(&root,&json!({"command":"code-index-grant","taskID":t,"materialID":"arbitrary","enabled":true,"path":"/arbitrary"})).is_err());
    }
    #[test]
    fn disabling_tasks_stops_folder_reads_and_rejects_old_routes_without_revoking_grants() {
        let temp = tempfile::tempdir().unwrap(); let base = temp.path().canonicalize().unwrap();
        let root=base.join("library"); let code=base.join("project"); fs::create_dir_all(&code).unwrap();
        fs::write(code.join("main.rs"),"fn recovery() {}\n").unwrap();
        let (t,m)=task(&root,&code); grant(&root,&t,&m,true);
        let before=documents(&root).unwrap(); let source=before.0[0].source.clone();
        crate::storage::atomic_json(&root.join("settings.json"),&json!({"features":{}})).unwrap();
        assert!(documents(&root).unwrap().0.is_empty());
        assert!(!source_current(&root,&source).unwrap());
        assert!(dispatch(&root,&json!({"command":"code-index-open","source":source})).is_err());
        assert!(!cloud_allowed(&root,&source)); assert!(!answer_allowed(&root,&source));
        assert_eq!(grants(&root).unwrap().len(),1);
        crate::storage::atomic_json(&root.join("settings.json"),&json!({"features":{"tasks":true}})).unwrap();
        assert_eq!(documents(&root).unwrap().0.len(),before.0.len());
        assert!(source_current(&root,&source).unwrap());
    }

}

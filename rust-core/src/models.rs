//! Bounded, read-only model discovery. Works before the Python runtime is installed.
use anyhow::{bail, Result};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::{HashSet, VecDeque};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

const MAX_DIRECTORIES: usize = 800;
const MAX_ENTRIES: usize = 512;
const MAX_DEPTH: usize = 6;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Model {
    id: String,
    name: String,
    path: String,
    format: String,
    source: String,
    compatible: bool,
    reason: String,
}

fn nonempty(path: &Path) -> bool {
    fs::metadata(path).is_ok_and(|info| info.is_file() && info.len() > 0)
}

fn json_file(path: &Path) -> Option<Value> {
    if fs::metadata(path).ok()?.len() > 1_000_000 { return None; }
    serde_json::from_slice(&fs::read(path).ok()?).ok()
}

fn names(path: &Path) -> Vec<String> {
    let mut result: Vec<_> = fs::read_dir(path).into_iter().flatten().take(MAX_ENTRIES)
        .filter_map(|entry| entry.ok()?.file_name().into_string().ok()).collect();
    result.sort();
    result
}

fn weight(path: &Path, minimum: u64) -> bool {
    if !fs::metadata(path).is_ok_and(|info| info.is_file() && info.len() >= minimum) { return false; }
    let mut prefix = [0u8; 64];
    fs::File::open(path).and_then(|mut f| f.read(&mut prefix)).is_ok()
        && !prefix.starts_with(b"version https://git-lfs.github.com/spec/")
}
fn safetensors(path: &Path) -> bool {
    if !weight(path, 1024) { return false; }
    let check = || -> Option<()> {
        let mut f = fs::File::open(path).ok()?;
        let size = f.metadata().ok()?.len();
        let mut bytes = [0u8; 8]; f.read_exact(&mut bytes).ok()?;
        let length = u64::from_le_bytes(bytes);
        if !(2..=16 * 1024 * 1024).contains(&length) || length + 8 > size { return None; }
        let mut header = vec![0; length as usize]; f.read_exact(&mut header).ok()?;
        let data: Value = serde_json::from_slice(&header).ok()?;
        let mut tensors = 0;
        for (key, value) in data.as_object()? {
            if key == "__metadata__" { continue; }
            let offsets = value["data_offsets"].as_array()?;
            if offsets.len() != 2 { return None; }
            let start = offsets[0].as_u64()?; let end = offsets[1].as_u64()?;
            if start > end || end > size - 8 - length { return None; }
            tensors += 1;
        }
        (tensors > 0).then_some(())
    };
    check().is_some()
}
fn vocabulary(path: &Path) -> bool {
    if !fs::metadata(path).is_ok_and(|m| m.is_file() && (10..=1_048_576).contains(&m.len())) { return false; }
    let Ok(text) = fs::read_to_string(path) else { return false; };
    let mut blank = false;
    for line in text.lines().filter(|line| !line.trim().is_empty()) {
        let Some((token, id)) = line.rsplit_once(' ') else { return false; };
        if id.is_empty() || !id.bytes().all(|c| c.is_ascii_digit()) { return false; }
        blank |= token == "<blk>";
    }
    blank
}
fn onnx_file(path: &Path, stem: &str) -> Option<PathBuf> {
    [".int8", ".fp16", ""].into_iter().map(|suffix| path.join(format!("{stem}{suffix}.onnx"))).find(|p| p.is_file())
}

fn classify(path: &Path, source: &str) -> Model {
    let canonical = fs::canonicalize(path).unwrap_or_else(|_| path.to_owned());
    let entries = names(&canonical);
    let mut model = Model {
        id: canonical.to_string_lossy().into_owned(),
        name: canonical.file_name().unwrap_or_default().to_string_lossy().into_owned(),
        path: canonical.to_string_lossy().into_owned(), format: "auto".into(),
        source: source.into(), compatible: false,
        reason: "В папке не найден совместимый Parakeet. Нужны MLX или поддерживаемые ONNX-файлы.".into(),
    };
    if let Some(parent) = canonical.parent().and_then(Path::parent).and_then(Path::file_name) {
        let parent = parent.to_string_lossy();
        if parent.starts_with("models--") { model.name = parent.trim_start_matches("models--").replace("--", "/"); }
    }
    let has = |name: &str| nonempty(&canonical.join(name));
    let onnx = |prefix: &str| entries.iter().any(|name| name.starts_with(prefix) && name.ends_with(".onnx") && has(name));
    let has_mlx = entries.iter().any(|name| name.ends_with(".safetensors"));
    let meetily = if has_mlx { None } else { onnx_file(&canonical, "encoder-model").zip(onnx_file(&canonical, "decoder_joint-model")) };
    if let Some((encoder, decoder)) = meetily {
        model.format = "onnx".into();
        let fp32_data = encoder.file_name().is_some_and(|n| n == "encoder-model.onnx")
            && fs::metadata(&encoder).is_ok_and(|m| m.len() < 200_000_000);
        let min_encoder = if encoder.to_string_lossy().contains(".int8.onnx") { 100_000_000 } else { 1_000_000 };
        let config_ok = !has("config.json") || json_file(&canonical.join("config.json")).is_some_and(|c| {
            c.get("model_type").is_none_or(|v| v == "nemo-conformer-tdt")
                && c.get("features_size").is_none_or(|v| v == 128)
        });
        model.compatible = weight(&encoder, min_encoder) && weight(&decoder, 1_000_000)
            && (!fp32_data || weight(&canonical.join("encoder-model.onnx.data"), 1_000_000_000))
            && weight(&canonical.join("nemo128.onnx"), 1024) && vocabulary(&canonical.join("vocab.txt")) && config_ok
            && canonical.to_string_lossy().to_lowercase().contains("parakeet");
        model.name = format!("Parakeet ONNX · {}", model.name);
        model.reason = if model.compatible {
            "Формат ONNX Parakeet. Веса используются без копирования; граф проверяется при запуске."
        } else { "Набор ONNX Parakeet неполный: проверьте encoder, decoder_joint, nemo128, vocab.txt и внешние .data-файлы." }.into();
    } else if !has_mlx && onnx("encoder") && onnx("decoder") && onnx("joiner") {
        model.format = "onnx".into();
        model.compatible = [("encoder", 100_000_000), ("decoder", 1_000_000), ("joiner", 100_000)].into_iter()
            .all(|(stem, minimum)| onnx_file(&canonical, stem).is_some_and(|p| weight(&p, minimum)))
            && vocabulary(&canonical.join("tokens.txt")) && canonical.to_string_lossy().to_lowercase().contains("parakeet");
        model.name = format!("Parakeet Sherpa ONNX · {}", model.name);
        model.reason = if model.compatible {
            "Формат Sherpa ONNX. Веса используются без копирования; граф проверяется при запуске."
        } else { "Набор Sherpa ONNX неполный или не удалось подтвердить модель Parakeet." }.into();
    } else if has("config.json") {
        if let Some(config) = json_file(&canonical.join("config.json")) {
            let parakeet = config["encoder"].is_object() && config["joint"].is_object()
                && config["joint"]["vocabulary"].as_array().is_some_and(|a| !a.is_empty())
                && config["model_defaults"]["tdt_durations"].as_array().is_some_and(|a| !a.is_empty());
            let weights: Vec<_> = entries.iter().filter(|n| n.ends_with(".safetensors")).collect();
            let index_ok = !has("model.safetensors.index.json") || json_file(&canonical.join("model.safetensors.index.json"))
                .and_then(|v| v["weight_map"].as_object().cloned()).is_some_and(|map| !map.is_empty() && map.values().all(|v| v == "model.safetensors"));
            if parakeet && weights.len() == 1 && weights[0] == "model.safetensors" && index_ok && safetensors(&canonical.join("model.safetensors")) {
                model.format = "mlx".into(); model.compatible = true;
                model.name = format!("Parakeet MLX · {}", model.name);
                model.reason = "MLX-модель используется из этой папки без повторной загрузки.".into();
            } else if parakeet {
                model.reason = "Веса Parakeet MLX неполные либо формат не поддерживается. Нужен целый model.safetensors.".into();
            } else {
                model.reason = "Это другая модель. Для распознавания выберите папку Parakeet.".into();
            }
        }
    } else if entries.iter().any(|name| name.ends_with(".gguf") || name.ends_with(".nemo")) {
        model.reason = "GGUF и .nemo нельзя подключить как MLX или ONNX. Укажите совместимую папку Parakeet.".into();
    } else if onnx("encoder") || onnx("decoder") {
        model.reason = "Найден неполный набор ONNX. Нужны все файлы модели из исходного скачивания.".into();
    }
    if model.compatible && canonical.to_string_lossy().to_lowercase().contains("v2") {
        model.reason.push_str(" Проверьте язык: Parakeet v2 обычно поддерживает только английский; для русского нужен v3.");
    }
    model
}

fn default_roots(root: &Path, home: &Path) -> Vec<(PathBuf, &'static str)> {
    let mut result = vec![(root.join("cache/huggingface/hub"), "After")];
    for name in ["HF_HUB_CACHE", "HUGGINGFACE_HUB_CACHE"] {
        if let Some(value) = std::env::var_os(name) { result.push((PathBuf::from(value), "Hugging Face")); }
    }
    if let Some(value) = std::env::var_os("HF_HOME") { result.push((PathBuf::from(value).join("hub"), "Hugging Face")); }
    result.extend([
        (home.join(".cache/huggingface/hub"), "Hugging Face"),
        (home.join("Library/Caches/huggingface/hub"), "Hugging Face"),
        (home.join("Library/Application Support/Meetily/models"), "Локальная папка моделей"),
        (home.join("Library/Application Support/meetily/models"), "Локальная папка моделей"),
        (home.join("Library/Application Support/com.meetily.ai/models"), "Локальная папка моделей"),
        (home.join(".lmstudio/models"), "LM Studio"),
        (home.join(".cache/lm-studio/models"), "LM Studio"),
    ]);
    result
}

fn scan(roots: Vec<(PathBuf, &str)>, explicit: bool) -> Value {
    let mut visited = HashSet::new();
    let mut models = Vec::new();
    let mut stack: VecDeque<_> = roots.into_iter().map(|(path, source)| (path, source, 0)).collect();
    let mut skipped = 0;
    while let Some((path, source, depth)) = stack.pop_front() {
        if visited.len() >= MAX_DIRECTORIES { skipped += 1; break; }
        let Ok(path) = fs::canonicalize(path) else { continue; };
        if !path.is_dir() || !visited.insert(path.clone()) { continue; }
        let lower = path.to_string_lossy().to_lowercase();
        // Do not open arbitrary config files in unrelated model caches.
        let files = names(&path);
        let artifacts = files.iter().any(|n| n.ends_with(".onnx") || n.ends_with(".safetensors") || n.ends_with(".gguf") || n.ends_with(".nemo"));
        let candidate = files.iter().any(|n| n.starts_with("encoder-model"))
            || files.iter().any(|n| n == "model.safetensors") && files.iter().any(|n| n == "config.json");
        if explicit && depth == 0 || artifacts && (lower.contains("parakeet") || candidate) {
            let model = classify(&path, source);
            if model.compatible || explicit && depth == 0 || lower.contains("parakeet") { models.push(model); }
            if models.last().is_some_and(|model| model.path == path.to_string_lossy() && model.compatible) { continue; }
        }
        if depth >= MAX_DEPTH { skipped += 1; continue; }
        let Ok(entries) = fs::read_dir(&path) else { continue; };
        for entry in entries.take(MAX_ENTRIES).flatten() {
            let Ok(kind) = entry.file_type() else { continue; };
            // HF weight symlinks are read by validators; directory links are not traversed.
            let skip = ["blobs", ".locks", "refs", "meetings", "transcriptions", "recordings", "test_wavs", ".git"];
            if kind.is_dir() && !skip.contains(&entry.file_name().to_string_lossy().as_ref()) { stack.push_back((entry.path(), source, depth + 1)); }
        }
    }
    models.sort_by_key(|model| (!model.compatible, model.path.to_lowercase().contains("v2"), model.format != "mlx", model.path.clone()));
    models.dedup_by(|a, b| a.path == b.path);
    let mut notes = Vec::new();
    if models.is_empty() { notes.push("Готовые модели Parakeet не найдены в стандартных папках. Можно выбрать папку вручную.".to_owned()); }
    if skipped > 0 { notes.push("Поиск ограничен папками моделей. Для вложенной папки используйте ручной выбор.".to_owned()); }
    json!({"asrModels":models,"notes":notes})
}

pub fn discover(root: &Path, selected: Option<&Path>) -> Result<Value> {
    if let Some(path) = selected {
        if !path.is_absolute() || !path.is_dir() { bail!("Выберите существующую папку Parakeet."); }
        return Ok(scan(vec![(path.to_owned(), "Выбрано вручную")], true));
    }
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let mut roots = default_roots(root, &home);
    if let Some(path) = json_file(&root.join("settings.json")).and_then(|s| s["asrModelPath"].as_str().map(PathBuf::from)).filter(|p| p.is_absolute()) {
        roots.push((path, "Выбрано в настройках"));
    }
    Ok(scan(roots, false))
}

/// Find standalone LLM weights without loading a model or starting a server.
pub fn discover_gguf(_root: &Path) -> Result<Value> {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let mut roots = vec![
        (home.join(".lmstudio/models"), "LM Studio"),
        (home.join(".cache/lm-studio/models"), "LM Studio"),
    ];
    for app in ["Meetily", "meetily", "com.meetily.ai"] {
        roots.push((home.join("Library/Application Support").join(app).join("models/summary"), "Локальная папка моделей"));
    }
    Ok(scan_gguf(roots))
}
fn scan_gguf(roots: Vec<(PathBuf, &str)>) -> Value {
    let mut stack: VecDeque<_> = roots.into_iter().map(|(path, source)| (path, source, 0)).collect();
    let mut visited = HashSet::new();
    let mut found = Vec::new();
    while let Some((path, source, depth)) = stack.pop_front() {
        if visited.len() >= 800 { break; }
        let Ok(path) = fs::canonicalize(path) else { continue; };
        if !path.is_dir() || !visited.insert(path.clone()) { continue; }
        let Ok(entries) = fs::read_dir(path) else { continue; };
        for entry in entries.take(MAX_ENTRIES).flatten() {
            let Ok(info) = entry.metadata() else { continue; };
            let name = entry.file_name(); let name = name.to_string_lossy();
            if info.is_file() && name.to_lowercase().ends_with(".gguf") && info.len() >= 1_048_576 {
                let Ok(mut file) = fs::File::open(entry.path()) else { continue; };
                let mut magic = [0u8; 4];
                if file.read_exact(&mut magic).is_err() || &magic != b"GGUF" { continue; }
                let Ok(canonical) = fs::canonicalize(entry.path()) else { continue; };
                let path = canonical.to_string_lossy().into_owned();
                found.push(json!({"id":path,"path":path,"name":name,"source":source,"sizeBytes":info.len()}));
            } else if info.is_dir() && depth < 5 && entry.file_type().is_ok_and(|kind| !kind.is_symlink())
                && !["meetings", "recordings", "transcriptions", ".git"].contains(&name.as_ref()) {
                stack.push_back((entry.path(), source, depth + 1));
            }
        }
    }
    found.sort_by(|a,b| a["path"].as_str().cmp(&b["path"].as_str()));
    found.dedup_by(|a,b| a["path"] == b["path"]);
    let notes: Vec<String> = if found.is_empty() { vec!["GGUF в стандартных папках не найден. Можно выбрать файл вручную.".into()] } else { Vec::new() };
    json!({"ggufModels":found,"notes":notes})
}

#[cfg(test)]
mod tests {
    use super::*;
    fn put(path: &Path, name: &str, bytes: &[u8]) { fs::write(path.join(name), bytes).unwrap(); }
    fn sparse(path: &Path, name: &str, bytes: u64) { fs::File::create(path.join(name)).unwrap().set_len(bytes).unwrap(); }
    fn meetily(path: &Path) {
        sparse(path, "encoder-model.int8.onnx", 100_000_000);
        sparse(path, "decoder_joint-model.int8.onnx", 1_000_000);
        sparse(path, "nemo128.onnx", 1024);
        put(path, "vocab.txt", b"<blk> 0\nword 1\n");
    }
    #[test]
    fn complete_meetily_model_is_reused_without_writes() {
        let root = tempfile::Builder::new().prefix("parakeet-test-").tempdir().unwrap(); meetily(root.path());
        let before = fs::read_dir(root.path()).unwrap().count();
        let found = discover(root.path(), Some(root.path())).unwrap();
        assert_eq!(found["asrModels"][0]["compatible"], true);
        assert_eq!(found["asrModels"][0]["format"], "onnx");
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), before);
    }
    #[test]
    fn incomplete_meetily_and_unrelated_llms_are_not_offered() {
        let root = tempfile::Builder::new().prefix("parakeet-test-").tempdir().unwrap(); meetily(root.path());
        fs::remove_file(root.path().join("nemo128.onnx")).unwrap();
        assert!(!classify(root.path(), "test").compatible);
        put(root.path(), "config.json", br#"{"model_type":"qwen3"}"#);
        put(root.path(), "model.safetensors", b"fixture");
        assert!(!classify(root.path(), "test").compatible);
    }
    #[test]
    fn mlx_requires_supported_config_and_complete_tensor_payload() {
        let root = tempfile::tempdir().unwrap();
        put(root.path(), "config.json", br#"{"encoder":{},"joint":{"vocabulary":["word"]},"model_defaults":{"tdt_durations":[0,1]}}"#);
        let header = br#"{"tensor":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}"#;
        let mut data = (header.len() as u64).to_le_bytes().to_vec(); data.extend_from_slice(header); data.resize(1024, 0);
        put(root.path(), "model.safetensors", &data);
        assert!(classify(root.path(), "test").compatible);
        let broken = br#"{"tensor":{"data_offsets":[0,5000]}}"#;
        let mut data = (broken.len() as u64).to_le_bytes().to_vec(); data.extend_from_slice(broken); data.resize(1024, 0);
        put(root.path(), "model.safetensors", &data);
        assert!(!classify(root.path(), "test").compatible);
    }
    #[test]
    fn loops_and_corpus_folders_are_not_scanned() {
        let root = tempfile::tempdir().unwrap();
        let folder = root.path().join("parakeet-v3"); fs::create_dir(&folder).unwrap(); meetily(&folder);
        std::os::unix::fs::symlink(root.path(), folder.join("loop")).unwrap();
        let meetings = root.path().join("meetings"); fs::create_dir(&meetings).unwrap();
        let hidden = meetings.join("parakeet-v3"); fs::create_dir(&hidden).unwrap(); meetily(&hidden);
        let result = scan(vec![(root.path().to_owned(), "test")], false);
        assert_eq!(result["asrModels"].as_array().unwrap().len(), 1);
    }
    #[test]
    fn gguf_discovery_checks_magic_and_skips_meeting_folders() {
        let root = tempfile::tempdir().unwrap();
        let model = root.path().join("Qwen.gguf");
        fs::write(&model, b"GGUF").unwrap(); fs::OpenOptions::new().write(true).open(&model).unwrap().set_len(1_048_576).unwrap();
        sparse(root.path(), "broken.gguf", 1_048_576);
        let meetings = root.path().join("meetings"); fs::create_dir(&meetings).unwrap();
        fs::copy(&model, meetings.join("private.gguf")).unwrap();
        let found = scan_gguf(vec![(root.path().to_owned(), "test")]);
        assert_eq!(found["ggufModels"].as_array().unwrap().len(), 1);
        assert_eq!(found["ggufModels"][0]["name"], "Qwen.gguf");
        assert_eq!(fs::read(&model).unwrap()[..4], *b"GGUF");
    }

}

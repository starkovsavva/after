mod python_host;

use anyhow::{bail, Context, Result};
use clap::{Parser, ValueEnum};
use posle_core::{ai, media, models, search, storage, worker};
use serde_json::{json, Value};
use std::io::{self, Read};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, ValueEnum)]
enum Command { Prepare, Transcribe, Diarize, Finalize, InstallLocal, InstallRuntime, Summarize, Example, Review, Check, CheckCloud, Pull, DiscoverModels, DiscoverLocal, DiscoverGguf, ImportGguf, Search, List, Import, Update, NotesList, NoteSave, NoteDelete, ContextSave, TemplateSave, TemplateDelete, NoteAttach, AttachmentRemove, AttachmentText, AttachmentPath, NotesSearch, NotesTasks, NotesBrief, ExpandNotes, CardsImport, CardsImportPreview, VoicePlan }

#[derive(Parser)]
#[command(version, about="После: ядро библиотеки и обработки встреч")]
struct Args {
    #[arg(value_enum)] command: Command,
    #[arg(long)] root: PathBuf,
    #[arg(long)] backend: Option<PathBuf>,
    #[arg(long)] meeting: Option<PathBuf>,
    #[arg(long)] path: Option<PathBuf>,
    #[arg(long, default_value="")] card: String,
    #[arg(long, default_value="")] note: String,
    #[arg(long, default_value="auto")] separator: String,
    #[arg(long)] title: Option<String>,
    #[arg(long, default_value_t=3)] rating: u8,
    #[arg(long, default_value_t=0)] speakers: u32,
    #[arg(long)] no_diarization: bool,
    #[arg(long)] replace_manual_summary: bool,
    #[arg(long, default_value="")] query: String,
    #[arg(long, default_value="all")] scope: String,
    #[arg(long, default_value_t=60)] limit: usize,
}

fn backend_path(override_path: Option<&Path>) -> Result<PathBuf> {
    if let Some(path) = override_path { return Ok(path.to_owned()); }
    let executable = std::env::current_exe()?;
    if let Some(contents) = worker::application_contents(&executable) {
        return Ok(contents.join("Resources/backend"));
    }
    Ok(Path::new(env!("CARGO_MANIFEST_DIR")).join("../backend"))
}

const VOICE_INPUT_LIMIT: usize = 256 * 1024;

fn read_voice_input(reader: impl Read) -> Result<Value> {
    let mut bytes = Vec::new();
    reader.take((VOICE_INPUT_LIMIT + 1) as u64).read_to_end(&mut bytes)?;
    if bytes.len() > VOICE_INPUT_LIMIT {
        bail!("Контекст помощника слишком большой. Сократите диапазон календаря или вопрос.");
    }
    serde_json::from_slice(&bytes).context("Не удалось прочитать запрос помощника")
}

fn run(args: Args) -> Result<Value> {
    if !args.root.is_absolute() { bail!("Нужен абсолютный путь папки приложения"); }
    let backend = backend_path(args.backend.as_deref())?;
    let directory = if let Some(path) = &args.meeting {
        let id = path.file_name().and_then(|s| s.to_str()).context("Некорректный ID встречи")?;
        let expected = storage::meeting_directory(&args.root, id)?;
        if path != &expected { bail!("Встреча должна находиться в библиотеке приложения"); }
        Some(expected)
    } else { None };
    let required = || directory.as_deref().context("Выберите встречу");
    match args.command {
        Command::Finalize => { media::finalize(&args.root, required()?)?; Ok(json!({})) }
        Command::Prepare | Command::Transcribe | Command::Diarize | Command::InstallLocal => {
            let command = match args.command { Command::Prepare=>"prepare", Command::Transcribe=>"transcribe", Command::Diarize=>"diarize", _=>"install-local" };
            worker::run_worker(&args.root, &backend, command, directory.as_deref(), args.speakers, !args.no_diarization)?;
            Ok(json!({}))
        }
        Command::InstallRuntime => { worker::install_runtime(&args.root, &backend)?; Ok(json!({})) }
        Command::Summarize => { ai::summarize_with_options(&args.root, required()?, args.replace_manual_summary)?; Ok(json!({})) }
        Command::Example => { ai::example(&args.root, required()?, &args.card)?; Ok(json!({})) }
        Command::Review => {
            let id = required()?.file_name().and_then(|s|s.to_str()).context("Нет ID")?;
            storage::review(&args.root, id, &args.card, args.rating)
        }
        Command::Check => ai::check(&args.root),
        Command::CheckCloud => ai::check_cloud(&args.root),
        Command::DiscoverModels => models::discover(&args.root, args.path.as_deref()),
        Command::DiscoverLocal => ai::discover_local_models(&args.root),
        Command::DiscoverGguf => models::discover_gguf(&args.root),
        Command::ImportGguf => ai::import_gguf(&args.root, args.path.as_deref().context("Выберите файл GGUF")?),
        Command::Pull => { ai::pull(&args.root)?; Ok(json!({})) }
        Command::Search => search::search(&args.root, &args.query, &args.scope, args.limit),
        Command::List => Ok(json!({"meetings":storage::list_meetings(&args.root)?})),
        Command::CardsImport => posle_core::cards::import(&args.root,args.path.as_deref().context("Выберите CSV/TSV файл")?,Some(&args.separator),args.title.as_deref()),
        Command::CardsImportPreview => posle_core::cards::preview(args.path.as_deref().context("Выберите CSV/TSV файл")?,Some(&args.separator)),
        Command::ExpandNotes => { ai::expand_note(&args.root, &args.note)?; Ok(json!({})) }
        Command::VoicePlan => {
            let mut request = read_voice_input(io::stdin())?; request["root"]=json!(args.root); request["command"]=json!("voice-plan");
            Ok(json!({"voicePlan":posle_core::request(&request)?}))
        }
        Command::NotesList => posle_core::request(&json!({"root":args.root,"command":"notes-list"})),
        Command::NotesSearch => posle_core::request(&json!({"root":args.root,"command":"notes-search","query":args.query,"scope":args.scope})),
        Command::NotesTasks => posle_core::request(&json!({"root":args.root,"command":"notes-tasks"})),
        Command::NotesBrief => posle_core::request(&json!({"root":args.root,"command":"notes-brief","meetingID":args.note})),
        Command::NoteSave | Command::NoteDelete | Command::ContextSave | Command::TemplateSave | Command::TemplateDelete | Command::NoteAttach | Command::AttachmentRemove | Command::AttachmentText | Command::AttachmentPath => {
            let command=match args.command {
                Command::NoteSave=>"note-save",Command::NoteDelete=>"note-delete",Command::ContextSave=>"context-save",Command::TemplateSave=>"template-save",Command::TemplateDelete=>"template-delete",Command::NoteAttach=>"note-attach",Command::AttachmentRemove=>"attachment-remove",Command::AttachmentText=>"attachment-text",_=>"attachment-path",
            };
            let mut input=String::new(); io::stdin().take(1_000_000).read_to_string(&mut input)?;
            let mut request:Value=serde_json::from_str(&input)?; request["root"]=json!(args.root); request["command"]=json!(command); posle_core::request(&request)
        }
        Command::Import | Command::Update => {
            let mut input = String::new(); io::stdin().take(1_000_000).read_to_string(&mut input)?;
            let mut request: Value = serde_json::from_str(&input)?;
            request["root"] = json!(args.root);
            request["command"] = json!(if matches!(args.command, Command::Import) {"import"} else {"update"});
            posle_core::request(&request)
        }
    }
}

fn main() {
    if std::env::args_os().nth(1).as_deref() == Some(std::ffi::OsStr::new("mcp")) {
        let args: Vec<_> = std::env::args_os().skip(2).collect();
        let result = if args.len() == 2 && args[0] == "--root" { posle_core::mcp::run_stdio(PathBuf::from(&args[1])) }
            else { Err(anyhow::anyhow!("Usage: posle-engine mcp --root /absolute/library/path")) };
        if let Err(error) = result { eprintln!("{error}"); std::process::exit(1); }
        return;
    }
    if std::env::args_os().nth(1).as_deref() == Some(std::ffi::OsStr::new(posle_core::python_runtime::VERIFY_MODE)) {
        let args: Vec<_> = std::env::args_os().skip(2).collect();
        let result = if args.len() == 1 { posle_core::python_runtime::verify_distribution(Path::new(&args[0])) }
            else { Err(anyhow::anyhow!("Нужен один абсолютный путь компонентов Python.")) };
        let code = match result {
            Ok(()) => { println!("Python runtime integrity verified"); 0 },
            Err(error) => { eprintln!("{error}"); 1 },
        };
        std::process::exit(code);
    }
    // The helper remains the real executable while the selected CPython
    // runtime performs MLX/ONNX/media work inside this native process.
    if std::env::args_os().nth(1).as_deref() == Some(std::ffi::OsStr::new(python_host::INTERNAL_MODE)) {
        let code = match python_host::run(std::env::args_os().skip(2).collect()) {
            Ok(code) => code,
            Err(error) => {
                println!("{}", json!({"event":"error", "message":error.to_string()}));
                1
            }
        };
        std::process::exit(code);
    }
    // Rust owns domain logic; the embedded worker is limited to MLX/ONNX/media.
    let result = run(Args::parse());
    match result {
        Ok(value) => {
            let mut event = value.as_object().cloned().unwrap_or_default();
            event.insert("event".into(), json!("done"));
            println!("{}", Value::Object(event));
        }
        Err(error) => {
            if worker::error_was_reported(&error) { std::process::exit(1); }
            let mut message = error.to_string();
            for name in ["POSLE_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "POSLE_SPEECH_API_KEY"] {
                if let Ok(secret) = std::env::var(name) { if !secret.is_empty() { message = message.replace(&secret, "[hidden]"); } }
            }
            let mut event = json!({"event":"error","message":message});
            if let Some(diagnostics) = posle_core::chatgpt::error_diagnostics(&error) {
                event["chatGPTDiagnostics"] = json!(diagnostics);
            }
            println!("{}", event);
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod voice_input_tests {
    use super::*;
    #[test]
    fn calendar_context_larger_than_old_stdin_limit_is_not_truncated() {
        let value = json!({"text":"Что у меня в календаре?", "calendar":{"events":[{"title":"Обсуждение".repeat(4000)}]}});
        let bytes = serde_json::to_vec(&value).unwrap();
        assert!(bytes.len() > 20_000 && bytes.len() < VOICE_INPUT_LIMIT);
        assert_eq!(read_voice_input(bytes.as_slice()).unwrap(), value);
    }
    #[test]
    fn oversized_or_invalid_input_fails_without_accepting_a_valid_prefix() {
        let mut bytes = br#"{"text":"question"}"#.to_vec();
        bytes.resize(VOICE_INPUT_LIMIT + 1, b' ');
        assert!(read_voice_input(bytes.as_slice()).unwrap_err().to_string().contains("слишком большой"));
        assert!(read_voice_input(&[0xffu8][..]).is_err());
    }
}

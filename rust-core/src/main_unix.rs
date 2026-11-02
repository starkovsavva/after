// Binary-only CPython entry point: selected before any Rust worker threads.
#[cfg(target_os = "macos")]
#[path = "platform/macos/python_host.rs"]
mod python_host;

use anyhow::{bail, Context, Result};
use clap::{Parser, ValueEnum};
use posle_core::{ai, media, models, search, storage, worker};
use serde_json::{json, Value};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, ValueEnum)]
enum Command { Prepare, Transcribe, Diarize, Finalize, InstallLocal, InstallRuntime, Summarize, Example, Review, Check, CheckCloud, Pull, DiscoverModels, DiscoverLocal, DiscoverGguf, ImportGguf, Search, List, Import, Update, NotesList, NoteSave, NoteDelete, ContextSave, TemplateSave, TemplateDelete, NoteAttach, AttachmentRemove, AttachmentText, AttachmentPath, NotesSearch, NotesTasks, NotesBrief, ExpandNotes, CardsImport, CardsImportPreview, VoicePlan, KnowledgeRebuild }

#[cfg(target_os = "linux")]
#[derive(Parser)]
struct PythonRuntimeInstallArgs {
    #[arg(long)] root: PathBuf,
    #[arg(long, required_unless_present = "archive", conflicts_with = "archive")] download: bool,
    #[arg(long)] archive: Option<PathBuf>,
    #[arg(long, value_parser = ["python", "linux-cpu"], default_value = "python")] profile: String,
    #[arg(long)] wheelhouse: Option<PathBuf>,
}

#[derive(Parser)]
#[command(version, about="After: ядро библиотеки и обработки встреч")]
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
        Command::KnowledgeRebuild => {
            let input = read_voice_input(io::stdin())?;
            Ok(json!({"knowledgeRebuild":posle_core::knowledge_rebuild_ai::generate(&args.root,&input)?}))
        }
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
    if std::env::args_os().nth(1).as_deref() == Some(std::ffi::OsStr::new("desktop-import-queue")) {
        let args: Vec<_> = std::env::args_os().skip(2).collect();
        if args.len() != 2 || args[0] != "--root" || posle_core::desktop_queue_service::run_stdio(Path::new(&args[1]), io::stdin().lock(), io::stdout().lock()).is_err() {
            std::process::exit(1);
        }
        return;
    }
    if std::env::args_os().nth(1).as_deref() == Some(std::ffi::OsStr::new("desktop-import-worker")) {
        let args: Vec<_> = std::env::args_os().skip(2).collect();
        if args.len() != 2 || args[0] != "--root" || posle_core::desktop_worker::run_stdio(Path::new(&args[1])).is_err() {
            std::process::exit(1);
        }
        return;
    }
    if std::env::args_os().nth(1).as_deref() == Some(std::ffi::OsStr::new("desktop-bridge")) {
        let args: Vec<_> = std::env::args_os().skip(2).collect();
        if args.len() != 2 || args[0] != "--root" {
            eprintln!("Usage: posle-engine desktop-bridge --root /absolute/library/path");
            std::process::exit(2);
        }
        if posle_core::desktop::run_stdio(Path::new(&args[1]), io::stdin().lock(), io::stdout().lock()).is_err() {
            std::process::exit(1);
        }
        return;
    }
    if std::env::args_os().nth(1).as_deref() == Some(std::ffi::OsStr::new("mcp-share")) {
        let args: Vec<_> = std::env::args_os().skip(2).collect();
        let result = if args.len() == 2 && args[0] == "--root" { posle_core::scoped_share::stdio::run(PathBuf::from(&args[1])) }
            else { Err(anyhow::anyhow!("Usage: After Engine mcp-share --root /absolute/library/path")) };
        if let Err(error) = result { eprintln!("{error}"); std::process::exit(1); }
        return;
    }
    if std::env::args_os().nth(1).as_deref() == Some(std::ffi::OsStr::new("mcp")) {
        let args: Vec<_> = std::env::args_os().skip(2).collect();
        let result = if (args.len() == 2 || args.len() == 3 && args[2] == "--shared-material-search") && args[0] == "--root" { posle_core::mcp::run_stdio(PathBuf::from(&args[1]), args.len() == 3) }
            else { Err(anyhow::anyhow!("Usage: posle-engine mcp --root /absolute/library/path [--shared-material-search]")) };
        if let Err(error) = result { eprintln!("{error}"); std::process::exit(1); }
        return;
    }
    if std::env::args_os().nth(1).as_deref() == Some(std::ffi::OsStr::new("--posle-speech-queue")) {
        let args: Vec<_> = std::env::args_os().skip(2).collect();
        let result = if args.len()==4 && args[0]=="--root" && args[2]=="--backend" {
            posle_core::desktop_speech_service::run_stdio(Path::new(&args[1]),Path::new(&args[3]),io::stdin(),io::stdout())
        } else {Err(anyhow::anyhow!("Usage: --posle-speech-queue --root /owned/root --backend /backend"))};
        if let Err(error)=result {eprintln!("{error:#}");std::process::exit(1);}
        return;
    }
    if std::env::args_os().nth(1).as_deref() == Some(std::ffi::OsStr::new("--posle-speech-job")) {
        let args: Vec<_> = std::env::args_os().skip(2).collect();
        let scope = if args.len()==4 && args[0]=="--root" && args[2]=="--backend" {
            match posle_core::speech_job::native_scope(Path::new(&args[1])) {
                Ok(scope)=>scope,Err(error)=>{eprintln!("{error:#}");std::process::exit(1);}
            }
        } else {None};
        let result = (|| -> Result<Value> {
            if args.len() != 4 || args[0] != "--root" || args[2] != "--backend" {
                bail!("Usage: --posle-speech-job --root /owned/root --backend /backend < request.json");
            }
            let raw = read_voice_input(io::stdin())?;
            if raw.get("inspect").and_then(Value::as_str).is_some() && raw.as_object().is_some_and(|v| v.len()==1) {
                return Ok(json!({"inputRevision":posle_core::speech_job::inspect(Path::new(&args[1]),raw["inspect"].as_str().unwrap())?}));
            }
            let work = serde_json::from_value(raw)?;
            Ok(json!({"receipt":posle_core::speech_job::execute(Path::new(&args[1]),Path::new(&args[3]),&work)?}))
        })();
        let failed = match result {
            Ok(value) => {println!("{}",json!({"event":"done","speechJob":value}));false},
            Err(error) => {eprintln!("{error:#}");true}
        };
        let _=io::stdout().flush(); let _=io::stderr().flush();
        drop(scope);
        if failed {std::process::exit(1);}
        return;
    }
    if std::env::args_os().nth(1).as_deref()
        == Some(std::ffi::OsStr::new("--posle-install-asr-model"))
    {
        let args: Vec<_> = std::env::args_os().skip(2).collect();
        let result = if args.len() == 3 && args[0] == "--root" && args[2] == "--download" {
            posle_core::asr_model::install(Path::new(&args[1]), None)
        } else if args.len() == 4 && args[0] == "--root" && args[2] == "--archive" {
            posle_core::asr_model::install(Path::new(&args[1]), Some(Path::new(&args[3])))
        } else {
            Err(anyhow::anyhow!(
                "Usage: --posle-install-asr-model --root /owned/root (--download | --archive /model.tar.bz2)"
            ))
        };
        match result {
            Ok(model) => println!("{}", serde_json::to_string(&model).unwrap()),
            Err(error) => {
                eprintln!("{error:#}");
                std::process::exit(1);
            }
        }
        return;
    }
    #[cfg(target_os = "linux")]
    if std::env::args_os().nth(1).as_deref() == Some(std::ffi::OsStr::new(posle_core::python_runtime::CHECK_MODE)) {
        let args: Vec<_> = std::env::args_os().skip(2).collect();
        let result = if args.len() == 2 && args[0] == "--root" {
            posle_core::python_runtime::validate_active(Path::new(&args[1]))
        } else { Err(anyhow::anyhow!("Usage: --posle-check-python-runtime --root /absolute/private/root")) };
        match result {
            Ok(runtime) => println!("{}", serde_json::to_string(runtime.installation()).unwrap()),
            Err(error) => { eprintln!("{error:#}"); std::process::exit(1); }
        }
        return;
    }
    #[cfg(target_os = "linux")]
    if std::env::args_os().nth(1).as_deref() == Some(std::ffi::OsStr::new(posle_core::python_runtime::INSTALL_MODE)) {
        let result = PythonRuntimeInstallArgs::try_parse_from(std::iter::once(std::ffi::OsString::from("python-runtime-install")).chain(std::env::args_os().skip(2)))
            .map_err(|error| anyhow::anyhow!(error.to_string()))
            .and_then(|args| {
                if args.profile == "linux-cpu" {
                    posle_core::python_runtime::install_cpu(&args.root,args.archive.as_deref(),args.wheelhouse.as_deref())
                } else {
                    if args.wheelhouse.is_some() { bail!("--wheelhouse requires --profile linux-cpu"); }
                    posle_core::python_runtime::install(&args.root,args.archive.as_deref())
                }
            });
        match result {
            Ok(installed) => println!("{}", serde_json::to_string(&installed).unwrap()),
            Err(error) => { eprintln!("{error:#}"); std::process::exit(1); }
        }
        return;
    }
    #[cfg(any(target_os = "macos", target_os = "linux"))]
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
    #[cfg(target_os = "macos")]
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

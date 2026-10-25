use anyhow::{bail, Context, Result};
use clap::{Parser, ValueEnum};
use posle_core::{ai, storage, worker};
use serde_json::{json, Value};
use std::io::{self, Read};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, ValueEnum)]
enum Command { Prepare, Transcribe, Finalize, InstallLocal, InstallRuntime, Summarize, Example, Review, Check, Pull, List, Import, Update }

#[derive(Parser)]
#[command(version, about="После: ядро библиотеки и обработки встреч")]
struct Args {
    #[arg(value_enum)] command: Command,
    #[arg(long)] root: PathBuf,
    #[arg(long)] backend: Option<PathBuf>,
    #[arg(long)] meeting: Option<PathBuf>,
    #[arg(long, default_value="")] card: String,
    #[arg(long, default_value_t=3)] rating: u8,
    #[arg(long, default_value_t=0)] speakers: u32,
    #[arg(long)] no_diarization: bool,
}

fn backend_path(override_path: Option<&Path>) -> Result<PathBuf> {
    if let Some(path) = override_path { return Ok(path.to_owned()); }
    let executable = std::env::current_exe()?;
    let bundled = executable.parent().and_then(Path::parent).context("Нет папки приложения")?.join("Resources/backend");
    if bundled.join("engine.py").exists() { return Ok(bundled); }
    Ok(Path::new(env!("CARGO_MANIFEST_DIR")).join("../backend"))
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
        Command::Prepare | Command::Transcribe | Command::Finalize | Command::InstallLocal => {
            let command = match args.command { Command::Prepare=>"prepare", Command::Transcribe=>"transcribe", Command::Finalize=>"finalize", _=>"install-local" };
            worker::run_worker(&args.root, &backend, command, directory.as_deref(), args.speakers, !args.no_diarization)?;
            Ok(json!({}))
        }
        Command::InstallRuntime => { worker::install_runtime(&args.root, &backend)?; Ok(json!({})) }
        Command::Summarize => { ai::summarize(&args.root, required()?)?; Ok(json!({})) }
        Command::Example => { ai::example(&args.root, required()?, &args.card)?; Ok(json!({})) }
        Command::Review => {
            let id = required()?.file_name().and_then(|s|s.to_str()).context("Нет ID")?;
            storage::review(&args.root, id, &args.card, args.rating)
        }
        Command::Check => ai::check(),
        Command::Pull => { ai::pull(&args.root)?; Ok(json!({})) }
        Command::List => Ok(json!({"meetings":storage::list_meetings(&args.root)?})),
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
    // Rust owns domain logic; the Python child is limited to MLX/ONNX/media.
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
            for name in ["POSLE_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY"] {
                if let Ok(secret) = std::env::var(name) { if !secret.is_empty() { message = message.replace(&secret, "[hidden]"); } }
            }
            println!("{}", json!({"event":"error","message":message}));
            std::process::exit(1);
        }
    }
}

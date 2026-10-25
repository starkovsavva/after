//! Native entry point for the isolated speech worker. The Mach-O helper stays
//! the process executable while CPython and its native MLX/ONNX modules run
//! inside it. This is not argv/process-title impersonation of a Python child.

use anyhow::{bail, Context, Result};
use std::ffi::{CString, OsStr, OsString};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

pub const INTERNAL_MODE: &str = "--posle-python-host";

#[derive(Debug)]
struct Runtime {
    interpreter: PathBuf,
    library: PathBuf,
}

fn runtime(interpreter: &Path) -> Result<Runtime> {
    if !interpreter.is_absolute() {
        bail!("Путь движка распознавания должен быть абсолютным.");
    }
    let venv = interpreter.parent().filter(|path| path.file_name() == Some(OsStr::new("bin")))
        .and_then(Path::parent)
        .context("Некорректная папка движка распознавания.")?;
    if !venv.join("pyvenv.cfg").is_file() {
        bail!("Сначала установите движок распознавания в настройках.");
    }
    // Keep the original venv executable as CPython argv[0], but derive its
    // library from the real interpreter. Relocated standalone distributions
    // can retain an obsolete sysconfig LIBDIR; it must never select a library.
    let real = std::fs::canonicalize(interpreter)
        .context("Сначала установите движок распознавания в настройках.")?;
    if !real.is_file() || real.file_name() != Some(OsStr::new("python3.12")) {
        bail!("Нужен совместимый движок распознавания Python 3.12. Переустановите его в настройках.");
    }
    let base = real.parent().filter(|path| path.file_name() == Some(OsStr::new("bin")))
        .and_then(Path::parent)
        .context("Некорректная папка движка распознавания.")?;
    let library = base.join("lib/libpython3.12.dylib");
    if !library.is_file() {
        bail!("Движок распознавания установлен не полностью. Переустановите его в настройках.");
    }
    Ok(Runtime { interpreter: interpreter.to_owned(), library })
}

fn python_arguments(runtime: &Runtime, arguments: &[OsString]) -> Result<Vec<CString>> {
    let Some(script) = arguments.first().map(Path::new) else {
        bail!("Не выбран модуль распознавания.");
    };
    if !script.is_absolute() || script.file_name() != Some(OsStr::new("engine.py")) || !script.is_file() {
        bail!("В приложении отсутствует модуль распознавания. Повторите установку приложения.");
    }
    // -E/-s ignore ambient Python configuration and the user's site-packages;
    // the selected venv's packages remain available. -B is explicit because
    // -E deliberately ignores PYTHONDONTWRITEBYTECODE. -u preserves JSONL.
    std::iter::once(runtime.interpreter.as_os_str())
        .chain([OsStr::new("-B"), OsStr::new("-u"), OsStr::new("-E"), OsStr::new("-s")])
        .chain(arguments.iter().map(OsString::as_os_str))
        .map(|argument| CString::new(argument.as_bytes()).context("Некорректный аргумент модуля распознавания."))
        .collect()
}

/// Called only by the binary's earliest main branch, before any Rust threads
/// exist. The worker adapter is still responsible for process-group lifetime,
/// cancellation, progress filtering and removing provider secrets.
pub fn run(arguments: Vec<OsString>) -> Result<i32> {
    let Some(interpreter) = arguments.first().map(Path::new) else {
        bail!("Не выбран движок распознавания.");
    };
    let runtime = runtime(interpreter)?;
    let strings = python_arguments(&runtime, &arguments[1..])?;
    let argc = libc::c_int::try_from(strings.len()).context("Слишком много аргументов обработки.")?;
    let library = CString::new(runtime.library.as_os_str().as_bytes())
        .context("Некорректный путь движка распознавания.")?;
    // __PYVENV_LAUNCHER__ can override executable/venv detection even with -E
    // on macOS. Clear all executable/path overrides before Python initializes.
    for name in ["__PYVENV_LAUNCHER__", "PYTHONEXECUTABLE", "PYTHONHOME", "PYTHONPATH"] {
        std::env::remove_var(name);
    }
    // RTLD_GLOBAL exposes the CPython ABI to subsequently imported native
    // extensions (NumPy, MLX, ONNX). Keep the handle alive for process lifetime:
    // native extensions may retain Python symbols after Py_BytesMain returns.
    let handle = unsafe { libc::dlopen(library.as_ptr(), libc::RTLD_NOW | libc::RTLD_GLOBAL) };
    if handle.is_null() {
        bail!("Не удалось загрузить движок распознавания. Переустановите его в настройках.");
    }
    let symbol = unsafe { libc::dlsym(handle, c"Py_BytesMain".as_ptr()) };
    if symbol.is_null() {
        bail!("Движок распознавания несовместим. Переустановите его в настройках.");
    }
    type PythonMain = unsafe extern "C" fn(libc::c_int, *mut *mut libc::c_char) -> libc::c_int;
    // Py_BytesMain is CPython's public stable-ABI entry point. CStrings and
    // pointer storage outlive the call; CPython may reorder argv pointers.
    let python_main: PythonMain = unsafe { std::mem::transmute(symbol) };
    let mut argv: Vec<_> = strings.iter().map(|value| value.as_ptr().cast_mut()).collect();
    argv.push(std::ptr::null_mut());
    Ok(unsafe { python_main(argc, argv.as_mut_ptr()) })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::symlink;

    fn fixture() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let temp = tempfile::tempdir().unwrap();
        let base = temp.path().join("standalone");
        fs::create_dir_all(base.join("bin")).unwrap();
        fs::create_dir_all(base.join("lib")).unwrap();
        fs::write(base.join("bin/python3.12"), b"fixture").unwrap();
        fs::write(base.join("lib/libpython3.12.dylib"), b"fixture").unwrap();
        let venv = temp.path().join("Данные с пробелами/venv");
        fs::create_dir_all(venv.join("bin")).unwrap();
        fs::write(venv.join("pyvenv.cfg"), b"home = /obsolete/path\n").unwrap();
        symlink(base.join("bin/python3.12"), venv.join("bin/python")).unwrap();
        let script = temp.path().join("Модуль с пробелами/engine.py");
        fs::create_dir_all(script.parent().unwrap()).unwrap();
        fs::write(&script, "pass\n").unwrap();
        (temp, venv.join("bin/python"), script)
    }

    #[test]
    fn keeps_venv_program_name_and_resolves_real_library_after_relocation() {
        let (_temp, interpreter, script) = fixture();
        let selected = runtime(&interpreter).unwrap();
        assert_eq!(selected.interpreter, interpreter);
        assert!(selected.library.ends_with("standalone/lib/libpython3.12.dylib"));
        assert!(!selected.library.to_string_lossy().contains("obsolete"));
        let extra = OsString::from("моя встреча; $(literal)");
        let args = python_arguments(&selected, &[script.clone().into_os_string(), extra.clone()]).unwrap();
        let expected = vec![interpreter.into_os_string(), "-B".into(), "-u".into(), "-E".into(), "-s".into(), script.into_os_string(), extra];
        assert_eq!(args.iter().map(|value| value.as_bytes()).collect::<Vec<_>>(), expected.iter().map(|value| value.as_bytes()).collect::<Vec<_>>());
    }

    #[test]
    fn rejects_incomplete_runtime_and_unexpected_script_without_loading_code() {
        let (_temp, interpreter, script) = fixture();
        let selected = runtime(&interpreter).unwrap();
        assert!(runtime(Path::new("relative/python")).is_err());
        assert!(python_arguments(&selected, &["relative/engine.py".into()]).is_err());
        assert!(python_arguments(&selected, &[script.with_file_name("other.py").into_os_string()]).is_err());
        fs::remove_file(&selected.library).unwrap();
        assert!(runtime(&interpreter).unwrap_err().to_string().contains("не полностью"));
    }
}

//! Native entry point for the isolated speech worker. The Mach-O helper stays
//! the process executable while CPython and its native MLX/ONNX modules run
//! inside it. This is not argv/process-title impersonation of a Python child.

use anyhow::{bail, Context, Result};
use std::ffi::{CString, OsStr, OsString};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

pub const INTERNAL_MODE: &str = "--posle-python-host";

fn python_arguments(interpreter: &Path, arguments: &[OsString]) -> Result<Vec<CString>> {
    let Some(script) = arguments.first().map(Path::new) else {
        bail!("Не выбран модуль распознавания.");
    };
    if !script.is_absolute() || script.file_name() != Some(OsStr::new("engine.py")) || !script.is_file() {
        bail!("В приложении отсутствует модуль распознавания. Повторите установку приложения.");
    }
    // -E/-s ignore ambient Python configuration and the user's site-packages;
    // the selected venv's packages remain available. -B is explicit because
    // -E deliberately ignores PYTHONDONTWRITEBYTECODE. -u preserves JSONL.
    std::iter::once(interpreter.as_os_str())
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
    let runtime = posle_core::python_runtime::validate_interpreter(interpreter)?;
    let strings = python_arguments(&runtime.interpreter, &arguments[1..])?;
    let argc = libc::c_int::try_from(strings.len()).context("Слишком много аргументов обработки.")?;
    let library = runtime.loader_path()?;
    // __PYVENV_LAUNCHER__ can override executable/venv detection even with -E
    // on macOS. Clear all executable/path overrides before Python initializes.
    for name in ["__PYVENV_LAUNCHER__", "PYTHONEXECUTABLE", "PYTHONHOME", "PYTHONPATH"] {
        std::env::remove_var(name);
    }
    // RTLD_GLOBAL exposes the CPython ABI to subsequently imported native
    // extensions (NumPy, MLX, ONNX). Keep the handle alive for process lifetime:
    // native extensions may retain Python symbols after Py_BytesMain returns.
    // Recheck immediately before dyld consumes the held descriptor.
    runtime.recheck()?;
    let handle = unsafe { libc::dlopen(library.as_ptr(), libc::RTLD_NOW | libc::RTLD_GLOBAL) };
    if handle.is_null() {
        bail!("Не удалось загрузить движок распознавания. Переустановите его в настройках.");
    }
    let symbol = unsafe { libc::dlsym(handle, c"Py_BytesMain".as_ptr()) };
    if symbol.is_null() {
        bail!("Движок распознавания несовместим. Переустановите его в настройках.");
    }
    unsafe { runtime.require_image(symbol)?; }
    let version = unsafe { libc::dlsym(handle, c"Py_GetVersion".as_ptr()) };
    if version.is_null() { bail!("Движок распознавания несовместим. Переустановите компоненты."); }
    type Version = unsafe extern "C" fn() -> *const libc::c_char;
    let get_version: Version = unsafe { std::mem::transmute(version) };
    let version = unsafe { get_version() };
    if version.is_null() { bail!("Движок распознавания несовместим. Переустановите компоненты."); }
    runtime.require_version(unsafe { std::ffi::CStr::from_ptr(version) }.to_bytes())?;
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
    use std::path::PathBuf;
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
    fn keeps_venv_program_name_without_trusting_arbitrary_runtime_files() {
        let (_temp, interpreter, script) = fixture();
        assert!(posle_core::python_runtime::validate_interpreter(&interpreter).is_err());
        let extra = OsString::from("моя встреча; $(literal)");
        let args = python_arguments(&interpreter, &[script.clone().into_os_string(), extra.clone()]).unwrap();
        let expected = vec![interpreter.into_os_string(), "-B".into(), "-u".into(), "-E".into(), "-s".into(), script.into_os_string(), extra];
        assert_eq!(args.iter().map(|value| value.as_bytes()).collect::<Vec<_>>(), expected.iter().map(|value| value.as_bytes()).collect::<Vec<_>>());
    }

    #[test]
    fn rejects_incomplete_runtime_and_unexpected_script_without_loading_code() {
        let (_temp, interpreter, script) = fixture();
        assert!(posle_core::python_runtime::validate_interpreter(&interpreter).is_err());
        assert!(posle_core::python_runtime::validate_interpreter(Path::new("relative/python")).is_err());
        assert!(python_arguments(&interpreter, &["relative/engine.py".into()]).is_err());
        assert!(python_arguments(&interpreter, &[script.with_file_name("other.py").into_os_string()]).is_err());
        fs::remove_file(fs::canonicalize(&interpreter).unwrap().parent().unwrap().parent().unwrap().join("lib/libpython3.12.dylib")).unwrap();
        assert!(posle_core::python_runtime::validate_interpreter(&interpreter).is_err());
    }
}

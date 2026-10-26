//! Persistent in-process CPython host. The main app's PID owns MLX/ONNX work.
//! Python is initialized once on one dedicated thread and never finalized or
//! reinitialized. No Python environment, signal handler or stdout is replaced.
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, OnceLock};

static CANCELLED: AtomicBool = AtomicBool::new(false);
static RUNNING: AtomicBool = AtomicBool::new(false);
static HOST: OnceLock<std::result::Result<mpsc::Sender<Job>, String>> = OnceLock::new();
type EventCallback = unsafe extern "C" fn(*const c_char, *mut c_void);
struct Job { input: Value, callback: Option<EventCallback>, context: usize, reply: mpsc::SyncSender<Result<Value>> }

#[repr(C)]
#[derive(Clone, Copy)]
struct PyStatus { kind: c_int, function: *const c_char, message: *const c_char, exitcode: c_int }
#[repr(C)]
struct PyPreConfig312 {
    config_init:c_int, parse_argv:c_int, isolated:c_int, use_environment:c_int,
    configure_locale:c_int, coerce_c_locale:c_int, coerce_c_locale_warn:c_int,
    utf8_mode:c_int, dev_mode:c_int, allocator:c_int,
}
#[repr(C)]
struct PyWideStringList { length: isize, items: *mut *mut libc::wchar_t }
/// Public PyConfig layout for the explicitly pinned CPython 3.12 runtime on
/// macOS (cpython/initconfig.h). Refuse every other minor version before use.
/// https://docs.python.org/3.12/c-api/init_config.html
#[repr(C)]
struct PyConfig312 {
    config_init:c_int, isolated:c_int, use_environment:c_int, dev_mode:c_int,
    install_signal_handlers:c_int, use_hash_seed:c_int, hash_seed:libc::c_ulong,
    faulthandler:c_int, tracemalloc:c_int, perf_profiling:c_int, import_time:c_int,
    code_debug_ranges:c_int, show_ref_count:c_int, dump_refs:c_int,
    dump_refs_file:*mut libc::wchar_t, malloc_stats:c_int,
    filesystem_encoding:*mut libc::wchar_t, filesystem_errors:*mut libc::wchar_t,
    pycache_prefix:*mut libc::wchar_t, parse_argv:c_int,
    orig_argv:PyWideStringList, argv:PyWideStringList, xoptions:PyWideStringList, warnoptions:PyWideStringList,
    site_import:c_int, bytes_warning:c_int, warn_default_encoding:c_int, inspect:c_int,
    interactive:c_int, optimization_level:c_int, parser_debug:c_int, write_bytecode:c_int,
    verbose:c_int, quiet:c_int, user_site_directory:c_int, configure_c_stdio:c_int,
    buffered_stdio:c_int, stdio_encoding:*mut libc::wchar_t, stdio_errors:*mut libc::wchar_t,
    check_hash_pycs_mode:*mut libc::wchar_t, use_frozen_modules:c_int, safe_path:c_int,
    int_max_str_digits:c_int, pathconfig_warnings:c_int, program_name:*mut libc::wchar_t,
    pythonpath_env:*mut libc::wchar_t, home:*mut libc::wchar_t, platlibdir:*mut libc::wchar_t,
    module_search_paths_set:c_int, module_search_paths:PyWideStringList,
    stdlib_dir:*mut libc::wchar_t, executable:*mut libc::wchar_t, base_executable:*mut libc::wchar_t,
    prefix:*mut libc::wchar_t, base_prefix:*mut libc::wchar_t, exec_prefix:*mut libc::wchar_t, base_exec_prefix:*mut libc::wchar_t,
    skip_source_first_line:c_int, run_command:*mut libc::wchar_t, run_module:*mut libc::wchar_t, run_filename:*mut libc::wchar_t,
    install_importlib:c_int, init_main:c_int, is_python_build:c_int,
}
struct Api {
    _handle:*mut c_void,
    preconfig_init:unsafe extern "C" fn(*mut PyPreConfig312),
    preinitialize:unsafe extern "C" fn(*const PyPreConfig312)->PyStatus,
    config_init:unsafe extern "C" fn(*mut PyConfig312),
    config_clear:unsafe extern "C" fn(*mut PyConfig312),
    config_string:unsafe extern "C" fn(*mut PyConfig312,*mut *mut libc::wchar_t,*const c_char)->PyStatus,
    list_append:unsafe extern "C" fn(*mut PyWideStringList,*const libc::wchar_t)->PyStatus,
    initialize:unsafe extern "C" fn(*const PyConfig312)->PyStatus,
    initialized:unsafe extern "C" fn()->c_int,
    get_version:unsafe extern "C" fn()->*const c_char,
    save_thread:unsafe extern "C" fn()->*mut c_void,
    gil_ensure:unsafe extern "C" fn()->c_int,
    gil_release:unsafe extern "C" fn(c_int),
    import:unsafe extern "C" fn(*const c_char)->*mut c_void,
    attr:unsafe extern "C" fn(*mut c_void,*const c_char)->*mut c_void,
    unicode:unsafe extern "C" fn(*const c_char,isize)->*mut c_void,
    call:unsafe extern "C" fn(*mut c_void,*mut c_void)->*mut c_void,
    tuple_new:unsafe extern "C" fn(isize)->*mut c_void,
    tuple_set:unsafe extern "C" fn(*mut c_void,isize,*mut c_void)->c_int,
    utf8:unsafe extern "C" fn(*mut c_void,*mut isize)->*const c_char,
    decref:unsafe extern "C" fn(*mut c_void),
    clear_error:unsafe extern "C" fn(),
}
unsafe fn symbol<T:Copy>(handle:*mut c_void,name:&CStr)->Result<T> {
    let value=libc::dlsym(handle,name.as_ptr());
    if value.is_null() {bail!("Движок распознавания несовместим. Переустановите компоненты.");}
    Ok(std::mem::transmute_copy(&value))
}
impl Api {
    unsafe fn load(runtime:&crate::python_runtime::VerifiedRuntime)->Result<Self> {
        // CPython 3.12 getpath.c unconditionally consumes this macOS launcher
        // variable even in isolated mode. Refuse that unusual parent instead
        // of changing the running Swift app's environment or restoring it racily.
        // https://github.com/python/cpython/blob/v3.12.12/Modules/getpath.c
        if std::env::var_os("__PYVENV_LAUNCHER__").is_some() {
            bail!("Среда запуска содержит служебные настройки Python. Закройте «После» и откройте его из Finder.");
        }
        let path=runtime.loader_path()?;
        let handle=libc::dlopen(path.as_ptr(),libc::RTLD_NOW|libc::RTLD_GLOBAL);
        if handle.is_null() {bail!("Не удалось загрузить движок распознавания. Переустановите компоненты.");}
        // Deliberately never dlclose: native extensions retain CPython symbols.
        let api=Self{_handle:handle,
            preconfig_init:symbol(handle,c"PyPreConfig_InitIsolatedConfig")?,preinitialize:symbol(handle,c"Py_PreInitialize")?,
            config_init:symbol(handle,c"PyConfig_InitIsolatedConfig")?,config_clear:symbol(handle,c"PyConfig_Clear")?,
            config_string:symbol(handle,c"PyConfig_SetBytesString")?,list_append:symbol(handle,c"PyWideStringList_Append")?,
            initialize:symbol(handle,c"Py_InitializeFromConfig")?,initialized:symbol(handle,c"Py_IsInitialized")?,get_version:symbol(handle,c"Py_GetVersion")?,
            save_thread:symbol(handle,c"PyEval_SaveThread")?,gil_ensure:symbol(handle,c"PyGILState_Ensure")?,gil_release:symbol(handle,c"PyGILState_Release")?,
            import:symbol(handle,c"PyImport_ImportModule")?,attr:symbol(handle,c"PyObject_GetAttrString")?,unicode:symbol(handle,c"PyUnicode_FromStringAndSize")?,
            call:symbol(handle,c"PyObject_CallObject")?,tuple_new:symbol(handle,c"PyTuple_New")?,tuple_set:symbol(handle,c"PyTuple_SetItem")?,
            utf8:symbol(handle,c"PyUnicode_AsUTF8AndSize")?,decref:symbol(handle,c"Py_DecRef")?,clear_error:symbol(handle,c"PyErr_Clear")?};
        runtime.require_image(api.get_version as *const libc::c_void)?;
        runtime.require_version(CStr::from_ptr((api.get_version)()).to_bytes())?;
        if (api.initialized)()!=0 {bail!("В приложении уже работает другой Python-движок. Перезапустите «После».");}
        Ok(api)
    }
    unsafe fn initialize(&self,runtime:&Runtime)->Result<()> {
        // Finder-launched native apps commonly retain C locale. ML packages
        // contain UTF-8 resource files; enable Python UTF-8 mode without changing
        // LC_CTYPE or mutating PYTHONUTF8 in the running Swift app's environment.
        let mut preconfig:PyPreConfig312=std::mem::zeroed(); (self.preconfig_init)(&mut preconfig);
        preconfig.utf8_mode=1; preconfig.configure_locale=0;
        status((self.preinitialize)(&preconfig))?;
        let mut config:PyConfig312=std::mem::zeroed(); (self.config_init)(&mut config);
        let configured=(||->Result<()> {
            config.install_signal_handlers=0; config.site_import=0; config.write_bytecode=0;
            config.configure_c_stdio=0; config.pathconfig_warnings=0; config.parse_argv=0;
            for (field,path) in [
                (std::ptr::addr_of_mut!(config.home),runtime.base.clone()),
                (std::ptr::addr_of_mut!(config.program_name),runtime.interpreter.clone()),
                (std::ptr::addr_of_mut!(config.executable),runtime.interpreter.clone()),
                (std::ptr::addr_of_mut!(config.base_executable),runtime.real.clone()),
                (std::ptr::addr_of_mut!(config.prefix),runtime.venv.clone()),
                (std::ptr::addr_of_mut!(config.exec_prefix),runtime.venv.clone()),
                (std::ptr::addr_of_mut!(config.base_prefix),runtime.base.clone()),
                (std::ptr::addr_of_mut!(config.base_exec_prefix),runtime.base.clone()),
            ] {
                let text=CString::new(path.as_os_str().as_bytes())?;
                status((self.config_string)(&mut config,field,text.as_ptr()))?;
            }
            config.module_search_paths_set=1;
            for path in [runtime.backend.clone(),runtime.base.join("lib/python312.zip"),runtime.base.join("lib/python3.12"),runtime.base.join("lib/python3.12/lib-dynload"),runtime.venv.join("lib/python3.12/site-packages")] {
                let mut wide:Vec<libc::wchar_t>=path.to_str().context("Некорректный путь компонентов")?.chars().map(|c|c as libc::wchar_t).collect(); wide.push(0);
                status((self.list_append)(&mut config.module_search_paths,wide.as_ptr()))?;
            }
            status((self.initialize)(&config))
        })();
        (self.config_clear)(&mut config);
        configured?;
        // Future calls always reacquire the GIL on this exact persistent thread.
        (self.save_thread)();
        Ok(())
    }
    unsafe fn invoke(&self,input:&Value)->Result<Value> {
        let gil=(self.gil_ensure)();
        let result=(||->Result<Value> {
            let module=(self.import)(c"embedded_bridge".as_ptr());
            if module.is_null() {(self.clear_error)();bail!("Не удалось загрузить модуль распознавания. Переустановите приложение.");}
            let function=(self.attr)(module,c"run".as_ptr()); (self.decref)(module);
            if function.is_null() {(self.clear_error)();bail!("Версия модуля распознавания не соответствует приложению.");}
            let text=input.to_string(); let value=(self.unicode)(text.as_ptr().cast(),text.len() as isize);
            let args=(self.tuple_new)(1);
            if value.is_null() || args.is_null() {
                if !value.is_null() {(self.decref)(value);} if !args.is_null() {(self.decref)(args);}
                (self.decref)(function);(self.clear_error)();bail!("Не хватает памяти для распознавания.");
            }
            if (self.tuple_set)(args,0,value)!=0 {(self.decref)(args);(self.decref)(function);(self.clear_error)();bail!("Не удалось передать параметры распознавания.");}
            let output=(self.call)(function,args); (self.decref)(args); (self.decref)(function);
            if output.is_null() {(self.clear_error)();bail!("Модуль распознавания не завершил запрос. Исходная запись сохранена.");}
            let mut length=0; let pointer=(self.utf8)(output,&mut length);
            let result=if pointer.is_null() || length<0 || length>4*1024*1024 {Err(anyhow::anyhow!("Некорректный ответ модуля распознавания."))}
                else {serde_json::from_slice(std::slice::from_raw_parts(pointer.cast::<u8>(),length as usize)).context("Некорректный ответ модуля распознавания.")};
            (self.decref)(output);(self.clear_error)(); result
        })();
        (self.gil_release)(gil);result
    }
}
fn status(value:PyStatus)->Result<()> {
    if value.kind!=0 {bail!("Не удалось подготовить встроенное распознавание. Переустановите компоненты и перезапустите приложение.");} Ok(())
}
struct Runtime { interpreter:PathBuf, real:PathBuf, base:PathBuf, venv:PathBuf, backend:PathBuf, verified:crate::python_runtime::VerifiedRuntime }
impl PartialEq for Runtime {
    fn eq(&self, other:&Self)->bool { self.interpreter==other.interpreter && self.real==other.real && self.base==other.base && self.venv==other.venv && self.backend==other.backend }
}
fn runtime(input:&Value)->Result<Runtime> {
    let interpreter=PathBuf::from(input["interpreter"].as_str().context("Не выбраны компоненты распознавания")?);
    let backend=PathBuf::from(input["backend"].as_str().context("В приложении отсутствует модуль распознавания")?);
    let root=Path::new(input["root"].as_str().context("Не выбрана папка приложения")?);
    if !backend.is_absolute() || !backend.join("embedded_bridge.py").is_file() {bail!("В приложении отсутствует модуль распознавания.");}
    let verified=crate::python_runtime::validate(root,&interpreter)?;
    Ok(Runtime { interpreter:verified.interpreter.clone(), real:verified.real.clone(), base:verified.base.clone(), venv:verified.venv.clone(), backend, verified })
}
/// Reject unsupported commands and unowned dictation paths before loading Python.
fn validate_request(input: &Value) -> Result<()> {
    let command = input["command"].as_str().context("Не указана команда распознавания")?;
    if !["transcribe", "diarize", "finalize", "probe", "dictate"].contains(&command) {
        bail!("Эта команда не поддерживается встроенным распознаванием.");
    }
    if command != "dictate" { return Ok(()); }
    let root = Path::new(input["root"].as_str().context("Не выбрана папка приложения")?);
    let audio = Path::new(input["audio"].as_str().context("Не выбрана запись голосового поручения")?);
    let session = audio.parent().context("Некорректная запись поручения")?;
    if !root.is_absolute() || !audio.is_absolute()
        || root.components().chain(audio.components()).any(|part|matches!(part, std::path::Component::ParentDir))
        || session.parent() != Some(root.join("voice-inputs").as_path())
        || session.file_name().and_then(|name|name.to_str()).and_then(|name|uuid::Uuid::parse_str(name).ok()).is_none()
    { bail!("Голосовое поручение должно находиться в собственной папке приложения."); }
    if let Some(key) = input.get("apiKey") {
        let key = key.as_str().context("Некорректный ключ распознавания")?;
        if key.len() > 16_000 || key.contains(['\r', '\n']) { bail!("Некорректный ключ распознавания."); }
    }
    Ok(())
}
unsafe extern "C" fn cancellation()->c_int {i32::from(CANCELLED.load(Ordering::Acquire))}
fn host()->Result<&'static mpsc::Sender<Job>> {
    match HOST.get_or_init(|| {
        let (sender,receiver)=mpsc::channel::<Job>();
        std::thread::Builder::new().name("После · Распознавание".into()).spawn(move|| {
            let mut selected:Option<(Runtime,Api)>=None;
            for mut job in receiver {
                let result=(||->Result<Value> {
                    let runtime=runtime(&job.input)?;
                    if selected.as_ref().is_some_and(|(old,_)|old!=&runtime) {bail!("Компоненты распознавания изменились. Перезапустите «После».");}
                    if selected.is_none() {
                        let api=unsafe{Api::load(&runtime.verified)?};
                        unsafe{api.initialize(&runtime)?;}
                        selected=Some((runtime,api));
                    }
                    job.input["eventCallback"]=json!(job.callback.map(|callback|callback as usize).unwrap_or(0));
                    job.input["eventContext"]=json!(job.context);
                    job.input["cancelCallback"]=json!(cancellation as *const () as usize);
                    unsafe{selected.as_ref().unwrap().1.invoke(&job.input)}
                })();
                let _=job.reply.send(result);
            }
        }).map_err(|_|"Не удалось запустить встроенное распознавание.".to_owned())?;
        Ok(sender)
    }) {
        Ok(sender)=>Ok(sender),Err(message)=>bail!("{message}"),
    }
}

#[no_mangle]
pub extern "C" fn posle_speech_set_cancelled(value:c_int) {CANCELLED.store(value!=0,Ordering::Release);}

/// Blocking C ABI; call only from a background queue. The callback is invoked
/// on the persistent Python thread, never on the UI thread. Free via posle_free_string.
#[no_mangle]
pub unsafe extern "C" fn posle_speech_run(input:*const c_char,callback:Option<EventCallback>,context:*mut c_void)->*mut c_char {
    let result=std::panic::catch_unwind(||->Result<Value> {
        if RUNNING.compare_exchange(false,true,Ordering::AcqRel,Ordering::Acquire).is_err() {bail!("Распознавание уже выполняется.");}
        struct Guard; impl Drop for Guard {fn drop(&mut self){RUNNING.store(false,Ordering::Release);}} let _guard=Guard;
        if input.is_null() {bail!("Пустой запрос распознавания.");}
        let input=CStr::from_ptr(input).to_str().context("Ожидается UTF-8")?;
        if input.len()>100_000 {bail!("Слишком большой запрос распознавания.");}
        let input: Value = serde_json::from_str(input)?;
        validate_request(&input)?;
        let (reply,receiver)=mpsc::sync_channel(1);
        host()?.send(Job{input,callback,context:context as usize,reply}).map_err(|_|anyhow::anyhow!("Перезапустите приложение для распознавания."))?;
        receiver.recv().map_err(|_|anyhow::anyhow!("Распознавание прервалось. Исходная запись сохранена."))?
    });
    let envelope=match result {Ok(Ok(value))=>value,Ok(Err(error))=>json!({"ok":false,"error":error.to_string()}),Err(_)=>json!({"ok":false,"error":"Не удалось завершить распознавание. Исходная запись сохранена."})};
    CString::new(envelope.to_string()).expect("JSON escapes NUL").into_raw()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn matches_cpython312_darwin_public_config_layout() {
        assert_eq!(std::mem::size_of::<PyStatus>(),32);
        assert_eq!(std::mem::size_of::<PyPreConfig312>(),40);
        assert_eq!(std::mem::offset_of!(PyPreConfig312,utf8_mode),28);
        assert_eq!(std::mem::size_of::<PyConfig312>(),432);
        assert_eq!(std::mem::offset_of!(PyConfig312,program_name),272);
        assert_eq!(std::mem::offset_of!(PyConfig312,module_search_paths),312);
    }
    #[test]
    fn dictation_paths_are_owned_and_bounded_before_loading_python() {
        let mut input = json!({"root":"/private/tmp/posle-fixture", "command":"dictate", "audio":"/private/tmp/posle-fixture/voice-inputs/34ae2e5f-ac02-44ca-8f06-c1aaa66b5974/input.m4a"});
        assert!(validate_request(&input).is_ok());
        for path in ["/private/tmp/outside.wav", "/private/tmp/posle-fixture/voice-inputs/not-a-session/input.m4a", "/private/tmp/posle-fixture/voice-inputs/34ae2e5f-ac02-44ca-8f06-c1aaa66b5974/../input.m4a"] {
            input["audio"] = json!(path);
            assert!(validate_request(&input).is_err());
        }
        input["command"] = json!("prepare");
        assert!(validate_request(&input).is_err());
        input["command"] = json!("probe");
        assert!(validate_request(&input).is_ok());
    }

}

#[cfg(unix)]
include!("main_unix.rs");

#[cfg(windows)]
fn main() {
    use std::{ffi::OsStr, io, path::Path};
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() != 3 || ![OsStr::new("desktop-bridge"), OsStr::new("desktop-import-worker"), OsStr::new("desktop-import-queue")].contains(&args[0].as_os_str()) || args[1] != OsStr::new("--root") {
        eprintln!("After Windows preview supports only desktop-bridge, desktop-import-worker or desktop-import-queue with --root <absolute private library>");
        std::process::exit(2);
    }
    let root = Path::new(&args[2]);
    if args[0] == OsStr::new("desktop-import-queue") {
        if posle_core::desktop_queue_service::run_stdio(root, io::stdin().lock(), io::stdout().lock()).is_err() { std::process::exit(1); }
        return;
    }
    if args[0] == OsStr::new("desktop-import-worker") {
        if posle_core::desktop_worker::run_stdio(root).is_err() { std::process::exit(1); }
        return;
    }
    if posle_core::desktop::run_stdio(root, io::stdin().lock(), io::stdout().lock()).is_err() {
        std::process::exit(1);
    }
}

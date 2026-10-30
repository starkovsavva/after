#[cfg(unix)]
include!("main_unix.rs");

#[cfg(windows)]
fn main() {
    use std::{ffi::OsStr, io, path::Path};
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() != 3 || args[0] != OsStr::new("desktop-bridge") || args[1] != OsStr::new("--root") {
        eprintln!("After Windows preview supports only: posle-engine desktop-bridge --root <absolute private library>");
        std::process::exit(2);
    }
    let root = Path::new(&args[2]);
    if posle_core::desktop::run_stdio(root, io::stdin().lock(), io::stdout().lock()).is_err() {
        std::process::exit(1);
    }
}

//! Real processes, no installed Python, shells, media devices or accounts.
use after_process_runtime::ProcessTree;
use std::{
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicUsize, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "after-process-{}-{stamp}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn wait_for(path: &Path) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !path.is_file() {
        assert!(
            Instant::now() < deadline,
            "fixture did not start: {}",
            path.display()
        );
        thread::sleep(Duration::from_millis(10));
    }
}

// Runs recursively in isolated copies of this test binary. The leaf retains
// stdout for its entire lifetime, so EOF proves it no longer holds the pipe.
#[test]
fn fixture_process() {
    let Some(role) = std::env::var_os("AFTER_PROCESS_TEST_ROLE") else {
        return;
    };
    let directory = PathBuf::from(std::env::var_os("AFTER_PROCESS_TEST_DIR").unwrap());
    if role == "echo" {
        let mut bytes = Vec::new();
        io::stdin().read_to_end(&mut bytes).unwrap();
        io::stdout().write_all(&bytes).unwrap();
        return;
    }
    if role == "leaf" {
        io::stdout().write_all(b"leaf ready\n").unwrap();
        io::stdout().flush().unwrap();
        fs::write(directory.join("leaf-ready"), b"ready").unwrap();
    } else {
        // Deliberately use plain Child: the supervisor must contain descendants
        // created by a worker without requiring them to cooperate with it.
        let _child = fixture_command("leaf", &directory)
            .stdout(Stdio::inherit())
            .spawn()
            .unwrap();
        wait_for(&directory.join("leaf-ready"));
        fs::write(directory.join("parent-ready"), b"ready").unwrap();
        if role == "parent-exits" {
            return;
        }
    }
    // A failed test can never leave a permanent fixture running.
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
}

fn fixture_command(role: &str, directory: &Path) -> Command {
    let mut command = Command::new(std::env::current_exe().unwrap());
    command
        .args([
            "--exact",
            "fixture_process",
            "--nocapture",
            "--test-threads=1",
        ])
        .env("AFTER_PROCESS_TEST_ROLE", role)
        .env("AFTER_PROCESS_TEST_DIR", directory)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    command
}

fn spawn(role: &str, directory: &Path) -> (ProcessTree, mpsc::Receiver<io::Result<Vec<u8>>>) {
    let mut child = ProcessTree::spawn(&mut fixture_command(role, directory)).unwrap();
    let mut stdout = child.take_stdout().unwrap();
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = stdout.read_to_end(&mut bytes).map(|_| bytes);
        let _ = sender.send(result);
    });
    (child, receiver)
}

fn eof(receiver: mpsc::Receiver<io::Result<Vec<u8>>>) -> Vec<u8> {
    receiver
        .recv_timeout(Duration::from_secs(5))
        .expect("descendant retained stdout after scope ended")
        .unwrap()
}

#[test]
fn force_stop_closes_descendant_pipes_and_reaps_the_leader() {
    let directory = Directory::new();
    let (mut child, output) = spawn("parent", &directory.0);
    wait_for(&directory.0.join("parent-ready"));
    assert!(child.try_wait().unwrap().is_none());
    child.kill().unwrap();
    let status = child.wait().unwrap();
    assert!(!status.success());
    assert_eq!(child.try_wait().unwrap(), Some(status));
    assert!(String::from_utf8(eof(output))
        .unwrap()
        .contains("leaf ready"));
}

#[test]
fn stop_request_reaches_the_whole_scope() {
    let directory = Directory::new();
    let (mut child, output) = spawn("parent", &directory.0);
    wait_for(&directory.0.join("parent-ready"));
    child.request_stop().unwrap();
    assert!(!child.wait().unwrap().success());
    eof(output);
}

#[test]
fn drop_cleans_up_one_scope_without_cancelling_another() {
    let first = Directory::new();
    let second = Directory::new();
    let (one, output_one) = spawn("parent", &first.0);
    let (mut two, output_two) = spawn("parent", &second.0);
    wait_for(&first.0.join("parent-ready"));
    wait_for(&second.0.join("parent-ready"));
    drop(one);
    eof(output_one);
    assert!(two.try_wait().unwrap().is_none());
    two.kill().unwrap();
    two.wait().unwrap();
    eof(output_two);
}

#[test]
fn normal_parent_exit_stops_leftover_descendants() {
    let directory = Directory::new();
    let (mut child, output) = spawn("parent-exits", &directory.0);
    wait_for(&directory.0.join("parent-ready"));
    let deadline = Instant::now() + Duration::from_secs(5);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        assert!(Instant::now() < deadline, "parent exit was not observed");
        thread::sleep(Duration::from_millis(10));
    };
    assert!(status.success());
    assert_eq!(child.wait().unwrap(), status);
    eof(output);
}

#[test]
fn wait_closes_owned_stdin_and_preserves_exit_status() {
    let directory = Directory::new();
    let mut command = fixture_command("echo", &directory.0);
    command.stdin(Stdio::piped()).stdout(Stdio::null());
    let mut child = ProcessTree::spawn(&mut command).unwrap();
    assert!(child.wait().unwrap().success());
    assert!(child.wait().unwrap().success());
    child.kill().unwrap();
}

#[test]
fn failed_spawn_is_reported_without_a_live_scope() {
    let directory = Directory::new();
    assert!(ProcessTree::spawn(&mut Command::new(directory.0.join("missing-engine"))).is_err());
}

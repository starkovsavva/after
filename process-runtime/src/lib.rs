//! Infrastructure shared by the engine and desktop host. Commands and arguments
//! come from trusted host code; this crate never interprets renderer requests.
//!
//! Ordinary children own an isolated scope (Unix group / Windows Job Object).
//! Explicit Unix contained children share a scope retained by their outer owner.
//! Returning from that scope stops remaining descendants, even after the direct
//! child exits. This is lifecycle management, not a sandbox: Unix children must
//! not deliberately escape their group via setsid/setpgid.
use std::{
    io,
    process::{ChildStderr, ChildStdin, ChildStdout, Command, ExitStatus},
};

#[cfg(unix)]
#[path = "unix.rs"]
mod platform;
#[cfg(windows)]
#[path = "windows.rs"]
mod platform;

pub struct ProcessTree {
    inner: platform::Process,
}

impl ProcessTree {
    /// The supervisor owns process-group/creation flags. It preserves the
    /// command's arguments, environment, working directory and stdio settings.
    pub fn spawn(command: &mut Command) -> io::Result<Self> {
        Ok(Self {
            inner: platform::Process::spawn(command)?,
        })
    }
    /// Spawn within an already owned Unix process group. The caller must retain
    /// its outer ProcessTree until this child and the native publisher exit.
    /// This handle stops/reaps the direct child; the outer owner stops the group.
    #[cfg(unix)]
    pub fn spawn_contained(command: &mut Command) -> io::Result<Self> {
        Ok(Self {
            inner: platform::Process::spawn_contained(command)?,
        })
    }

    pub fn id(&self) -> u32 {
        self.inner.child.id()
    }
    pub fn take_stdin(&mut self) -> Option<ChildStdin> {
        self.inner.child.stdin.take()
    }
    pub fn take_stdout(&mut self) -> Option<ChildStdout> {
        self.inner.child.stdout.take()
    }
    pub fn take_stderr(&mut self) -> Option<ChildStderr> {
        self.inner.child.stderr.take()
    }

    /// Request graceful termination on Unix. Windows has no equivalent signal
    /// for arbitrary GUI/background processes, so it terminates the job.
    pub fn request_stop(&mut self) -> io::Result<()> {
        self.inner.request_stop()
    }
    /// Force termination of the whole owned scope, without waiting.
    pub fn kill(&mut self) -> io::Result<()> {
        self.inner.kill()
    }
    /// Poll the direct child's status. Once it exits, remaining descendants are
    /// stopped before releasing its identity or returning the status.
    pub fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
        self.inner.try_wait()
    }
    pub fn wait(&mut self) -> io::Result<ExitStatus> {
        self.inner.wait()
    }
}

impl Drop for ProcessTree {
    fn drop(&mut self) {
        let _ = self.inner.kill();
        let _ = self.inner.wait();
    }
}

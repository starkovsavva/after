use std::{
    io,
    os::unix::process::CommandExt,
    process::{Child, Command, ExitStatus},
};

pub(super) struct Process {
    pub child: Child,
    group: Option<libc::pid_t>,
    status: Option<ExitStatus>,
    contained: bool,
}

impl Process {
    pub fn spawn(command: &mut Command) -> io::Result<Self> {
        let mut child = command.process_group(0).spawn()?;
        let group = match libc::pid_t::try_from(child.id()) {
            Ok(group) if group > 0 => group,
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(io::Error::other("Invalid child process group"));
            }
        };
        Ok(Self {
            child,
            group: Some(group),
            status: None,
            contained: false,
        })
    }

    // The caller owns an outer ProcessTree whose group contains this process.
    // Only the direct child is signalled/reaped here; the outer owner cleans
    // the entire group after its native publisher exits, including on SIGKILL.
    pub fn spawn_contained(command: &mut Command) -> io::Result<Self> {
        let group = unsafe { libc::getpgrp() };
        let child = command.process_group(group).spawn()?;
        Ok(Self {
            child,
            group: None,
            status: None,
            contained: true,
        })
    }

    fn signal(&self, signal: libc::c_int) -> io::Result<()> {
        if self.status.is_some() {
            return Ok(());
        }
        let target = if let Some(group) = self.group {
            -group
        } else if self.contained {
            self.child.id() as libc::pid_t
        } else {
            return Ok(());
        };
        if unsafe { libc::kill(target, signal) } == 0 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ESRCH) {
            Ok(())
        } else {
            Err(error)
        }
    }
    pub fn request_stop(&mut self) -> io::Result<()> {
        self.signal(libc::SIGTERM)
    }
    pub fn kill(&mut self) -> io::Result<()> {
        self.signal(libc::SIGKILL)
    }

    fn observe_exit(&mut self, nohang: bool) -> io::Result<Option<ExitStatus>> {
        if let Some(status) = self.status {
            return Ok(Some(status));
        }
        let flags = libc::WEXITED | libc::WNOWAIT | if nohang { libc::WNOHANG } else { 0 };
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        loop {
            // Keep the leader unreaped until the group has been stopped. Its
            // PID cannot be reused for an unrelated group between poll and kill.
            let result = unsafe { libc::waitid(libc::P_PID, self.child.id(), &mut info, flags) };
            if result == 0 {
                break;
            }
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
        if unsafe { info.si_pid() } == 0 {
            return Ok(None);
        }
        self.kill()?;
        let status = self.child.wait()?;
        self.group = None;
        self.status = Some(status);
        Ok(Some(status))
    }
    pub fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
        self.observe_exit(true)
    }
    pub fn wait(&mut self) -> io::Result<ExitStatus> {
        drop(self.child.stdin.take());
        self.observe_exit(false)?
            .ok_or_else(|| io::Error::other("Child exit was not observed"))
    }
}

#[cfg(test)]
mod contained_tests {
    use super::*;
    #[test]
    fn contained_child_uses_the_callers_group_and_does_not_signal_its_owner() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "exec sleep 20"]).process_group(0);
        let mut child = Process::spawn_contained(&mut command).unwrap();
        let group = unsafe { libc::getpgid(child.child.id() as libc::pid_t) };
        assert_eq!(group, unsafe { libc::getpgrp() });
        child.kill().unwrap();
        assert!(!child.wait().unwrap().success());
    }
}

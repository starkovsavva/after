use std::{
    io,
    os::windows::{
        io::{AsRawHandle, FromRawHandle, OwnedHandle},
        process::CommandExt,
    },
    process::{Child, Command, ExitStatus},
};
use windows_sys::Win32::{
    Foundation::{HANDLE, INVALID_HANDLE_VALUE},
    System::{
        Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, Thread32First, Thread32Next, TH32CS_SNAPTHREAD, THREADENTRY32,
        },
        JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
            SetInformationJobObject, TerminateJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        },
        Threading::{
            GetProcessIdOfThread, OpenThread, ResumeThread, CREATE_NO_WINDOW, CREATE_SUSPENDED,
            THREAD_QUERY_LIMITED_INFORMATION, THREAD_SUSPEND_RESUME,
        },
    },
};

pub(super) struct Process {
    pub child: Child,
    job: OwnedHandle,
    status: Option<ExitStatus>,
}

fn owned(handle: HANDLE) -> io::Result<OwnedHandle> {
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { OwnedHandle::from_raw_handle(handle) })
}

impl Process {
    pub fn spawn(command: &mut Command) -> io::Result<Self> {
        let job = owned(unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) })?;
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if unsafe {
            SetInformationJobObject(
                job.as_raw_handle(),
                JobObjectExtendedLimitInformation,
                &limits as *const _ as *const _,
                std::mem::size_of_val(&limits) as u32,
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        // The child cannot spawn unowned descendants before assignment. No
        // shell, taskkill, nightly Rust or undocumented NT API is required.
        let child = command
            .creation_flags(CREATE_SUSPENDED | CREATE_NO_WINDOW)
            .spawn()?;
        let mut process = Self {
            child,
            job,
            status: None,
        };
        let setup = (|| {
            if unsafe {
                AssignProcessToJobObject(process.job.as_raw_handle(), process.child.as_raw_handle())
            } == 0
            {
                return Err(io::Error::last_os_error());
            }
            resume_initial_thread(process.child.id())
        })();
        if let Err(error) = setup {
            // Also covers failure before assignment: closing the job alone
            // would leave the suspended direct child alive in that case.
            let _ = process.kill();
            let _ = process.child.kill();
            let _ = process.child.wait();
            return Err(error);
        }
        Ok(process)
    }
    pub fn request_stop(&mut self) -> io::Result<()> {
        self.kill()
    }
    pub fn kill(&mut self) -> io::Result<()> {
        if unsafe { TerminateJobObject(self.job.as_raw_handle(), 1) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
    pub fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
        if let Some(status) = self.status {
            return Ok(Some(status));
        }
        match self.child.try_wait()? {
            Some(status) => {
                self.kill()?;
                self.status = Some(status);
                Ok(Some(status))
            }
            None => Ok(None),
        }
    }
    pub fn wait(&mut self) -> io::Result<ExitStatus> {
        if let Some(status) = self.status {
            return Ok(status);
        }
        let status = self.child.wait()?;
        self.kill()?;
        self.status = Some(status);
        Ok(status)
    }
}

fn resume_initial_thread(pid: u32) -> io::Result<()> {
    let snapshot = owned(unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) })?;
    let mut entry: THREADENTRY32 = unsafe { std::mem::zeroed() };
    entry.dwSize = std::mem::size_of_val(&entry) as u32;
    let mut found = unsafe { Thread32First(snapshot.as_raw_handle(), &mut entry) };
    while found != 0 {
        if entry.th32OwnerProcessID == pid {
            let thread = owned(unsafe {
                OpenThread(
                    THREAD_SUSPEND_RESUME | THREAD_QUERY_LIMITED_INFORMATION,
                    0,
                    entry.th32ThreadID,
                )
            })?;
            if unsafe { GetProcessIdOfThread(thread.as_raw_handle()) } != pid {
                return Err(io::Error::other("Child thread identity changed"));
            }
            return match unsafe { ResumeThread(thread.as_raw_handle()) } {
                u32::MAX => Err(io::Error::last_os_error()),
                1 => Ok(()),
                _ => Err(io::Error::other("Child thread did not resume")),
            };
        }
        found = unsafe { Thread32Next(snapshot.as_raw_handle(), &mut entry) };
    }
    Err(io::Error::other("Suspended child thread was not found"))
}

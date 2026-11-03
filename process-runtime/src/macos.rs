//! Darwin skips zombies while signalling a group, returning EPERM when no
//! signalable member remains. Verify membership before treating that as empty.
//! https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_sig.c
use std::mem::{size_of, zeroed};

pub(super) fn group_has_no_live_members(group: libc::pid_t) -> bool {
    if group <= 0 {
        return false;
    }
    let mut capacity = 32;
    loop {
        let mut pids = vec![0 as libc::pid_t; capacity];
        unsafe {
            *libc::__error() = 0;
        }
        let count = unsafe {
            libc::proc_listpgrppids(
                group,
                pids.as_mut_ptr().cast(),
                (pids.len() * size_of::<libc::pid_t>()) as libc::c_int,
            )
        };
        if count == 0 {
            let error = std::io::Error::last_os_error().raw_os_error();
            return error == Some(0) || error == Some(libc::ESRCH);
        }
        if count < 0 {
            return false;
        }
        if count as usize >= capacity {
            if capacity >= 262_144 {
                return false;
            }
            capacity *= 2;
            continue;
        }
        for pid in pids.into_iter().take(count as usize).filter(|pid| *pid > 0) {
            let mut info: libc::proc_bsdinfo = unsafe { zeroed() };
            unsafe {
                *libc::__error() = 0;
            }
            let read = unsafe {
                libc::proc_pidinfo(
                    pid,
                    libc::PROC_PIDTBSDINFO,
                    0,
                    (&mut info as *mut libc::proc_bsdinfo).cast(),
                    size_of::<libc::proc_bsdinfo>() as libc::c_int,
                )
            };
            if read == 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH) {
                continue;
            }
            if read as usize != size_of::<libc::proc_bsdinfo>() {
                return false;
            }
            if info.pbi_pgid == group as u32 && info.pbi_status != libc::SZOMB {
                return false;
            }
        }
        return true;
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn current_live_group_is_never_classified_as_empty() {
        assert!(!super::group_has_no_live_members(unsafe {
            libc::getpgrp()
        }));
        assert!(!super::group_has_no_live_members(-1));
    }
}

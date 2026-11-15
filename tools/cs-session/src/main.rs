use std::env;
use std::io;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, ExitCode};
use std::time::{Duration, Instant};

// Signals stay blocked from before spawn until exec in the child. There is no
// handler touching a PID concurrently with waitpid (or a recycled PID).
fn signal_set() -> io::Result<u64> {
    unsafe {
        // musl's public signal functions reserve signals 32–34. This process is
        // single-threaded and uses the kernel ABI so those catchable signals
        // cannot terminate the supervisor without descendant cleanup.
        let set: u64 = !((1 << (libc::SIGKILL - 1)) | (1 << (libc::SIGSTOP - 1)));
        if libc::syscall(
            libc::SYS_rt_sigprocmask,
            libc::SIG_BLOCK,
            &set,
            0usize,
            8usize,
        ) == -1
        {
            return Err(io::Error::last_os_error());
        }
        // SIG_DFL, no flags and an empty mask are all zero. Supply enough zero
        // words for the kernel action without depending on musl's struct layout.
        let default = [0u64; 4];
        // An inherited SIG_IGN for SIGCHLD would automatically reap our children.
        for signal in 1..=libc::SIGRTMAX() {
            if signal != libc::SIGKILL && signal != libc::SIGSTOP {
                if libc::syscall(libc::SYS_rt_sigaction, signal, &default, 0usize, 8usize) == -1 {
                    return Err(io::Error::last_os_error());
                }
            }
        }
        Ok(set)
    }
}

fn receive(set: &u64, timeout: Duration) -> io::Result<Option<i32>> {
    let ts = libc::timespec {
        tv_sec: timeout.as_secs() as _,
        tv_nsec: timeout.subsec_nanos() as _,
    };
    let signal =
        unsafe { libc::syscall(libc::SYS_rt_sigtimedwait, set, 0usize, &ts, 8usize) } as i32;
    if signal >= 0 {
        Ok(Some(signal))
    } else {
        let error = io::Error::last_os_error();
        match error.raw_os_error() {
            Some(libc::EINTR | libc::EAGAIN) => Ok(None),
            _ => Err(error),
        }
    }
}

fn reap() -> io::Result<Option<(i32, i32)>> {
    let mut status = 0;
    let pid = unsafe { libc::waitpid(-1, &mut status, libc::WNOHANG) };
    if pid > 0 {
        Ok(Some((pid, status)))
    } else if pid == 0 || io::Error::last_os_error().raw_os_error() == Some(libc::ECHILD) {
        Ok(None)
    } else {
        Err(io::Error::last_os_error())
    }
}

fn pause(set: &u64) -> io::Result<i32> {
    loop {
        while reap()?.is_some() {}
        if receive(set, Duration::from_secs(60))? == Some(libc::SIGTERM) {
            return Ok(0);
        }
    }
}

fn transient_proc_error(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::NotFound | io::ErrorKind::PermissionDenied
    ) || error.raw_os_error() == Some(libc::ESRCH)
}

fn descendants(set: &u64) -> io::Result<()> {
    // Kill direct children, reap them, then repeat for newly adopted children.
    // A process group alone misses setsid/double-fork descendants. Linux exposes
    // only this launcher's children here, so concurrent sessions are untouched.
    loop {
        while reap()?.is_some() {}
        let mut children = Vec::new();
        for entry in std::fs::read_dir("/proc")? {
            let entry = entry?;
            let Some(pid) = entry
                .file_name()
                .to_str()
                .and_then(|name| name.parse::<i32>().ok())
            else {
                continue;
            };
            let stat = match std::fs::read(entry.path().join("stat")) {
                Ok(stat) => stat,
                // Other users' processes may be hidden; a process may also exit
                // during enumeration. Our own unreaped children remain visible.
                Err(error) if transient_proc_error(&error) => continue,
                Err(error) => return Err(error),
            };
            // comm is parenthesized and may itself contain spaces or ')'.
            // comm may contain arbitrary bytes, not necessarily UTF-8.
            let end = stat
                .iter()
                .rposition(|byte| *byte == b')')
                .ok_or_else(|| io::Error::other("invalid proc stat"))?;
            let fields = std::str::from_utf8(&stat[end + 1..]).map_err(io::Error::other)?;
            let parent = fields
                .split_whitespace()
                .nth(1)
                .and_then(|field| field.parse::<u32>().ok());
            if parent == Some(std::process::id()) {
                children.push(pid);
            }
        }
        if children.is_empty() {
            return Ok(());
        }
        for pid in children {
            // We have not reaped this PID, so it cannot be recycled underneath us.
            unsafe { libc::kill(pid, libc::SIGKILL) };
        }
        // Bound the sleep even if SIGCHLD was coalesced with a previous death.
        receive(set, Duration::from_millis(10))?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    #[test]
    fn disappearing_proc_stat_is_skipped() {
        // Opening a zombie's stat succeeds, but reading that same descriptor
        // after its parent reaps it yields ESRCH on Linux. Another session can
        // race our open/read exactly this way during cleanup.
        let pid = unsafe { libc::fork() };
        assert!(pid >= 0);
        if pid == 0 {
            unsafe { libc::_exit(0) }
        }
        let mut file = std::fs::File::open(format!("/proc/{pid}/stat")).unwrap();
        let mut status = 0;
        assert_eq!(unsafe { libc::waitpid(pid, &mut status, 0) }, pid);
        let error = file.read_to_string(&mut String::new()).unwrap_err();
        assert_eq!(error.raw_os_error(), Some(libc::ESRCH));
        assert!(
            transient_proc_error(&error),
            "a disappearing process must not abort cleanup"
        );
        assert!(!transient_proc_error(&io::Error::from_raw_os_error(
            libc::EIO
        )));
    }
}

fn remove_temporary(directory: &Path) -> io::Result<()> {
    let metadata = match std::fs::symlink_metadata(directory) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    if !metadata.is_dir() {
        return std::fs::remove_file(directory);
    }
    // Programs may leave read-only caches. All descendants are gone, so restore
    // owner access before traversing. Symlinks are unlinked, never traversed.
    std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700))?;
    for entry in std::fs::read_dir(directory)? {
        remove_temporary(&entry?.path())?;
    }
    std::fs::remove_dir(directory)
}

fn run(set: &u64, directory: &Path, program: &[std::ffi::OsString]) -> io::Result<i32> {
    if unsafe { libc::prctl(libc::PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) } == -1 {
        return Err(io::Error::last_os_error());
    }
    std::fs::DirBuilder::new().mode(0o700).create(directory)?;
    let result: io::Result<i32> = (|| {
        std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700))?;
        let mut command = Command::new(&program[0]);
        command.args(&program[1..]).env("TMPDIR", directory);
        unsafe {
            command.pre_exec(|| {
                let mut empty = std::mem::zeroed();
                libc::sigemptyset(&mut empty);
                if libc::sigprocmask(libc::SIG_SETMASK, &empty, std::ptr::null_mut()) == -1 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = match command.spawn() {
            Ok(child) => child,
            Err(error) => {
                return Ok(if error.raw_os_error() == Some(libc::ENOENT) {
                    127
                } else {
                    126
                });
            }
        };
        let pid = child.id() as i32;
        let mut deadline = None;
        let status = 'running: loop {
            while let Some((reaped, status)) = reap()? {
                if reaped == pid {
                    break 'running status;
                }
            }
            let timeout = deadline.map_or(Duration::from_secs(60), |end: Instant| {
                end.saturating_duration_since(Instant::now())
            });
            if let Some(signal) = receive(set, timeout)? {
                let forwarded = if signal == libc::SIGRTMIN() + 1 {
                    libc::SIGKILL
                } else {
                    signal
                };
                unsafe { libc::kill(pid, forwarded) };
                if signal == libc::SIGTERM && deadline.is_none() {
                    deadline = Some(Instant::now() + Duration::from_secs(5));
                }
            }
            if deadline.is_some_and(|end| Instant::now() >= end) {
                unsafe { libc::kill(pid, libc::SIGKILL) };
                deadline = None;
            }
        };
        descendants(set)?;
        Ok(if libc::WIFEXITED(status) {
            libc::WEXITSTATUS(status)
        } else {
            128 + libc::WTERMSIG(status)
        })
    })();
    let cleanup = remove_temporary(directory);
    let code = result?;
    cleanup?;
    Ok(code)
}

fn main() -> ExitCode {
    let args: Vec<_> = env::args_os().skip(1).collect();
    let valid_pause = args.len() == 1 && args[0] == "pause";
    let valid_run = args.len() >= 5 && args[0] == "run" && args[1] == "--tmp" && args[3] == "--";
    if !valid_pause && !valid_run {
        eprintln!("usage: cs-session pause | cs-session run --tmp <dir> -- <program> [args...]");
        return ExitCode::from(125);
    }
    let result = signal_set().and_then(|set| {
        if valid_pause {
            pause(&set)
        } else {
            run(&set, Path::new(&args[2]), &args[4..])
        }
    });
    match result {
        Ok(code) => ExitCode::from(code as u8),
        Err(error) => {
            eprintln!("cs-session: {error}");
            ExitCode::from(126)
        }
    }
}

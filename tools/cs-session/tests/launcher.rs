use std::io::{Read, Write};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Session {
    child: Child,
    root: PathBuf,
    tmp: PathBuf,
    finished: bool,
}
impl Session {
    fn start(mode: &str) -> Self {
        let fixture = PathBuf::from(env!("CARGO_BIN_EXE_cs-session"))
            .parent()
            .unwrap()
            .join("examples/fixture");
        Self::program(&[fixture.to_str().unwrap(), mode])
    }
    fn program(program: &[&str]) -> Self {
        let root = std::env::temp_dir().join(format!(
            "cs-session-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&root).unwrap();
        let tmp = root.join("tmp");
        let mut command = Command::new(env!("CARGO_BIN_EXE_cs-session"));
        command
            .arg("run")
            .arg("--tmp")
            .arg(&tmp)
            .arg("--")
            .args(program);
        if program[0].ends_with("/fixture") {
            command.arg(&root);
        }
        if program.get(1) == Some(&"readonly") && unsafe { libc::geteuid() } == 0 {
            let path = std::ffi::CString::new(root.as_os_str().as_encoded_bytes()).unwrap();
            assert_eq!(unsafe { libc::chown(path.as_ptr(), 65534, 65534) }, 0);
            command.gid(65534).uid(65534);
        }
        let child = command
            .current_dir(&root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        Self {
            child,
            root,
            tmp,
            finished: false,
        }
    }
    fn signal(&self, signal: i32) {
        assert_eq!(unsafe { libc::kill(self.child.id() as i32, signal) }, 0);
    }
    fn ready(&mut self, name: &str) {
        let end = Instant::now() + Duration::from_secs(3);
        while !self.root.join(name).exists() {
            assert!(
                self.child.try_wait().unwrap().is_none(),
                "launcher exited before {name}"
            );
            assert!(Instant::now() < end, "no {name}");
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    fn finish(&mut self, code: i32, limit: Duration) {
        let end = Instant::now() + limit;
        loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                assert_eq!(status.code(), Some(code));
                break;
            }
            assert!(Instant::now() < end, "launcher did not exit");
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(!self.tmp.exists(), "temporary directory remains");
        if let Ok(pids) = std::fs::read_to_string(self.root.join("ready")) {
            let pids: Vec<_> = pids.split_whitespace().collect();
            assert_eq!(pids.len(), 3, "fixture must have main and two children");
            for pid in pids {
                assert!(
                    !PathBuf::from(format!("/proc/{pid}")).exists(),
                    "process {pid} remains (including zombies)"
                );
            }
        }
        self.finished = true;
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        // Failure cleanup is limited to processes and paths this test created.
        if !self.finished {
            if let Ok(pids) = std::fs::read_to_string(self.root.join("ready")) {
                for pid in pids.split_whitespace() {
                    unsafe {
                        libc::kill(pid.parse().unwrap(), libc::SIGKILL);
                    }
                }
            }
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.root);
    }
}
#[test]
fn exit_code_tmpdir_mode_and_current_directory() {
    let mut s = Session::start("exit");
    s.finish(37, Duration::from_secs(3));
    assert_eq!(
        std::fs::read(s.root.join("cwd")).unwrap(),
        s.root.as_os_str().as_encoded_bytes()
    );
}
#[test]
fn sigterm_five_second_limit_and_descendants() {
    let mut s = Session::start("ignore");
    s.ready("ready");
    let start = Instant::now();
    s.signal(libc::SIGTERM);
    std::thread::sleep(Duration::from_secs(1));
    s.signal(libc::SIGTERM); // Must not restart the five second deadline.
    s.finish(137, Duration::from_millis(4800));
    assert!(start.elapsed() >= Duration::from_secs(5));
    assert!(start.elapsed() < Duration::from_millis(5800));
}
#[test]
fn control_signal_ends_immediately_and_cleans_descendants() {
    let mut s = Session::start("ignore");
    s.ready("ready");
    s.signal(libc::SIGRTMIN() + 1);
    s.finish(137, Duration::from_secs(2));
}
#[test]
fn handled_sigusr1_keeps_session_alive() {
    let mut s = Session::start("usr1");
    s.ready("ready");
    s.signal(libc::SIGUSR1);
    s.ready("handled");
    std::thread::sleep(Duration::from_millis(100));
    assert!(s.child.try_wait().unwrap().is_none());
    assert!(s.tmp.exists());
    s.signal(libc::SIGRTMIN() + 1);
    s.finish(137, Duration::from_secs(2));
}
#[test]
fn stdin_eof_still_allows_answer() {
    let mut s = Session::start("stdin");
    let mut stdin = s.child.stdin.take().unwrap();
    stdin.write_all(b"request").unwrap();
    drop(stdin);
    s.finish(0, Duration::from_secs(3));
    let mut output = String::new();
    s.child
        .stdout
        .take()
        .unwrap()
        .read_to_string(&mut output)
        .unwrap();
    assert_eq!(output, "answer:request\n");
}
#[test]
fn signal_exit_code() {
    let mut s = Session::start("signal");
    s.finish(128 + libc::SIGUSR2, Duration::from_secs(3));
}
#[test]
fn not_found_and_cannot_execute() {
    for (program, code) in [("/no-such-program", 127), ("/", 126)] {
        let mut s = Session::program(&[program]);
        s.finish(code, Duration::from_secs(3));
    }
}
#[test]
fn usage_errors() {
    for args in [
        vec![],
        vec!["pause", "extra"],
        vec!["run", "--tmp", "/tmp/no", "--"],
    ] {
        assert_eq!(
            Command::new(env!("CARGO_BIN_EXE_cs-session"))
                .args(args)
                .status()
                .unwrap()
                .code(),
            Some(125)
        );
    }
}
#[test]
fn natural_exit_cleans_double_fork_and_setsid_descendants() {
    let mut s = Session::start("orphan");
    s.finish(37, Duration::from_secs(3));
    assert!(
        s.root.join("ready").exists(),
        "fixture did not create descendants"
    );
}

#[test]
fn pause_reaps_children() {
    let mut s = Session::start("pause-parent");
    s.ready("pause-child");
    let pid = std::fs::read_to_string(s.root.join("pause-child")).unwrap();
    let end = Instant::now() + Duration::from_secs(2);
    while PathBuf::from(format!("/proc/{pid}")).exists() {
        assert!(Instant::now() < end, "pause left a zombie");
        std::thread::sleep(Duration::from_millis(10));
    }
    s.signal(libc::SIGTERM);
    s.finish(0, Duration::from_secs(2));
}

#[test]
fn reserved_kernel_signals_are_forwarded_without_losing_cleanup() {
    for signal in 32..=34 {
        let mut s = Session::start("ignore");
        s.ready("ready");
        s.signal(signal);
        s.finish(128 + signal, Duration::from_secs(2));
    }
}

#[test]
fn program_can_remove_its_own_tmpdir() {
    let mut s = Session::start("remove-tmp");
    s.finish(37, Duration::from_secs(3));
}

#[test]
fn nonroot_readonly_tmpdir_is_removed() {
    let mut s = Session::start("readonly");
    s.finish(37, Duration::from_secs(3));
}

#[test]
fn ending_one_session_preserves_another() {
    let mut first = Session::start("ignore");
    let mut second = Session::start("usr1");
    first.ready("ready");
    second.ready("ready");
    first.signal(36); // Fixed musl Linux control number used by the caller.
    first.finish(137, Duration::from_secs(2));
    assert!(second.child.try_wait().unwrap().is_none());
    assert!(second.tmp.exists());
    second.signal(libc::SIGUSR1);
    second.ready("handled");
    second.signal(36);
    second.finish(137, Duration::from_secs(2));
}

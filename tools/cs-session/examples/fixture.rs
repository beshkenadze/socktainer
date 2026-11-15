use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::Path;

fn report_file(report: &Path, name: &str, contents: impl AsRef<[u8]>) {
    let temporary = report.join(format!(".{name}.tmp"));
    std::fs::write(&temporary, contents).unwrap();
    std::fs::rename(temporary, report.join(name)).unwrap();
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let report = Path::new(&args[2]);
    if args[1] == "pause-parent" {
        let pid = unsafe { libc::fork() };
        assert!(pid >= 0);
        if pid == 0 {
            unsafe { libc::_exit(0) }
        }
        report_file(report, "pause-child", pid.to_string());
        let launcher = std::env::current_exe()
            .unwrap()
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .join("cs-session");
        panic!(
            "exec pause: {}",
            std::process::Command::new(launcher).arg("pause").exec()
        );
    }
    let tmp = std::env::var("TMPDIR").unwrap();
    assert_eq!(
        std::fs::metadata(&tmp).unwrap().permissions().mode() & 0o777,
        0o700
    );
    std::fs::create_dir(format!("{tmp}/nested")).unwrap();
    std::fs::write(format!("{tmp}/nested/data"), "session data").unwrap();
    // Cleanup must unlink this link, never follow it into the report directory.
    std::os::unix::fs::symlink(report, format!("{tmp}/outside")).unwrap();
    std::fs::write(
        report.join("cwd"),
        std::env::current_dir()
            .unwrap()
            .as_os_str()
            .as_encoded_bytes(),
    )
    .unwrap();
    match args[1].as_str() {
        "exit" => std::process::exit(37),
        "remove-tmp" => {
            std::fs::remove_dir_all(&tmp).unwrap();
            std::process::exit(37);
        }
        "readonly" => {
            assert_ne!(
                unsafe { libc::geteuid() },
                0,
                "must exercise non-root cleanup"
            );
            std::fs::set_permissions(format!("{tmp}/nested"), std::fs::Permissions::from_mode(0))
                .unwrap();
            std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o500)).unwrap();
            std::process::exit(37);
        }
        "stdin" => {
            let mut input = String::new();
            std::io::stdin().read_to_string(&mut input).unwrap();
            println!("answer:{input}");
        }
        "ignore" | "usr1" | "orphan" => unsafe {
            if args[1] == "usr1" {
                // Another session's proc stat can have a non-UTF-8 comm field.
                assert_eq!(
                    libc::prctl(libc::PR_SET_NAME, b"odd\xff) name\0".as_ptr(), 0, 0, 0),
                    0
                );
            }
            libc::signal(libc::SIGTERM, libc::SIG_IGN);
            let mut blocked = std::mem::zeroed();
            libc::sigemptyset(&mut blocked);
            libc::sigaddset(&mut blocked, libc::SIGUSR1);
            libc::sigprocmask(libc::SIG_BLOCK, &blocked, std::ptr::null_mut());
            let mut pids = vec![std::process::id()];
            for index in 0..2 {
                let pid = libc::fork();
                assert!(pid >= 0);
                if pid == 0 {
                    libc::setsid();
                    if args[1] == "orphan" && index == 0 {
                        let grandchild = libc::fork();
                        assert!(grandchild >= 0);
                        if grandchild != 0 {
                            libc::_exit(0);
                        }
                        report_file(report, "grandchild", std::process::id().to_string());
                    }

                    loop {
                        libc::pause();
                    }
                }
                pids.push(pid as u32);
            }
            if args[1] == "orphan" {
                let mut status = 0;
                assert_eq!(
                    libc::waitpid(pids[1] as i32, &mut status, 0),
                    pids[1] as i32
                );
                while !report.join("grandchild").exists() {
                    std::thread::sleep(std::time::Duration::from_millis(1));
                }
                pids[1] = std::fs::read_to_string(report.join("grandchild"))
                    .unwrap()
                    .parse()
                    .unwrap();
            }
            report_file(
                report,
                "ready",
                pids.iter()
                    .map(u32::to_string)
                    .collect::<Vec<_>>()
                    .join(" "),
            );
            if args[1] == "orphan" {
                std::process::exit(37);
            }
            if args[1] == "usr1" {
                let mut signal = 0;
                assert_eq!(libc::sigwait(&blocked, &mut signal), 0);
                assert_eq!(signal, libc::SIGUSR1);
                report_file(report, "handled", "USR1");
            }
            loop {
                libc::pause();
            }
        },
        "signal" => unsafe {
            libc::raise(libc::SIGUSR2);
        },
        _ => panic!("unknown fixture"),
    }
}

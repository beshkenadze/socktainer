# cs-session

Static Linux arm64 session launcher for shared runtimes (spec v0.2, §3.3,
F-006 launcher behavior and F-013). It requires Linux procfs at `/proc`, but
requires no shell or shared libraries in the session image.

```
cs-session pause
cs-session run --tmp <dir> -- <program> [args...]
```

`pause` reaps children and exits 0 on SIGTERM. `run` becomes a child subreaper,
creates a new directory with mode 0700, and gives the program `TMPDIR=<dir>`.
The directory must not already exist; its parent must exist and be writable.
The program inherits stdin, stdout, stderr, the current directory and the
launcher environment (with TMPDIR replaced). Program lookup uses PATH.

Signals are blocked before spawning and consumed synchronously through the Linux kernel ABI, including signals 32–34 that musl reserves internally. The child
restores an empty signal mask before exec. Catchable signals are forwarded
unchanged to the main process, except `SIGRTMIN+1`, which sends SIGKILL
immediately. The first SIGTERM starts a monotonic five-second deadline;
additional SIGTERMs do not extend it. Never send SIGKILL to the launcher.
On musl Linux the control signal is 36 (`SIGRTMIN` is 35); callers must use the
launcher's Linux signal numbering, not the host's libc numbering.

After the main program exits, the launcher repeatedly kills and reaps its
remaining direct children. Subreaper adoption brings orphaned descendants into
that set, including descendants that call setsid or change process groups. It
then recursively removes the temporary directory (without following symlinks).
It returns the program's exit code, or 128 + its terminating signal; usage is
125, execution failure is 126, and a missing executable is 127. Setup or cleanup
errors are reported to stderr and return 126.

## Build and test

On an arm64 Mac with the existing ContainerStack Docker socket:

```sh
DOCKER_HOST="unix://$HOME/.containerstack/docker.sock" tools/cs-session/build.sh test
```

Use `build` instead of `test` to skip the test suite. This uses one disposable
`cs-session-test-*` container, removed on completion or interruption. It never
starts an image builder or manages the runtime. The recipe pins the Rust/Alpine
image by digest and locks the sole Rust dependency in Cargo.lock. It installs
musl headers and ELF inspection utilities inside that disposable container.
The ELF checks reject an interpreter or dynamic dependencies.

Linux arm64 with Docker can run the same script. For a native toolchain, install
Rust and the `aarch64-unknown-linux-musl` target, set its linker to `musl-gcc`,
and run these commands from this directory:

```sh
CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=musl-gcc \
  cargo build --locked --release --target aarch64-unknown-linux-musl
```

The Linux procfs regression reproduces ESRCH when a process is reaped between opening and reading its stat file. The container tests run the release binary and a Rust fixture, serially. They
check exit status, TMPDIR permissions and nested directory cleanup, unchanged
working directory, signal exit status, SIGTERM timing without deadline extension,
immediate control termination, handled SIGUSR1, stdin EOF followed by stdout,
missing/unrunnable programs, usage, and pause termination. The signal tests
record the main PID and two child PIDs and require that all three disappear
from procfs, including zombies, before declaring success. They also check simultaneous sessions, self-deleted TMPDIR, non-root read-only directory cleanup and forwarding of signals 32–34. Their children leave
the original process group to exercise subreaper cleanup.

## Binary handoff to wave 2

The local recipe writes **`tools/cs-session/dist/linux-arm64/cs-session`** and
prints its SHA-256. CI publishes this file as artifact **`cs-session-linux-arm64`**
from the `cs-session` workflow. Build outputs are ignored, not committed.
Wave 2 should consume this exact file for embedding and materialize/mount it
read-only at `/run/containerstack/cs-session`. This change does not register a
Swift target, embed bytes, mount a binary, or change container routes.

The existing DNS delivery was traced from Package.swift's `SocktainerDNSImage`
product to [dns-forwarder](https://github.com/socktainer/dns-forwarder),
`v0.2.0` (`07a861b754bcc6e7b749d149178054d215941faa`). Its source branch
(`6e2dbc38e3dd9c3a8254c0a5f4e5dc7ba0473e6f`) uses Rust, target
`aarch64-unknown-linux-musl`, and the same pinned Rust/Alpine builder used here.
Its release workflow puts the static binary into a scratch OCI image, exports
a gzip OCI archive, then generates a C byte array on its `swiftpm` branch.
The Swift package wraps those bytes with `archiveURL()`; socktainer imports
that archive in `Sources/socktainer/DNS/EmbeddedDNSImage.swift`. A launcher
needs a mounted executable rather than a DNS container image; wave 2 can use
the same C-byte embedding technique on the raw binary supplied here. Rust/musl
keeps the existing language and static toolchain without adding shell or libc
requirements to session images.

## Validation record

Local Linux arm64 release build: Rust 1.96.0, 15 tests passed (one kernel/procfs
unit regression and fourteen launcher tests). The ELF has no interpreter or
shared-library dependencies.

| Test | Result |
| --- | --- |
| `disappearing_proc_stat_is_skipped` | Passed |
| `control_signal_ends_immediately_and_cleans_descendants` | Passed |
| `ending_one_session_preserves_another` | Passed |
| `exit_code_tmpdir_mode_and_current_directory` | Passed |
| `handled_sigusr1_keeps_session_alive` | Passed |
| `natural_exit_cleans_double_fork_and_setsid_descendants` | Passed |
| `nonroot_readonly_tmpdir_is_removed` | Passed |
| `not_found_and_cannot_execute` | Passed |
| `pause_reaps_children` | Passed |
| `program_can_remove_its_own_tmpdir` | Passed |
| `reserved_kernel_signals_are_forwarded_without_losing_cleanup` | Passed |
| `signal_exit_code` | Passed |
| `sigterm_five_second_limit_and_descendants` | Passed |
| `stdin_eof_still_allows_answer` | Passed |
| `usage_errors` | Passed |

Review corrections were verified against the earlier implementation:

- The procfs regression actually opens a child's stat file, reaps the child,
  then reads the descriptor to reproduce ESRCH. It fails without ESRCH handling.
- The reserved-signal regression fails when the launcher uses musl's public
  signal set: the launcher dies instead of forwarding the signal and cleaning up.
- Self-deleted TMPDIR and non-root read-only directory tests both return 126
  instead of 37 with the earlier cleanup implementation.
- The concurrent-session test includes a non-UTF-8 process name; the earlier
  string-based procfs reader aborts cleanup with 126. Byte-based parsing passes.
- The redundant pause test that depended on a 100 ms sleep was removed;
  `pause_reaps_children` proves readiness before sending SIGTERM.

Suggestions to suppress SIGCHLD, restrict relative directory arguments, or
change the frozen specification's control-signal spelling were not applied:
the launcher retains the frozen interface and forwards each catchable signal.
The numeric musl control signal (36) is documented and exercised by the
concurrent-session test. Final ELF checks run after all builds and tests.
The source recipe remains the durable handoff if a CI artifact expires.

Additional local checks passed: `pause` as container init exits 0 on SIGTERM;
a file with executable permission but invalid executable contents returns 126.
The complete shared-runtime bridge and client-disconnect integration are wave 2
work and were not exercised by these launcher tests.

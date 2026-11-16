# Shared runtime groups

With `--shared-runtimes`, socktainer can run each `docker run -i --rm <image>` of a group as a
**session**: a process in a shared container of the group, not a VM of its own. The client
still sees a container of its own. Without the flag, nothing of this feature runs.

The groups and their rules are in `~/.containerstack/runtime-groups.json`. Both groups of the
default document are off. A run selects a group with the label `containerstack.group=<name>`
(`none` = no group) or with the first rule of an enabled group that matches.

## What a session supports

- `create`, `attach`, `wait`, `start`, `stop`, `kill`, `rm`, `inspect`, `logs`, and the
  container list. Every other route that takes a container ID answers 409 "not supported for
  a session of a shared group".
- `stop` sends SIGTERM (or the requested signal) and then ends the session after the timeout.
  The launcher ends the program 5 s after the first SIGTERM, so a timeout over 5 s does not give
  the program more time.
- `kill` with no signal, or with SIGKILL, ends the session at once. SIGSTOP is refused with 400.
- A session has one attach connection. A second `attach` is closed at once.
- Output waits in memory for a client that reads slowly, up to 8 MiB per attach connection. Past
  that, the connection closes and the session ends as for a client that is gone.
- `logs` serves the newest 256 KiB of output, whole lines, each with its stream. The output is
  dropped when the session ends.
- `inspect` returns the ID, name, state, image, command, user, working directory and labels.
  `Config.Env` is empty: a session does not show environment values.
- Each session gets its own `TMPDIR`, `/tmp/cs-session-<first 12 characters of its ID>`. The
  image must have a writable `/tmp`; without one, the session fails with exit code 126.

## Labels

| On | Label | Value |
|---|---|---|
| shared container | `containerstack.shared.group` | group name |
| shared container | `containerstack.shared.key` | first 16 hex characters of the sharing key |
| shared container | `containerstack.shared.socket` | socket path of the bridge that owns it |
| session | `containerstack.session.group` | group name |
| session | `containerstack.session.container` | Docker ID of its shared container |
| dedicated run | `containerstack.group.skipped` | `<group>:<reason>` |

A shared container is one trust domain: its sessions run as one user on one writable file
system. A run that needs separation stays dedicated (`containerstack.group=none`).

## Live check

Run the check on a second bridge with its own socket, not on the bridge that you use.

```bash
make release
cp ~/.containerstack/runtime-groups.json ~/.containerstack/runtime-groups.json.bak 2>/dev/null
cat > ~/.containerstack/runtime-groups.json <<'JSON'
{
  "version": 1,
  "groups": [
    { "name": "mcp-catalog",    "kind": "exec", "idleMinutes": 5, "enabled": true },
    { "name": "stdio-sessions", "kind": "exec", "idleMinutes": 5, "enabled": false }
  ],
  "rules": [
    { "group": "mcp-catalog",    "image": "mcp/*" },
    { "group": "stdio-sessions", "stdioSession": true }
  ]
}
JSON
# The socket directory must exist. Use /private/tmp, not /tmp: /tmp is a symlink, and the bridge
# cannot create it.
mkdir -p /private/tmp/cs-live
# One idle minute lasts 10 s, so the idle stop of check 4 comes after 50 s.
SOCKTAINER_SHARED_RUNTIMES_IDLE_MINUTE_SECONDS=10 "$PWD/.build/release/socktainer" \
  --socket /private/tmp/cs-live/docker.sock --no-check-compatibility --no-docker-context \
  --no-startup-housekeeping --shared-runtimes &
# The PID of the bridge itself: a plain `pgrep -f socktainer` also matches the shell that started it.
sleep 2; bridge=$(pgrep -f "^$PWD/.build/release/socktainer")
export DOCKER_HOST=unix:///private/tmp/cs-live/docker.sock
docker info --format '{{json .Labels}} {{json .Warnings}}'   # containerstack.shared-runtimes=on
```

1. Three sessions with one environment are one VM:

   ```bash
   for i in 1 2 3; do
     (sleep 600 | docker run -i --rm -l containerstack.group=mcp-catalog \
        -e DATABASE_URI=postgresql://user:pass@localhost/db crystaldba/postgres-mcp) &
   done
   docker ps --filter label=containerstack.session.group=mcp-catalog \
     --format '{{.ID}} {{.Label "containerstack.session.container"}}'   # one common container
   container list | grep cs-shared-mcp-catalog                         # one shared container
   ps -axo rss=,command= | grep '[V]irtualization.VirtualMachine' | awk '{s+=$1} END {print s/1024 " MB"}'
   ```

2. A real MCP exchange through a session:

   ```bash
   mcp='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}
   {"jsonrpc":"2.0","method":"notifications/initialized"}
   {"jsonrpc":"2.0","id":2,"method":"tools/list"}'
   echo "$mcp" | docker run -i --rm -l containerstack.group=mcp-catalog mcp/time
   echo "$mcp" | docker run -i --rm -l containerstack.group=mcp-catalog mcp/sequentialthinking
   echo "$mcp" | docker run -i --rm -l containerstack.group=mcp-catalog \
     -e GITHUB_PERSONAL_ACCESS_TOKEN ghcr.io/github/github-mcp-server stdio
   echo "$mcp" | docker run -i --rm mcp/time          # selected by the rule, no label
   ```

3. A killed client leaves no process of its session:

   ```bash
   sleep 600 | docker run -i --rm -l containerstack.group=mcp-catalog busybox:1.37-musl \
     sh -c 'sleep 1000 & sleep 1000 & wait' &
   sleep 5; pkill -9 -f 'docker run -i --rm -l containerstack.group=mcp-catalog busybox'
   sleep 10
   shared=$(container list | awk '/cs-shared-mcp-catalog/ {print $1; exit}')
   container exec "$shared" /run/containerstack/cs-session run --tmp /tmp/check -- ps   # no sleep 1000
   container exec "$shared" /run/containerstack/cs-session run --tmp /tmp/check -- ls /tmp   # no cs-session-*
   ```

   (In check 3 the shared container runs `busybox`, so `ps` and `ls` exist in it.)

4. Idle stop: when the last session has ended, the shared container is gone after about 50 s:

   ```bash
   sleep 60; container list --all | grep cs-shared || echo "no shared container"
   ```

5. Exit codes and signals. `sleep 600 | docker run` keeps the pipeline up after the session
   ends, so these checks give stdin from `/dev/zero`:

   ```bash
   docker run -i --rm -l containerstack.group=mcp-catalog busybox:1.37-musl \
     sh -c 'echo out; echo err >&2; exit 7' < /dev/zero; echo "exit=$?"       # out, err, exit=7
   docker run -i --rm --name stop-check -l containerstack.group=mcp-catalog busybox:1.37-musl \
     sh -c 'trap "" TERM; sleep 1000' < /dev/zero & sleep 3
   time docker stop -t 2 stop-check; wait $!; echo "exit=$?"                # about 2 s, exit=137
   ```

6. A bridge that stops removes its shared containers:

   ```bash
   for i in 1 2; do
     (sleep 600 | docker run -i --rm -l containerstack.group=mcp-catalog busybox:1.37-musl \
        sh -c 'echo ready; sleep 1000' > /private/tmp/cs-live/s$i.out; echo "client $i exit=$?") &
   done
   # A session in `docker ps` does not mean that its shared container exists yet: wait for output.
   until [ "$(cat /private/tmp/cs-live/s*.out 2>/dev/null | grep -c ready)" = 2 ]; do sleep 1; done
   container list | grep cs-shared-mcp-catalog                               # one shared container
   kill -TERM "$bridge"; sleep 2                                              # client 1 and 2 exit=137
   container list --all | grep cs-shared || echo "no shared container"
   ```

   The bridge logs the time of the cleanup: `shared runtimes: shutdown: deleted 1 shared
   container(s) in N ms`, with "(limit reached, deletes still pending)" when the 400 ms passed first.

At the end, stop the second bridge (if check 6 did not) and put the file back:

```bash
kill "$bridge" 2>/dev/null
mv ~/.containerstack/runtime-groups.json.bak ~/.containerstack/runtime-groups.json 2>/dev/null
```

#!/bin/bash
# Live check of the two data-loss paths of a container create, on a test socket:
#   D-1: the create of a container with PGDATA on a volume that holds data and still has
#        /lost+found must keep the data;
#   D-2: the create of a second container on a volume that a running container holds must not
#        replace the volume image (the running container's writes must stay).
# Only throwaway objects (prefix vdl-) are made, and all of them are removed at the end.
# Usage: scripts/live-check-volume-data-loss.sh <socktainer binary> [work dir]
set -u
BRIDGE=${1:?usage: $0 <socktainer binary> [work dir]}
WORK=${2:-$(mktemp -d /tmp/vdl.XXXXXX)}
C=${C:-container}
IMG=${IMG:-busybox:1.37-musl}
SOCK=$WORK/docker.sock
mkdir -p "$WORK"
rm -f "$SOCK"
"$BRIDGE" --socket "$SOCK" --no-docker-context --no-auto-start --no-startup-housekeeping > "$WORK/bridge.txt" 2>&1 &
PID=$!
cleanup() {
    DOCKER_HOST=unix://$SOCK docker rm -f vdl-a vdl-b vdl-pg > /dev/null 2>&1
    "$C" delete --force vdl-fill > /dev/null 2>&1
    for v in vdl-d1 vdl-d2; do DOCKER_HOST=unix://$SOCK docker volume rm -f "$v" > /dev/null 2>&1; "$C" volume delete "$v" > /dev/null 2>&1; done
    kill "$PID" 2> /dev/null
    wait "$PID" 2> /dev/null
    rm -f "$SOCK"
}
trap cleanup EXIT
for _ in $(seq 1 60); do [ -S "$SOCK" ] && break; sleep 0.5; done
[ -S "$SOCK" ] || { echo "the bridge did not start; see $WORK/bridge.txt"; exit 2; }
export DOCKER_HOST=unix://$SOCK
result=0

# D-1. Data written outside the bridge keeps /lost+found next to it.
"$C" volume create vdl-d1 > /dev/null
"$C" run --rm --name vdl-fill -v vdl-d1:/data "$IMG" sh -c 'echo keep > /data/keep && sync' > /dev/null
"$C" run --rm -v vdl-d1:/data "$IMG" ls -a /data | tr '\n' ' ' | sed 's/^/D-1 before: /'; echo
docker create --name vdl-pg -e PGDATA=/var/lib/postgresql/data -v vdl-d1:/var/lib/postgresql/data "$IMG" true > /dev/null
docker rm -f vdl-pg > /dev/null
after=$("$C" run --rm -v vdl-d1:/data "$IMG" sh -c 'ls -a /data | tr "\n" " "; cat /data/keep 2>/dev/null')
echo "D-1 after: $after"
if echo "$after" | grep -q "keep$"; then echo "D-1 PASS: the data stayed"; else echo "D-1 FAIL: the volume's data was erased"; result=1; fi

# D-2. A second create on a volume that a running container holds.
docker volume create vdl-d2 > /dev/null
docker run -d --name vdl-a -v vdl-d2:/data "$IMG" sleep 3600 > /dev/null
docker create --name vdl-b -v vdl-d2:/etc "$IMG" true > "$WORK/create-b.txt" 2>&1
docker exec vdl-a sh -c 'echo important-data > /data/x && sync'
docker stop -t 1 vdl-a > /dev/null
after=$(docker run --rm -v vdl-d2:/data "$IMG" sh -c 'ls /data | tr "\n" " "; cat /data/x 2>/dev/null')
echo "D-2 after: $after"
if echo "$after" | grep -q "important-data$"; then echo "D-2 PASS: the running container's write stayed"; else echo "D-2 FAIL: the volume image was replaced under a running container"; result=1; fi
grep -h "volume-copyup\|volume-clean" "$WORK/bridge.txt" | sed 's/^/bridge: /' | cut -c1-200
exit $result

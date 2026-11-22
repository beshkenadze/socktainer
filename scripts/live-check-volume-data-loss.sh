#!/bin/bash
# Live check of the host-side volume image writes of a container create, through a socktainer
# binary on a private test socket.
#
#   C=<container CLI> scripts/live-check-volume-data-loss.sh <socktainer binary>
#
# Checks (each prints PASS or FAIL):
#   D-1        a Postgres create on a volume that holds data and /lost+found keeps the data;
#   D-2        a create on a volume that a running container uses keeps that container's writes;
#   copy-up    a new volume mounted over an image directory gets that directory's contents;
#   postgres   Postgres initialises on a new volume mounted at its PGDATA;
#   two-a      a plain service, then Postgres, created one after the other on one new volume:
#              Postgres initialises;
#   two-b      the same in the other order;
#   nocopy-v   `-v vol:/path:nocopy` starts, and the volume stays empty;
#   nocopy-m   `--mount ...,volume-nocopy=true` leaves the volume empty.
#
# Every object carries a random suffix and is recorded when it is made; the cleanup trap removes
# only recorded objects. Any failed setup step stops the run with status 2. Exit status: 0 when
# every check passed, 1 when one failed, 2 when the run could not complete.
# PG_IMAGE (default postgres:17-alpine) is pulled if it is not there.

set -u
BRIDGE=${1:?usage: C=<container CLI> $0 <socktainer binary>}
C=${C:-container}
IMG=${IMG:-busybox:1.37-musl}
PG_IMAGE=${PG_IMAGE:-postgres:17-alpine}
RUN=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/vdl-$RUN.XXXXXX") || exit 2
SOCK=$WORK/docker.sock
CONTAINERS=()
VOLUMES=()
RESULT=0
BRIDGE_PID=

cleanup() {
    local name
    for name in "${CONTAINERS[@]+"${CONTAINERS[@]}"}"; do
        docker rm -f -v "$name" >/dev/null 2>&1 || "$C" delete --force "$name" >/dev/null 2>&1
    done
    for name in "${VOLUMES[@]+"${VOLUMES[@]}"}"; do
        docker volume rm -f "$name" >/dev/null 2>&1 || "$C" volume delete "$name" >/dev/null 2>&1
    done
    [[ -n "$BRIDGE_PID" ]] && kill "$BRIDGE_PID" 2>/dev/null && wait "$BRIDGE_PID" 2>/dev/null
    rm -f -- "$SOCK"
    echo "bridge log: $WORK/bridge.txt"
}
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 2; }
result() { echo "$1: $2 - $3"; [[ "$2" == PASS ]] || RESULT=1; }
name() { printf 'vdl-%s-%s' "$RUN" "$1"; }

# Make a volume or a container and record it. Any failure stops the run.
cli_volume() { "$C" volume create "$1" >/dev/null || die "container volume create $1"; VOLUMES+=("$1"); }
docker_volume() { docker volume create "$1" >/dev/null || die "docker volume create $1"; VOLUMES+=("$1"); }
docker_create() { # name args...
    local n=$1
    shift
    docker create --name "$n" "$@" >/dev/null 2>"$WORK/$n.create.txt" || die "docker create $n: $(cat "$WORK/$n.create.txt")"
    CONTAINERS+=("$n")
}
docker_start() { docker start "$1" >/dev/null 2>&1 || die "docker start $1"; }
# The names in a volume's root, read with the runtime CLI.
volume_ls() { "$C" run --rm -v "$1:/v" "$IMG" ls -A /v 2>/dev/null | tr '\n' ' '; }
pg_ready() { # container: waits up to 90 s for Postgres to accept connections
    local i
    for i in $(seq 1 90); do
        docker logs "$1" 2>&1 | grep -q "database system is ready to accept connections" && return 0
        docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true || return 1
        sleep 1
    done
    return 1
}

for n in d1 d2 d2a d2b cu cuc pg pgc ta tap taa tb tbp tba ncv ncvc ncm ncmc; do
    "$C" list --all --quiet 2>/dev/null | grep -qix "$(name $n)" && die "$(name $n) exists"
    "$C" volume list --quiet 2>/dev/null | grep -qix "$(name $n)" && die "volume $(name $n) exists"
done
"$C" image inspect "$PG_IMAGE" >/dev/null 2>&1 || "$C" image pull "$PG_IMAGE" >/dev/null || die "cannot pull $PG_IMAGE"
"$C" image inspect "$IMG" >/dev/null 2>&1 || "$C" image pull "$IMG" >/dev/null || die "cannot pull $IMG"

"$BRIDGE" --socket "$SOCK" --no-docker-context --no-auto-start --no-startup-housekeeping >"$WORK/bridge.txt" 2>&1 &
BRIDGE_PID=$!
for _ in $(seq 1 60); do [[ -S "$SOCK" ]] && break; sleep 0.5; done
[[ -S "$SOCK" ]] || die "the bridge did not start; see $WORK/bridge.txt"
export DOCKER_HOST=unix://$SOCK
echo "run $RUN, bridge $BRIDGE, work $WORK"

# D-1: data written outside the bridge keeps /lost+found next to it.
v=$(name d1)
cli_volume "$v"
"$C" run --rm -v "$v:/v" "$IMG" sh -c 'echo keep > /v/keep && sync' >/dev/null 2>&1 || die "writing into $v"
docker_create "$(name d1)c" -e PGDATA=/var/lib/postgresql/data -v "$v:/var/lib/postgresql/data" "$IMG" true
after=$(volume_ls "$v")
[[ " $after" == *" keep "* ]] && result D-1 PASS "the data stayed ($after)" || result D-1 FAIL "the data was erased ($after)"

# D-2: a second create on a volume that a running container uses.
v=$(name d2)
docker_volume "$v"
docker_create "$(name d2a)" -v "$v:/data" "$IMG" sleep 600
docker_start "$(name d2a)"
docker_create "$(name d2b)" -v "$v:/etc" "$IMG" true
docker exec "$(name d2a)" sh -c 'echo important > /data/x && sync' || die "writing in $(name d2a)"
docker stop -t 1 "$(name d2a)" >/dev/null 2>&1 || die "docker stop $(name d2a)"
after=$(volume_ls "$v")
[[ " $after" == *" x "* ]] && result D-2 PASS "the running container's write stayed ($after)" ||
    result D-2 FAIL "the volume image was replaced under a running container ($after)"

# copy-up: a new volume over an image directory gets its contents.
v=$(name cu)
docker_volume "$v"
docker_create "$(name cuc)" -v "$v:/etc" "$IMG" true
after=$(volume_ls "$v")
[[ " $after" == *" passwd "* ]] && result copy-up PASS "the image's /etc arrived ($after)" || result copy-up FAIL "the volume holds: $after"

# postgres: initialises on a new volume at its PGDATA.
v=$(name pg)
docker_volume "$v"
docker_create "$(name pgc)" -e POSTGRES_PASSWORD=x -e PGDATA=/var/lib/postgresql/data -v "$v:/var/lib/postgresql/data" "$PG_IMAGE"
docker_start "$(name pgc)"
pg_ready "$(name pgc)" && result postgres PASS "initialised" ||
    result postgres FAIL "$(docker logs "$(name pgc)" 2>&1 | grep -iE "initdb|error|lost\+found" | head -2 | tr '\n' ' ')"
docker stop -t 5 "$(name pgc)" >/dev/null 2>&1

# two-a and two-b: two services on one new volume, created one after the other. The plain
# service mounts a path that its image does not have, so its copy-up brings nothing.
two() { # label first second
    local label=$1 first=$2 second=$3 vol pgname
    vol=$(name "$label")
    docker_volume "$vol"
    pgname=$(name "${label}p")
    for svc in "$first" "$second"; do
        if [[ "$svc" == postgres ]]; then
            docker_create "$pgname" -e POSTGRES_PASSWORD=x -e PGDATA=/var/lib/postgresql/data -v "$vol:/var/lib/postgresql/data" "$PG_IMAGE"
        else
            docker_create "$(name "${label}a")" -v "$vol:/no-such-dir" "$IMG" true
        fi
    done
    docker_start "$pgname"
    pg_ready "$pgname" && result "two-$label" PASS "$first then $second: Postgres initialised" ||
        result "two-$label" FAIL "$first then $second: $(docker logs "$pgname" 2>&1 | grep -iE "initdb|error|lost\+found" | head -2 | tr '\n' ' ')"
    docker stop -t 5 "$pgname" >/dev/null 2>&1
}
two ta plain postgres
two tb postgres plain

# nocopy, both forms.
v=$(name ncv)
docker_volume "$v"
if docker run --name "$(name ncvc)" -v "$v:/etc:nocopy" "$IMG" true >"$WORK/ncv.txt" 2>&1; then
    CONTAINERS+=("$(name ncvc)")
    after=$(volume_ls "$v")
    [[ " $after" != *" passwd "* ]] && result nocopy-v PASS "started, the volume holds: ${after:-nothing}" ||
        result nocopy-v FAIL "the image's /etc was copied in ($after)"
else
    CONTAINERS+=("$(name ncvc)")
    result nocopy-v FAIL "the container did not start: $(grep -o 'mount failed[^"]*' "$WORK/ncv.txt" | head -1)"
fi
v=$(name ncm)
docker_volume "$v"
docker_create "$(name ncmc)" --mount "type=volume,src=$v,dst=/etc,volume-nocopy=true" "$IMG" true
after=$(volume_ls "$v")
[[ " $after" != *" passwd "* ]] && result nocopy-m PASS "the volume holds: ${after:-nothing}" ||
    result nocopy-m FAIL "the image's /etc was copied in ($after)"

grep -h "volume-copyup\|volume-clean" "$WORK/bridge.txt" | sed 's/^/bridge: /' | cut -c1-220
exit $RESULT

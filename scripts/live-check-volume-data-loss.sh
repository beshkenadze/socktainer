#!/bin/bash
# Live check of the host-side volume image writes of a container create, through a socktainer
# binary on a private test socket.
#
#   C=<container CLI> scripts/live-check-volume-data-loss.sh <socktainer binary>
#
# For a host where nobody else creates containers or volumes whose names start with vdl- during
# the run: the script checks that its names are free before it starts and again right before
# each volume create, but a native `container` CLI actor that creates one of those names between
# that check and the create would have its object taken as the script's own, and removed.
#
# Checks (each prints PASS or FAIL):
#   D-1        a Postgres create on a volume that holds data and /lost+found keeps the data;
#   D-2        a create on a volume that a running container uses keeps that container's writes;
#   rejected   a Postgres create that the runtime rejects as a name conflict ("container already
#              exists: <name>") leaves the volume image unchanged;
#   copy-up    a new volume mounted over an image directory gets that directory's contents;
#   postgres   Postgres initialises on a new volume mounted at its PGDATA;
#   two-a      a plain service, then Postgres, created one after the other on one new volume;
#   two-b      the same in the other order;
#   holder     a create on a volume that a never-started container names: the create warns that the
#              volume was not prepared because another container names it, and the volume is
#              unchanged. On 166bbd5 this reports DIFFERS-BY-DESIGN (it prepared the volume).
#   nocopy-v   `-v vol:/path:nocopy` starts, and the volume does not get the image's directory;
#   nocopy-m   `--mount ...,volume-nocopy=true` does not get it either.
#
# Exit status: 0 when every check passed, 1 when one failed, 2 when the run could not complete.
# PG_IMAGE (default postgres:17-alpine) is pulled if it is not there.

set -u
unset DOCKER_CONTEXT DOCKER_HOST
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

d() { docker --host "unix://$SOCK" "$@"; }

cleanup() {
    local n
    for n in "${CONTAINERS[@]+"${CONTAINERS[@]}"}"; do
        d rm -f -v "$n" >/dev/null 2>&1 || "$C" delete --force "$n" >/dev/null 2>&1
    done
    for n in "${VOLUMES[@]+"${VOLUMES[@]}"}"; do
        d volume rm -f "$n" >/dev/null 2>&1 || "$C" volume delete "$n" >/dev/null 2>&1
    done
    [[ -n "$BRIDGE_PID" ]] && kill "$BRIDGE_PID" 2>/dev/null && wait "$BRIDGE_PID" 2>/dev/null
    rm -f -- "$SOCK"
    echo "bridge log: $WORK/bridge.txt"
}
trap cleanup EXIT
trap 'exit 2' INT TERM

die() { echo "ERROR: $*" >&2; exit 2; }
result() { echo "$1: $2 - $3"; [[ "$2" == PASS ]] || RESULT=1; }
name() { printf 'vdl-%s-%s' "$RUN" "$1"; }

# Every name this run uses. Checked before anything is made.
SUFFIXES=(d1 d1c d2 d2a d2b rj rjc rjh cu cuc pg pgc ta tap taa tb tbp tba ho hoh hop ncv ncvc ncm ncmc)
status="$("$C" system status 2>/dev/null)" || die "the container system does not answer"
ROOT="$(printf '%s\n' "$status" | awk '$1 == "paths.appRoot" { sub(/^[^ ]+ +/, ""); print }')"
ROOT="${ROOT%/}"
[[ -n "$ROOT" && -d "$ROOT" ]] || die "the daemon reports no usable app root"
listing="$("$C" list --all --format json)" || die "container list failed"
listing+="$("$C" volume list --format json)" || die "container volume list failed"
for s in "${SUFFIXES[@]}"; do
    n=$(name "$s")
    printf '%s' "$listing" | grep -qi -- "\"$n\"" && die "$n exists"
    [[ -e "$ROOT/containers/$n" || -e "$ROOT/volumes/$n" ]] && die "$n exists under $ROOT"
done

# Make an object and record it only when this run's own create made it. Any failure stops the run.
new_volume() { # name: created through the bridge; refused when the name exists right before
    d volume inspect "$1" >/dev/null 2>&1 && die "volume $1 appeared during the run"
    d volume create "$1" >/dev/null || die "docker volume create $1"
    VOLUMES+=("$1")
}
cli_volume() {
    "$C" volume create "$1" >/dev/null || die "container volume create $1"
    VOLUMES+=("$1")
}
new_container() { # name args... -> 0 when created, 1 when the create was refused
    local n=$1
    shift
    if d create --name "$n" "$@" >/dev/null 2>"$WORK/$n.create.txt"; then
        CONTAINERS+=("$n")
        return 0
    fi
    return 1
}
must_create() { new_container "$@" || die "docker create $1: $(cat "$WORK/$1.create.txt")"; }
must_start() { d start "$1" >/dev/null 2>&1 || die "docker start $1"; }
# A file's content in a volume, read with the runtime CLI. Prints nothing and fails when the
# read fails, so a check cannot pass on a failed read.
volume_cat() { "$C" run --rm -v "$1:/v" "$IMG" cat "/v/$2" 2>/dev/null; }
volume_has() { "$C" run --rm -v "$1:/v" "$IMG" test -e "/v/$2" 2>/dev/null; }
volume_lacks() { "$C" run --rm -v "$1:/v" "$IMG" sh -c "ls -A /v >/dev/null && test ! -e /v/$2" 2>/dev/null; }
pg_initialised() { # container: true once the final server (not the init server) accepts connections
    local i
    for i in $(seq 1 120); do
        if d logs "$1" 2>&1 | grep -q "PostgreSQL init process complete" && d exec "$1" pg_isready -q 2>/dev/null; then
            return 0
        fi
        d inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true || return 1
        sleep 1
    done
    return 1
}
pg_why() { d logs "$1" 2>&1 | grep -iE "initdb|error|lost\+found|not empty" | head -2 | tr '\n' ' '; }

"$C" image inspect "$PG_IMAGE" >/dev/null 2>&1 || "$C" image pull "$PG_IMAGE" >/dev/null || die "cannot pull $PG_IMAGE"
"$C" image inspect "$IMG" >/dev/null 2>&1 || "$C" image pull "$IMG" >/dev/null || die "cannot pull $IMG"

"$BRIDGE" --socket "$SOCK" --no-docker-context --no-auto-start --no-startup-housekeeping >"$WORK/bridge.txt" 2>&1 &
BRIDGE_PID=$!
for _ in $(seq 1 60); do [[ -S "$SOCK" ]] && break; sleep 0.5; done
[[ -S "$SOCK" ]] || die "the bridge did not start; see $WORK/bridge.txt"
echo "run $RUN, bridge $BRIDGE, root $ROOT, work $WORK"
PG=(-e POSTGRES_PASSWORD=x -e PGDATA=/var/lib/postgresql/data)

# D-1: data written outside the bridge keeps /lost+found next to it.
v=$(name d1)
cli_volume "$v"
"$C" run --rm -v "$v:/v" "$IMG" sh -c 'echo keep > /v/keep && sync' >/dev/null 2>&1 || die "writing into $v"
must_create "$(name d1c)" -e PGDATA=/var/lib/postgresql/data -v "$v:/var/lib/postgresql/data" "$IMG" true
[[ "$(volume_cat "$v" keep)" == keep ]] && result D-1 PASS "the data stayed" || result D-1 FAIL "the data was erased"

# D-2: a second create on a volume that a running container uses.
v=$(name d2)
new_volume "$v"
must_create "$(name d2a)" -v "$v:/data" "$IMG" sleep 600
must_start "$(name d2a)"
must_create "$(name d2b)" -v "$v:/etc" "$IMG" true
d exec "$(name d2a)" sh -c 'echo important > /data/x && sync' || die "writing in $(name d2a)"
d stop -t 1 "$(name d2a)" >/dev/null 2>&1 || die "docker stop $(name d2a)"
[[ "$(volume_cat "$v" x)" == important ]] && result D-2 PASS "the running container's write stayed" ||
    result D-2 FAIL "the volume image was replaced under a running container"

# rejected: a create that the runtime refuses (its name is taken) changes no volume.
v=$(name rj)
new_volume "$v"
image="$ROOT/volumes/$v/volume.img"
must_create "$(name rjh)" "$IMG" true
# The image's identity (inode, size, modification time) and its first 64 MiB, which hold the
# superblock, the group descriptors and the root directory. Hashing all of a sparse 512 GiB image
# would take hours; a replacement changes the inode anyway.
# An image's identity and the hash of its first 64 MiB. Fails when any read fails.
fingerprint() {
    local meta sum
    meta=$(stat -f '%i %z %m' "$1") || return 1
    sum=$(set -o pipefail; head -c $((64 * 1024 * 1024)) "$1" | shasum) || return 1
    printf '%s %s\n' "$meta" "${sum%% *}"
}
before=$(fingerprint "$image") || die "cannot read $image"
if new_container "$(name rjh)" "${PG[@]}" -v "$v:/var/lib/postgresql/data" "$PG_IMAGE"; then
    result rejected FAIL "the duplicate create was accepted"
elif ! grep -qF "container already exists: $(name rjh)" "$WORK/$(name rjh).create.txt"; then
    result rejected FAIL "the create failed, but not on the name conflict: $(head -c 200 "$WORK/$(name rjh).create.txt")"
else
    after=$(fingerprint "$image") || die "cannot read $image"
    [[ "$before" == "$after" ]] && result rejected PASS "refused as a name conflict; the image is unchanged" ||
        result rejected FAIL "the rejected create changed the image"
fi

# copy-up: a new volume over an image directory gets its contents.
v=$(name cu)
new_volume "$v"
must_create "$(name cuc)" -v "$v:/etc" "$IMG" true
volume_has "$v" passwd && result copy-up PASS "the image's /etc arrived" || result copy-up FAIL "the volume lacks /etc/passwd"

# postgres: initialises on a new volume at its PGDATA.
v=$(name pg)
new_volume "$v"
must_create "$(name pgc)" "${PG[@]}" -v "$v:/var/lib/postgresql/data" "$PG_IMAGE"
must_start "$(name pgc)"
pg_initialised "$(name pgc)" && result postgres PASS "initialised" || result postgres FAIL "$(pg_why "$(name pgc)")"
d stop -t 5 "$(name pgc)" >/dev/null 2>&1

# two-a and two-b: two services on one new volume, created one after the other. The plain
# service mounts a path that its image does not have, so its copy-up brings nothing.
two() { # label first second
    local label=$1 first=$2 second=$3 vol pgname svc
    vol=$(name "$label")
    new_volume "$vol"
    pgname=$(name "${label}p")
    for svc in "$first" "$second"; do
        if [[ "$svc" == postgres ]]; then
            must_create "$pgname" "${PG[@]}" -v "$vol:/var/lib/postgresql/data" "$PG_IMAGE"
        else
            must_create "$(name "${label}a")" -v "$vol:/no-such-dir" "$IMG" true
        fi
    done
    must_start "$pgname"
    pg_initialised "$pgname" && result "two-$label" PASS "$first then $second: initialised" ||
        result "two-$label" FAIL "$first then $second: $(pg_why "$pgname")"
    d stop -t 5 "$pgname" >/dev/null 2>&1
}
two ta plain postgres
two tb postgres plain

# holder: a never-started container made with the runtime CLI names a new volume.
v=$(name ho)
cli_volume "$v"
"$C" create --name "$(name hoh)" -v "$v:/data" "$IMG" true >/dev/null 2>&1 || die "container create $(name hoh)"
CONTAINERS+=("$(name hoh)")
image="$ROOT/volumes/$v/volume.img"
before=$(fingerprint "$image") || die "cannot read $image"
must_create "$(name hop)" "${PG[@]}" -v "$v:/var/lib/postgresql/data" "$PG_IMAGE"
after=$(fingerprint "$image") || die "cannot read $image"
if grep -q "volume \"$v\" was not prepared (another container names it" "$WORK/$(name hop).create.txt" && [[ "$before" == "$after" ]]; then
    result holder PASS "the create warned that another container names the volume, and the volume is unchanged"
elif [[ "$before" != "$after" ]]; then
    RESULT=1
    echo "holder: DIFFERS-BY-DESIGN - the volume was prepared although another container names it (166bbd5 behaviour)"
else
    result holder FAIL "the volume is unchanged but the create gave no holder warning: $(head -c 300 "$WORK/$(name hop).create.txt")"
fi

# nocopy, both forms.
v=$(name ncv)
new_volume "$v"
must_create "$(name ncvc)" -v "$v:/etc:nocopy" "$IMG" true
if d start -a "$(name ncvc)" >"$WORK/ncv.txt" 2>&1; then
    volume_lacks "$v" passwd && result nocopy-v PASS "started; the volume has no /etc/passwd" ||
        result nocopy-v FAIL "the image's /etc was copied in, or the volume could not be read"
else
    result nocopy-v FAIL "the container did not start: $(grep -o 'mount failed[^"]*' "$WORK/ncv.txt" | head -1)"
fi
v=$(name ncm)
new_volume "$v"
must_create "$(name ncmc)" --mount "type=volume,src=$v,dst=/etc,volume-nocopy=true" "$IMG" true
volume_lacks "$v" passwd && result nocopy-m PASS "the volume has no /etc/passwd" ||
    result nocopy-m FAIL "the image's /etc was copied in, or the volume could not be read"

grep -h "volume-prepare\|volume-copyup\|volume-clean" "$WORK/bridge.txt" | sed 's/^/bridge: /' | cut -c1-220
exit $RESULT

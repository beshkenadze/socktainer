#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mode=${1:-test}
[[ "$mode" == build || "$mode" == test ]] || { echo 'usage: build.sh [build|test]' >&2; exit 125; }
# Same pinned Rust/Alpine builder as dns-forwarder. No image builder or runtime
# lifecycle commands: compilation and tests run in one disposable container.
image=public.ecr.aws/docker/library/rust:1-alpine3.24@sha256:f87aa870663e2b57ec8c69de82c7eedf7383bee987eef7612c0359635eaadb41
name="cs-session-test-${mode}-$$"
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
docker run --rm --name "$name" --platform linux/arm64 \
    -v "$PWD:/work" -w /work -e "CS_SESSION_BUILD_MODE=$mode" "$image" sh -ec '
    apk add --no-cache musl-dev binutils
    rustc --version
    cargo build --locked --release --target aarch64-unknown-linux-musl
    binary=target/aarch64-unknown-linux-musl/release/cs-session
    if [ "$CS_SESSION_BUILD_MODE" = test ]; then
        cargo build --locked --release --example fixture --target aarch64-unknown-linux-musl
        cargo test --locked --release --target aarch64-unknown-linux-musl -- --test-threads=1
    fi
    readelf -h "$binary"
    if readelf -l "$binary" | grep -q INTERP; then
        echo "binary has a dynamic interpreter" >&2; exit 1
    fi
    if readelf -d "$binary" | grep -q NEEDED; then
        echo "binary has dynamic dependencies" >&2; exit 1
    fi
    mkdir -p dist/linux-arm64
    cp "$binary" dist/linux-arm64/cs-session
    sha256sum dist/linux-arm64/cs-session
'

#!/usr/bin/env bash
# Sourced by spawn.sh and worker-resume.sh, before a worker starts (RUNID and ISSUE set).
#
# Every worker shares one on-disk package cache: per-issue uv/pnpm caches under /tmp exhaust
# its inodes and then the quota, taking every other worker down with them. The cache is the
# kit's own dir, not uv's or pnpm's default, so a worker's install can never write into the
# host's own cache. It overrides a cache the host session set: that one is neither a codex
# writable root nor ours to write. (`--env UV_CACHE_DIR=…` is exported later and still wins.)
ORCH_CACHE_ROOT="${HOME:-/nonexistent}/.cache/orchestrate"
export UV_CACHE_DIR="$ORCH_CACHE_ROOT/uv"
export npm_config_store_dir="$ORCH_CACHE_ROOT/pnpm-store"
mkdir -p "$ORCH_CACHE_ROOT" 2>/dev/null || :
# Everything the worker starts inherits this tag, so reap.sh can find a backgrounded build
# that outlived the worker's process group.
export ORCH_WORKER="$RUNID/$ISSUE"

# A codex workspace-write sandbox can write only its worktree and the listed roots, so the
# shared cache has to be one of them: `cache_root_into '<toml array>'` appends it.
cache_root_into() { printf '%s' "${1%]},\"$ORCH_CACHE_ROOT\"]"; }

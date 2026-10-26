#!/usr/bin/env bash
# Sourced by spawn.sh and worker-resume.sh, before a worker starts (RUNID and ISSUE set).
#
# Every worker shares one on-disk package cache: per-issue uv/pnpm caches under /tmp exhaust
# its inodes and then the quota, taking every other worker down with them. A cache the
# machine already chose is kept.
export UV_CACHE_DIR="${UV_CACHE_DIR:-${HOME:-/nonexistent}/.cache/uv}"
export npm_config_store_dir="${npm_config_store_dir:-${HOME:-/nonexistent}/.cache/pnpm-store}"
# Everything the worker starts inherits this tag, so reap.sh can find a backgrounded build
# that outlived the worker's process group.
export ORCH_WORKER="$RUNID/$ISSUE"

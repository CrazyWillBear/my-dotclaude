#!/usr/bin/env bash
# One script, not two copies: spawn.sh and worker-resume.sh must refuse exactly the same
# inputs, and no error message may quote an environment value.

set -uo pipefail

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

for pair in "$@"; do
    case "$pair" in
        *=*) ;;
        *) die "--env expects NAME=VALUE (an argument had no '=')" ;;
    esac

    name="${pair%%=*}"
    case "$name" in
        ''|[0-9]*|*[!A-Za-z0-9_]*) die "--env name '$name' is not a valid variable name" ;;
    esac
done

#!/usr/bin/env bash
#
# dedup-search — zero-dependency (ripgrep-only) candidate table for duplicate code.
#
# Usage: dedup-search.sh <repo-path> <term> [term ...]
#
# Emits a raw candidate table to stdout.  Every row names a match by file:line
# and a short context snippet.  Output is always filtered to the supplied terms —
# never an unfiltered dump.
#
# Search angles covered:
#   1. keyword    — case-insensitive literal grep of each term in all text files
#   2. file-loc   — files whose path contains any term (case-insensitive)
#   3. literal    — quoted string / constant containing any term
#   4. dep-check  — import / require / dependency reference to any term
#   5. def        — function/class/variable definition (per-language regex cheat-sheet
#                   covering Python, TS/JS, and Shell)
#
# Each output row format (tab-separated):
#   <angle>	<file>:<line>	<snippet>
#
# Design notes:
#   * Fail open: any rg invocation error is silently skipped so a missing file or
#     binary match never crashes the helper.
#   * ripgrep handles binary detection, .gitignore, and hidden-file skipping by
#     default; we rely on those defaults.
#   * The def-regex cheat-sheet is intentionally minimal — enough to surface
#     function/class/variable definitions without false-positive noise.
#   * Duplicate rows (same angle+file+line) are de-duped before output.
#   * The Python inline process drives the rg invocations and de-duplication so the
#     shell wrapper stays thin and portable.

set -u

command -v rg >/dev/null 2>&1 || { printf 'error: ripgrep (rg) is required\n' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf 'error: python3 is required\n' >&2; exit 1; }

if [ $# -lt 2 ]; then
    printf 'usage: dedup-search.sh <repo-path> <term> [term ...]\n' >&2
    exit 1
fi

# Pass repo and terms via environment so the heredoc needn't handle quoting.
export DEDUP_REPO="$1"; shift
export DEDUP_TERMS
DEDUP_TERMS="$(printf '%s\n' "$@")"

python3 <<"PY"
import os, subprocess, sys

repo  = os.environ["DEDUP_REPO"]
terms = [t for t in os.environ["DEDUP_TERMS"].splitlines() if t]

# ---------------------------------------------------------------------------
# Per-language definition regex cheat-sheet (applied to source files only).
# ---------------------------------------------------------------------------
DEF_PATTERNS = [
    # Python: def name(  or  class Name
    r"^[[:space:]]*(def|class)[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*",
    # Python: CONSTANT = ...
    r"^[[:space:]]*[A-Z_][A-Z0-9_]+[[:space:]]*=",
    # TS/JS: function/const/let/var/class name  (with optional export/async)
    r"^[[:space:]]*(export[[:space:]]+)?(default[[:space:]]+)?(async[[:space:]]+)?(function|const|let|var|class)[[:space:]]+[a-zA-Z_$][a-zA-Z0-9_$]*",
    # Shell: name()  or  function name
    r"^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*\(\)",
    r"^[[:space:]]*function[[:space:]]+[a-zA-Z_][a-zA-Z0-9_-]+",
]

# Dependency/import patterns (angle 4).
DEP_PATTERN = r"^\s*(import|from|require|use|extern crate|#include)\b"

# ---------------------------------------------------------------------------
# Helper: run rg and return stdout lines (empty list on any error).
# ---------------------------------------------------------------------------
def rg(*args):
    cmd = ["rg", "--no-heading", "--with-filename", "--line-number",
           "--color=never"] + list(args) + [repo]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode not in (0, 1):   # 1 = no match; anything else = error
            return []
        return [l for l in result.stdout.splitlines() if l]
    except Exception:
        return []

# ---------------------------------------------------------------------------
# Parse "file:line:text" rows emitted by rg --no-heading.
# rg uses the first colon after the filename (Windows paths may have drive
# letters, but this repo targets Linux/macOS so simple split is fine).
# ---------------------------------------------------------------------------
def parse_rows(lines, angle):
    rows = []
    for line in lines:
        # Split on first two colons only.
        parts = line.split(":", 2)
        if len(parts) < 3:
            continue
        fpath, lineno, snippet = parts
        snippet = snippet.strip()
        rows.append((angle, fpath, lineno, snippet))
    return rows

# ---------------------------------------------------------------------------
# Collect results (de-duped by (angle, file, lineno)).
# ---------------------------------------------------------------------------
seen   = set()
output = []

def emit(angle, fpath, lineno, snippet):
    key = (angle, fpath, lineno)
    if key in seen:
        return
    seen.add(key)
    output.append((angle, fpath, lineno, snippet))

# ---------------------------------------------------------------------------
# Angle 1 — keyword: case-insensitive search for each term.
# ---------------------------------------------------------------------------
for term in terms:
    for angle, fpath, lineno, snippet in parse_rows(
        rg("--ignore-case", "-e", term), "keyword"
    ):
        emit(angle, fpath, lineno, snippet)

# ---------------------------------------------------------------------------
# Angle 2 — file-loc: files whose path contains any term (case-insensitive).
# rg --files + --glob: emit a synthetic row at line 1.
# ---------------------------------------------------------------------------
for term in terms:
    cmd = ["rg", "--files", "--iglob", f"*{term}*", repo]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True)
        for fpath in result.stdout.splitlines():
            if fpath:
                emit("file-loc", fpath, "1", f"(path matches: {term})")
    except Exception:
        pass

# ---------------------------------------------------------------------------
# Angle 3 — literal: term appearing inside quotes or as an ALL_CAPS constant.
# We build one rg call per term with a pattern that requires the term inside
# single or double quotes.
# ---------------------------------------------------------------------------
for term in terms:
    qt_rows = rg(
        "--ignore-case",
        "-e", f'"[^"]*{term}[^"]*"',
        "-e", f"'[^']*{term}[^']*'",
    )
    for angle, fpath, lineno, snippet in parse_rows(qt_rows, "literal"):
        emit(angle, fpath, lineno, snippet)

# ---------------------------------------------------------------------------
# Angle 4 — dep-check: import/require/use/from lines that mention any term.
# ---------------------------------------------------------------------------
dep_lines = rg("--ignore-case", "-e", DEP_PATTERN)
for term in terms:
    term_lower = term.lower()
    for line in dep_lines:
        if term_lower in line.lower():
            for angle, fpath, lineno, snippet in parse_rows([line], "dep"):
                emit(angle, fpath, lineno, snippet)

# ---------------------------------------------------------------------------
# Angle 5 — def: per-language definition patterns, filtered to lines
# containing any term (case-insensitive).
# ---------------------------------------------------------------------------
for pat in DEF_PATTERNS:
    def_lines = rg("-e", pat)
    for term in terms:
        term_lower = term.lower()
        for line in def_lines:
            if term_lower in line.lower():
                for angle, fpath, lineno, snippet in parse_rows([line], "def"):
                    emit(angle, fpath, lineno, snippet)

# ---------------------------------------------------------------------------
# Emit de-duped output.
# ---------------------------------------------------------------------------
for angle, fpath, lineno, snippet in output:
    print(f"{angle}\t{fpath}:{lineno}\t{snippet}")
PY

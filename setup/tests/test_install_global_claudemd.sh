#!/usr/bin/env bash
#
# Tests for tcr_install_global_claudemd in setup/lib/common.sh.
#
# Black-box: we source the library with a controlled HOME and a local repo root,
# drive tcr_install_global_claudemd directly, and assert on the dest file + output.
# The terminal prompt is redirected to a fixture file via $TCR_TTY so the tests
# stay non-interactive.
#
# Covers:
#   * no existing CLAUDE.md            -> writes it, no prompt.
#   * existing + TCR_FORCE=1           -> replaces, backup kept, no prompt.
#   * existing + reply "y"             -> replaces, backup kept.
#   * existing + reply "n"             -> keeps theirs, prints source URL, backup made? no.
#   * existing + no readable tty       -> keeps theirs, prints source URL (non-interactive).
#
# Run: bash setup/tests/test_install_global_claudemd.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$SETUP_DIR/.." && pwd)"
COMMON="$SETUP_DIR/lib/common.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_file_contains() { if grep -q "$3" "$2" 2>/dev/null; then ok "$1"; else no "$1 (file missing: $3)"; fi; }

REAL_BASH="$(command -v bash)"

# run_install <home> <tty-file-or-empty> <force> — source common.sh from the real
# repo root (so it copies the local global/CLAUDE.md) and call the function with a
# controlled HOME. tty-file, when given, is fed as $TCR_TTY (the "terminal").
run_install() {
  local home="$1" ttyfile="$2" force="$3"
  HOME="$home" TCR_LOCAL_ROOT="$ROOT" TCR_TTY="$ttyfile" TCR_FORCE="$force" \
    NO_COLOR=1 "$REAL_BASH" -c "
      export HOME TCR_LOCAL_ROOT TCR_TTY TCR_FORCE NO_COLOR
      . '$COMMON'
      tcr_install_global_claudemd
    " 2>&1
}

# ---- test: no existing CLAUDE.md -> writes it -------------------------------
echo "test: no existing CLAUDE.md -> writes it, no prompt"
H="$WORK/h1"; mkdir -p "$H/.claude"
out=$(run_install "$H" "/nonexistent/tty" "0")
assert_contains "reports wrote" "$out" "wrote $H/.claude/CLAUDE.md"
assert_file_contains "dest has kit content" "$H/.claude/CLAUDE.md" "Definition of done"

# ---- test: existing + TCR_FORCE=1 -> replace, backup kept -------------------
echo "test: existing + --force -> replaces, backup kept, no prompt"
H="$WORK/h2"; mkdir -p "$H/.claude"
printf 'MY OWN RULES\n' > "$H/.claude/CLAUDE.md"
out=$(run_install "$H" "/nonexistent/tty" "1")
assert_contains "reports backup"  "$out" "backed up $H/.claude/CLAUDE.md"
assert_contains "reports wrote"   "$out" "wrote $H/.claude/CLAUDE.md"
assert_file_contains "dest replaced with kit" "$H/.claude/CLAUDE.md" "Definition of done"
bak=$(ls "$H/.claude/"CLAUDE.md.bak.* 2>/dev/null | head -1)
assert_file_contains "backup holds the original" "$bak" "MY OWN RULES"

# ---- test: existing + reply "y" -> replace ---------------------------------
echo "test: existing + tty reply 'y' -> replaces, backup kept"
H="$WORK/h3"; mkdir -p "$H/.claude"
printf 'MY OWN RULES\n' > "$H/.claude/CLAUDE.md"
printf 'y\n' > "$WORK/tty_y"
out=$(run_install "$H" "$WORK/tty_y" "0")
assert_contains "reports wrote" "$out" "wrote $H/.claude/CLAUDE.md"
assert_file_contains "dest replaced with kit" "$H/.claude/CLAUDE.md" "Definition of done"

# ---- test: existing + reply "n" -> keep theirs, print URL ------------------
echo "test: existing + tty reply 'n' -> keeps theirs, prints source URL"
H="$WORK/h4"; mkdir -p "$H/.claude"
printf 'MY OWN RULES\n' > "$H/.claude/CLAUDE.md"
printf 'n\n' > "$WORK/tty_n"
out=$(run_install "$H" "$WORK/tty_n" "0")
assert_contains "kept message" "$out" "kept your existing"
assert_contains "prints source URL" "$out" "global/CLAUDE.md"
assert_file_contains "dest untouched" "$H/.claude/CLAUDE.md" "MY OWN RULES"
assert_not_contains "did not write kit" "$(cat "$H/.claude/CLAUDE.md")" "Definition of done"

# ---- test: existing + no readable tty -> keep theirs (non-interactive) -----
echo "test: existing + no readable tty -> keeps theirs, prints source URL"
H="$WORK/h5"; mkdir -p "$H/.claude"
printf 'MY OWN RULES\n' > "$H/.claude/CLAUDE.md"
out=$(run_install "$H" "/nonexistent/tty" "0")
assert_contains "kept message" "$out" "kept your existing"
assert_file_contains "dest untouched" "$H/.claude/CLAUDE.md" "MY OWN RULES"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

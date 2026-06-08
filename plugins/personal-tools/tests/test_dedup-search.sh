#!/usr/bin/env bash
#
# Tests for scripts/dedup-search.sh — the zero-dep ripgrep-only candidate table.
#
# Black-box: we plant fixture files in a mktemp workdir, run the helper, and
# assert that candidate rows naming the correct file:line appear in the output.
#
# Covers:
#   * keyword search finds a planted duplicate function name
#   * literal search finds a planted quoted string constant
#   * dep search finds a planted import/dependency line
#   * def search finds planted definitions in Python, TS/JS, and Shell fixtures
#   * output is filtered — an unrelated planted symbol does NOT appear
#   * the helper exits non-zero and prints usage on bad args
#
# Run: bash plugins/personal-tools/tests/test_dedup-search.sh  (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$PLUGIN_ROOT/scripts/dedup-search.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Ensure rg is available.  Under bash (the documented run mode for test_*.sh
# files in this repo), rg may only be accessible as a Claude Code shell
# function.  We resolve it here and create a tiny shim in $WORK/bin so that
# child bash processes spawned by the helper can find it.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/bin"
_setup_rg_shim() {
    # 1. Already a real binary on PATH?
    local real
    real="$(type -P rg 2>/dev/null || true)"
    if [ -n "$real" ] && [ -f "$real" ]; then
        ln -sf "$real" "$WORK/bin/rg"
        return 0
    fi
    # 2. Claude Code embeds rg; CLAUDE_CODE_EXECPATH or the well-known default.
    local cc="${CLAUDE_CODE_EXECPATH:-}"
    if [ -z "$cc" ] || [ ! -x "$cc" ]; then
        cc="$HOME/.local/bin/claude"
    fi
    if [ -x "$cc" ]; then
        printf '#!/usr/bin/env bash\nexec -a rg "%s" "$@"\n' "$cc" > "$WORK/bin/rg"
        chmod +x "$WORK/bin/rg"
        return 0
    fi
    # 3. Give up — test will skip below.
    return 1
}

if ! _setup_rg_shim; then
    printf 'SKIP: could not locate rg or the claude binary; install ripgrep to run these tests.\n'
    exit 0
fi
export PATH="$WORK/bin:$PATH"

# Quick sanity — does rg actually work?
if ! rg --version >/dev/null 2>&1; then
    printf 'SKIP: rg shim does not appear to work.\n'
    exit 0
fi

# ---------------------------------------------------------------------------
# Fixture repo: planted duplicate function, literal, dep, and per-language defs.
# The "unrelated" symbol must NOT appear in search results for our terms.
# ---------------------------------------------------------------------------
REPO="$WORK/fixture"
mkdir -p "$REPO/src"

# Python fixture — planted definition + constant + import + unrelated symbol
cat > "$REPO/src/math_utils.py" <<'PYEOF'
import requests

DISCOUNT_RATE = 0.15

def calculate_total(items):
    """Return the sum of items."""
    return sum(items)

def _unrelated_zebra_func():
    return 42
PYEOF

# TS/JS fixture — planted function definition + quoted literal + import
cat > "$REPO/src/formatter.ts" <<'TSEOF'
import { calculate_total } from "./math_utils";

const DEFAULT_LABEL = "calculate_total result";

export function formatResult(value: number): string {
    return `Result: ${value}`;
}

const _ZEBRA_UNRELATED = "zebra_symbol_xyz";
TSEOF

# Shell fixture — planted function definition + dependency line
cat > "$REPO/src/run.sh" <<'SHEOF'
#!/usr/bin/env bash
# requires: requests

calculate_total() {
    local sum=0
    for n in "$@"; do sum=$((sum + n)); done
    printf '%d\n' "$sum"
}

_zebra_unrelated_func() {
    echo noop
}
SHEOF

# ---------------------------------------------------------------------------
# Pass / fail counters and assertion helpers (match existing test conventions).
# ---------------------------------------------------------------------------
pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) no "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }
assert_empty()        { if [ -z "$2" ]; then ok "$1"; else no "$1 (expected empty, got: $2)"; fi; }

run_helper() {
    bash "$HELPER" "$@"
}

# ---------------------------------------------------------------------------
echo "test: keyword search finds the planted duplicate function name"
out=$(run_helper "$REPO" calculate_total)
assert_contains "keyword row mentions calculate_total" "$out" "calculate_total"
# At least one row should identify a file:line reference
assert_contains "output includes a file:line reference" "$out" "math_utils.py"

# ---------------------------------------------------------------------------
echo "test: literal search finds the planted quoted constant string"
out=$(run_helper "$REPO" calculate_total)
assert_contains "literal row for the quoted constant" "$out" "literal"
assert_contains "literal row names formatter.ts" "$out" "formatter.ts"

# ---------------------------------------------------------------------------
echo "test: dep search finds the planted import/dependency reference"
out=$(run_helper "$REPO" requests)
assert_contains "dep row for python import" "$out" "dep"
assert_contains "dep row names math_utils.py" "$out" "math_utils.py"

# ---------------------------------------------------------------------------
echo "test: def search finds planted Python definition"
out=$(run_helper "$REPO" calculate_total)
assert_contains "def row present for Python" "$out" "def"
assert_contains "def row names math_utils.py" "$out" "math_utils.py"

# ---------------------------------------------------------------------------
echo "test: def search finds planted TS/JS definition"
out=$(run_helper "$REPO" formatResult)
assert_contains "def row for TS function" "$out" "def"
assert_contains "def row names formatter.ts" "$out" "formatter.ts"

# ---------------------------------------------------------------------------
echo "test: def search finds planted Shell function definition"
out=$(run_helper "$REPO" calculate_total)
assert_contains "def row for shell function" "$out" "def"
assert_contains "def row names run.sh" "$out" "run.sh"

# ---------------------------------------------------------------------------
echo "test: output is filtered — unrelated planted symbol does not appear"
out=$(run_helper "$REPO" calculate_total)
assert_not_contains "zebra_symbol_xyz not in output" "$out" "zebra_symbol_xyz"
assert_not_contains "zebra_unrelated not in output" "$out" "_zebra_unrelated"

# ---------------------------------------------------------------------------
echo "test: searching for an unrelated term that matches only the unrelated symbol"
out=$(run_helper "$REPO" zebra_symbol_xyz)
assert_contains "targeted search can find the unrelated constant itself" "$out" "zebra_symbol_xyz"

# ---------------------------------------------------------------------------
echo "test: bad args (no terms) exits non-zero and prints usage"
run_helper "$REPO" 2>"$WORK/err.txt"; rc=$?
if [ "$rc" -ne 0 ]; then ok "no-terms exits non-zero"; else no "no-terms should exit non-zero"; fi

# ---------------------------------------------------------------------------
echo "test: each angle tag appears at least once in a multi-angle search"
out=$(run_helper "$REPO" calculate_total requests)
assert_contains "keyword angle tag present" "$out" "keyword"
assert_contains "dep angle tag present" "$out" "dep"
assert_contains "def angle tag present" "$out" "def"

# ---------------------------------------------------------------------------
# ctags engine tests
# ---------------------------------------------------------------------------
# We need a stub ctags that emits realistic -x output for the fixture repo.
# The stub ignores all real arguments and prints a fixed xref table that
# names symbols from the fixture files planted above.
#
# ctags -x column layout: name  kind  line  file  context
# ---------------------------------------------------------------------------

# Resolve the real bash binary so we can inject it into synthetic PATHs.
REAL_BASH_DS="$(command -v bash)"

# Build a combined bin dir that has rg, python3, and bash — the minimum a
# child process needs to run the helper.  (The ctags test also adds ctags.)
mkdir -p "$WORK/full_bin"
ln -sf "$REAL_BASH_DS" "$WORK/full_bin/bash"
# Symlink python3 if available (the helper requires it).
_py3="$(command -v python3 2>/dev/null || true)"
[ -n "$_py3" ] && ln -sf "$_py3" "$WORK/full_bin/python3"
# Re-use the rg shim already placed in $WORK/bin.
ln -sf "$(readlink -f "$WORK/bin/rg")" "$WORK/full_bin/rg" 2>/dev/null \
    || cp "$WORK/bin/rg" "$WORK/full_bin/rg"

mkdir -p "$WORK/ctags_bin"

# Write the stub using shell variables already expanded — the here-doc is
# NOT quoted so $REPO expands now, giving the stub hard-coded absolute paths.
cat > "$WORK/ctags_bin/ctags" <<CTAGS_STUB
#!/usr/bin/env bash
# Stub ctags: ignores args, emits a fixed -x xref table for the fixture repo.
printf '%s\n' \\
  'calculate_total  function  4  ${REPO}/src/math_utils.py  def calculate_total(items):' \\
  'DISCOUNT_RATE  variable  3  ${REPO}/src/math_utils.py  DISCOUNT_RATE = 0.15' \\
  'formatResult  function  5  ${REPO}/src/formatter.ts  export function formatResult(value: number): string {' \\
  'DEFAULT_LABEL  constant  3  ${REPO}/src/formatter.ts  const DEFAULT_LABEL = "calculate_total result";' \\
  'calculate_total  function  7  ${REPO}/src/run.sh  calculate_total() {' \\
  '_zebra_unrelated_func  function  13  ${REPO}/src/run.sh  _zebra_unrelated_func() {'
CTAGS_STUB
chmod +x "$WORK/ctags_bin/ctags"

# Helper that runs the helper under a controlled PATH.
# Usage: run_helper_path <path> <repo> <term ...>
run_helper_path() {
    local p="$1"; shift
    PATH="$p" "$REAL_BASH_DS" "$HELPER" "$@"
}

# ---------------------------------------------------------------------------
echo "test (ctags present): ctags-sym rows contain name, file:line, and signature"
CTAGS_PATH="$WORK/ctags_bin:$WORK/full_bin"
out=$(run_helper_path "$CTAGS_PATH" "$REPO" calculate_total)
assert_contains "ctags-sym angle tag present" "$out" "ctags-sym"
assert_contains "ctags-sym row names calculate_total" "$out" "calculate_total"
# Row must contain a file:line reference (colon between path and line number)
assert_contains "ctags-sym row contains file:line" "$out" "math_utils.py:"
# Row must contain the signature/context
assert_contains "ctags-sym row contains kind" "$out" "function"

# ---------------------------------------------------------------------------
echo "test (ctags present): ctags output filtered — unrelated symbol absent"
out=$(run_helper_path "$CTAGS_PATH" "$REPO" calculate_total)
assert_not_contains "zebra symbol absent when searching calculate_total" "$out" "_zebra_unrelated_func"

# ---------------------------------------------------------------------------
echo "test (ctags present): ctags-sym row for TS function"
out=$(run_helper_path "$CTAGS_PATH" "$REPO" formatResult)
assert_contains "ctags-sym row for formatResult" "$out" "ctags-sym"
assert_contains "ctags-sym row names formatter.ts" "$out" "formatter.ts"
assert_contains "ctags-sym row contains formatResult" "$out" "formatResult"

# ---------------------------------------------------------------------------
echo "test (ctags present): def angle absent — ctags-sym supersedes it"
out=$(run_helper_path "$CTAGS_PATH" "$REPO" calculate_total)
# The def angle tag should NOT appear when ctags is present.
assert_not_contains "def angle absent when ctags present" "$out" "	def	"

# ---------------------------------------------------------------------------
echo "test (ctags absent): graceful degradation — falls back to ripgrep def-search"
# Use a PATH that has rg, python3, and bash but NO ctags.
NOCT_PATH="$WORK/full_bin"
out=$(run_helper_path "$NOCT_PATH" "$REPO" calculate_total)
# With ctags absent the def angle must fire and find the planted definitions.
assert_contains "fallback def row for Python" "$out" "def"
assert_contains "fallback def names math_utils.py" "$out" "math_utils.py"
assert_contains "fallback def names run.sh" "$out" "run.sh"
# And ctags-sym must NOT appear.
assert_not_contains "ctags-sym absent without ctags" "$out" "ctags-sym"

# ---------------------------------------------------------------------------
echo "test (ctags absent): fallback still finds planted Shell definition"
out=$(run_helper_path "$NOCT_PATH" "$REPO" calculate_total)
assert_contains "shell def row present in fallback" "$out" "def"
assert_contains "fallback finds run.sh shell def" "$out" "run.sh"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

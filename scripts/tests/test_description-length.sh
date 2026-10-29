#!/usr/bin/env bash
#
# Repo-wide invariant: every skill and agent description is at most 400 characters.
#
# Descriptions are loaded into EVERY session that has the kit installed, whether or not the
# skill is used; the old 1,413-character /orchestrate description cost every session in the
# kit its full length on every request. 400 keeps a description a trigger, not a manual.
#
# Run: bash scripts/tests/test_description-length.sh   (non-zero if any fail)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MAX=400

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }

echo "test: every skill and agent description is <= $MAX characters"
scanned=0
for f in "$REPO_ROOT"/plugins/*/skills/*/SKILL.md "$REPO_ROOT"/plugins/*/agents/*.md; do
    [ -f "$f" ] || continue
    scanned=$((scanned + 1))
    name="${f#"$REPO_ROOT"/}"
    # The first description: line inside the frontmatter block.
    desc="$(awk '/^---$/{n++; next} n==1 && /^description:/{sub(/^description: */,""); print; exit}' "$f")"
    if [ -z "$desc" ]; then
        no "$name has no description"
    elif [ "${#desc}" -gt "$MAX" ]; then
        no "$name description is ${#desc} chars (max $MAX)"
    else
        ok "$name (${#desc})"
    fi
done

# Without this the whole suite passes vacuously if the glob ever stops matching.
echo "test: the scan actually looked at something"
if [ "$scanned" -ge 10 ]; then ok "scanned $scanned files"; else no "scanned only $scanned files"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

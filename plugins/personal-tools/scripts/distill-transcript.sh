#!/usr/bin/env bash
#
# Distil a Claude Code session transcript down to the conversation itself.
#
#   distill-transcript.sh <transcript.jsonl> [out.md]
#
# Prints `turns=<n> bytes=<n> src_bytes=<n> out=<path>`; writes the markdown to
# [out.md], defaulting to a temp file keyed by the transcript's basename.
#
# WHY. A transcript is mostly not conversation. Measured on a real design session:
# 1.71 MB raw, of which ~336 KB thinking, ~265 KB tool results, ~137 KB tool-call
# parameters and ~190 KB harness bookkeeping (attachments, mode/system entries) —
# leaving ~138 KB of actual dialogue. Anything that reads a transcript to answer
# "what did they decide" pays 12x for evidence it does not need, and a long design
# session blows a size cap precisely when the check matters most.
#
# WHAT IT KEEPS. Every non-blank `text` block (and bare-string content) from every
# `user` / `assistant` entry, in order, labelled by role. Nothing else. The
# contract that matters is that NO spoken turn is dropped: a verifier that silently
# never read a decision, then reports ALIGNED, is worse than no verifier.
#
# WHY THINKING IS DROPPED — deliberate, not an oversight, even though it is the
# single largest category. It is reasoning the user never saw, and it contains
# positions worked through and discarded before speaking. Feeding it to a
# decisions-verifier invites mismatches against things that were never decided.
# The spoken text is the record.
#
# Fails loud: a missing argument or unreadable file exits non-zero. A malformed
# JSONL line is skipped (transcripts can be truncated mid-write), never fatal.

set -u

die() { printf 'distill-transcript: %s\n' "$1" >&2; exit 1; }

[ "$#" -ge 1 ] || die "usage: distill-transcript.sh <transcript.jsonl> [out.md]"
src="$1"
[ -r "$src" ] || die "cannot read transcript: $src"

if [ "$#" -ge 2 ]; then
    out="$2"
else
    out="${TMPDIR:-/tmp}/distilled-$(basename "$src" .jsonl).md"
fi

command -v python3 >/dev/null 2>&1 || die "python3 is required"

SRC="$src" OUT="$out" python3 <<'PY'
import json, os, sys

src, out = os.environ["SRC"], os.environ["OUT"]


def texts(content):
    """Every text block in a content field, whichever shape it takes."""
    if isinstance(content, str):
        return [content]
    if isinstance(content, list):
        return [b.get("text", "") for b in content
                if isinstance(b, dict) and b.get("type") == "text"]
    return []


turns = 0
try:
    with open(src, errors="replace") as fh, open(out, "w") as w:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except Exception:
                continue                      # truncated / malformed line: skip, never fatal
            role = entry.get("type")
            if role not in ("user", "assistant"):
                continue                      # system, attachment, mode, bookkeeping
            msg = entry.get("message")
            if not isinstance(msg, dict):
                continue
            body = "\n".join(t for t in texts(msg.get("content")) if t.strip())
            if not body.strip():
                continue                      # tool-result-only turn: no conversation
            turns += 1
            w.write("\n\n=== %s ===\n%s\n" % (role.upper(), body.rstrip()))
except OSError as e:
    sys.stderr.write("distill-transcript: %s\n" % e)
    sys.exit(1)

print("turns=%d bytes=%d src_bytes=%d out=%s"
      % (turns, os.path.getsize(out), os.path.getsize(src), out))
PY

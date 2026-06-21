#!/usr/bin/env python3
"""my-dotclaude default statusline (dev install).

Claude Code runs this on every status refresh, piping a JSON blob on stdin
(model, workspace, cost, context_window, ...). We print ONE line:

    <model> · <tokens>/<cost> · <dir> · ⎇ <branch> · +a/-r · <style> · <caveman> · <update>

Design notes:
  * No network, no transcript parsing. Token usage comes straight from the
    stdin `context_window` object (Claude Code >= 2.1.132). The "update
    available" flag is read from the cache the personal-tools SessionStart
    notifier already maintains (`~/.cache/my-dotclaude/last-check.json`).
  * Output is rendered straight into the terminal on every refresh, so EVERY
    segment is passed through `_clean()` (strips C0/C1 control chars + DEL)
    before it is joined into the line — no matter its source. This is the
    catch-all that neutralizes terminal-escape injection from any field,
    including ones outside our control: the working directory (a dir name can
    legally contain a raw ESC byte), the git branch name, and the model /
    output-style names that arrive on stdin.
  * The two user-space files (caveman flag, update cache) get extra defenses
    on top: refuse symlinks, cap bytes, and only ever emit derived/whitelisted
    text (mode whitelist, a static update badge) — never the raw file bytes.
  * Fail open: any unexpected error prints nothing rather than spamming the
    status line with a traceback.
"""

import json
import os
import re
import subprocess
import sys

SEP = " \033[2m·\033[0m "  # dim middle dot between segments
CAVEMAN_MODES = {
    "off", "lite", "full", "ultra",
    "wenyan-lite", "wenyan", "wenyan-full", "wenyan-ultra",
    "commit", "review", "compress",
}
# C0 + C1 control chars and DEL — stripped from every rendered segment so no
# field (cwd, branch, model, ...) can smuggle a terminal-escape sequence.
_CTRL = re.compile(r"[\x00-\x1f\x7f-\x9f]")


def _clean(s):
    return _CTRL.sub("", s)


def _config_dir():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(
        os.path.expanduser("~"), ".claude"
    )


def _cache_dir():
    return os.environ.get("XDG_CACHE_HOME") or os.path.join(
        os.path.expanduser("~"), ".cache"
    )


def _read_safe(path, limit):
    """Read at most `limit` bytes from a regular file, refusing symlinks.

    Returns "" on anything unexpected (missing, symlink, unreadable). The
    caller is responsible for sanitizing the returned text before display.
    """
    try:
        if os.path.islink(path) or not os.path.isfile(path):
            return ""
        with open(path, "rb") as fh:
            raw = fh.read(limit)
        return raw.decode("utf-8", "ignore")
    except OSError:
        return ""


def seg_dir(data):
    cwd = (data.get("workspace") or {}).get("current_dir") or data.get("cwd") or ""
    if not cwd:
        return ""
    home = os.environ.get("HOME") or os.path.expanduser("~")
    if home and (cwd == home or cwd.startswith(home + "/")):
        cwd = "~" + cwd[len(home):]
    return cwd


def seg_branch(data):
    cwd = (data.get("workspace") or {}).get("current_dir") or data.get("cwd") or ""
    if not cwd or not os.path.isdir(cwd):
        return ""
    try:
        out = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True, timeout=1,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    if out.returncode != 0:
        return ""
    branch = out.stdout.strip()
    if not branch:
        return ""
    if branch == "HEAD":  # detached — show short sha instead
        try:
            sha = subprocess.run(
                ["git", "-C", cwd, "rev-parse", "--short", "HEAD"],
                capture_output=True, text=True, timeout=1,
            )
            branch = sha.stdout.strip() or "HEAD"
        except (OSError, subprocess.SubprocessError):
            branch = "HEAD"
    return "⎇ " + branch


def seg_model(data):
    model = data.get("model")
    if isinstance(model, dict):
        return model.get("display_name") or model.get("id") or ""
    if isinstance(model, str):
        return model
    return ""


def _fmt_tokens(n):
    try:
        n = int(n)
    except (TypeError, ValueError):
        return "0k"
    if n >= 1000:
        return "%dk" % round(n / 1000)
    return str(n)


def seg_tokens(data):
    cw = data.get("context_window") or {}
    if "total_input_tokens" in cw:
        return _fmt_tokens(cw["total_input_tokens"])
    return "0k"  # missing (older Claude Code, or before the first API response)


def seg_cost(data):
    cost = data.get("cost") or {}
    try:
        usd = float(cost.get("total_cost_usd", 0) or 0)
    except (TypeError, ValueError):
        usd = 0.0
    return "$%.2f" % usd


def seg_meters(data):
    # tokens-in-context and session cost, shown as one "47k / $0.42" segment.
    return seg_tokens(data) + " / " + seg_cost(data)


def seg_lines(data):
    cost = data.get("cost") or {}
    try:
        added = int(cost.get("total_lines_added", 0) or 0)
        removed = int(cost.get("total_lines_removed", 0) or 0)
    except (TypeError, ValueError):
        added = removed = 0
    return "+%d/-%d" % (added, removed)


def seg_style(data):
    name = (data.get("output_style") or {}).get("name") or ""
    if name and name != "default":
        return name
    return ""


def seg_caveman():
    flag = os.path.join(_config_dir(), ".caveman-active")
    raw = _read_safe(flag, 64)
    mode = re.sub(r"[^a-z0-9-]", "", raw.strip().lower())
    if not mode or mode == "off" or mode not in CAVEMAN_MODES:
        return ""
    return "caveman" if mode == "full" else "caveman:" + mode


def seg_update():
    cache = os.path.join(_cache_dir(), "my-dotclaude", "last-check.json")
    text = _read_safe(cache, 256)
    if "available" in text and "/update-kit" in text:
        return "⬆ update"  # static badge — never echo the file contents
    return ""


def main():
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
        if not isinstance(data, dict):
            data = {}
    except (ValueError, OSError):
        data = {}

    segments = [
        seg_model(data),
        seg_meters(data),   # tokens / cost
        seg_dir(data),
        seg_branch(data),
        seg_lines(data),    # diff churn
        seg_style(data),    # only when non-default
        seg_caveman(),
        seg_update(),
    ]
    line = SEP.join(_clean(s) for s in segments if s)
    sys.stdout.write(line)


if __name__ == "__main__":
    try:
        main()
    except Exception:  # fail open — a broken statusline must not spew errors
        pass

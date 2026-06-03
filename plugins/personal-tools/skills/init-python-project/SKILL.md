---
name: init-python-project
description: Scaffold the working docs for a Python project — drops a filled CLAUDE.md, STYLEGUIDE.md, and a Python .gitignore into the target dir, wired for a uv + ruff + mypy + pytest toolchain. Minimal by design (no pyproject/venv). Use for "start a new python project", "initialize/scaffold a python repo", "set up python project docs".
argument-hint: "[project dir or name; defaults to current dir]"
allowed-tools: Read, Write, Edit, Bash, Glob
---

Scaffold the working docs for a Python project into the target directory. This is the
**minimal** scaffold: the two project docs plus a `.gitignore`. No `pyproject.toml`, no
virtualenv, no `git init` — those are left to the user (see the closing note).

Toolchain the docs are wired for: **uv + ruff + mypy + pytest**.

## Steps

1. **Resolve the target dir** from `$ARGUMENTS`:
   - If it names an existing directory (or `.`/empty), use it.
   - If it names a path that doesn't exist, confirm with me before creating it, then
     `mkdir -p` it.
   - If empty, use the current directory.

2. **Read the base templates** (do not edit them in place):
   - `${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.md`
   - `${CLAUDE_PLUGIN_ROOT}/templates/STYLEGUIDE.md`

3. **Produce the filled docs** by applying the substitutions below and **stripping** two
   kinds of scaffolding lines from each file: the top `<!-- … -->` HTML comment, and the
   `> Fill in the <...> …` / `> Language-neutral defaults. Adapt the <...> …` note line.
   The result must contain **no `<...>` placeholders**.

   **`CLAUDE.md`** — the Definition-of-done code block:
   ```
   <test command>          # e.g. npm test / pytest / go test ./...
   <lint command>          # e.g. eslint . / ruff check . / golangci-lint run
   <typecheck command>     # e.g. tsc --noEmit / mypy . (delete if not applicable)
   ```
   becomes (drop the `# e.g.` comments):
   ```
   uv run pytest
   uv run ruff check .
   uv run mypy .
   ```

   **`STYLEGUIDE.md`**:
   - `<lint command>`   → `uv run ruff check .`
   - `<test framework>` → `pytest`
   - `<test command>`   → `uv run pytest`

4. **Write the two filled docs** to the target dir as `CLAUDE.md` and `STYLEGUIDE.md`.
   If either already exists, **show me the diff and ask before overwriting** — never
   clobber silently.

5. **Write `.gitignore`** in the target dir with the set below. If a `.gitignore` already
   exists, **append only the lines it's missing** (use Edit) — don't duplicate entries or
   replace the file.
   ```
   # Python
   __pycache__/
   *.py[cod]
   .venv/
   *.egg-info/
   build/
   dist/
   # Tooling caches
   .mypy_cache/
   .ruff_cache/
   .pytest_cache/
   ```

6. **Report** what you wrote (paths), then note that this is the minimal scaffold: the
   `uv run …` commands in the docs need a `pyproject.toml` and an environment before they
   run — e.g. `uv init` followed by `uv add --dev ruff mypy pytest`. Leave that to me.

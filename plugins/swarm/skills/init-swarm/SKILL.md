---
name: init-swarm
description: Scaffold a project's swarm roster — asks which of the three default roles (orchestrator, swe-manager, performance-engineer) the project wants, then writes .claude/swarm/roster.json, charter.md, and one brief per chosen role from the plugin's templates. Use for "/init-swarm", "set up swarm roles", "initialize the swarm roster".
argument-hint: ""
allowed-tools: Read, Write, Bash, Glob, AskUserQuestion
---

Scaffold `.claude/swarm/` for the current project: a roster of peer roles, the shared
charter, one brief per role chosen, and the vault-scoped memory tree. This implements
`docs/swarm-design.md` § Roster / § Roles shipped in v1 / § Charter / § Memory tiers.
It does **not** spawn anything — `swarm.sh up|down|attach` (the piece that actually
starts peers) is a later issue; this command only writes the roster, the charter, the
briefs, and memory.

## Steps

1. **Confirm a git repo.** `.claude/swarm/` is project-local state, same as
   `.claude/swarm/roster.json` and the rest of the swarm tree. If the current
   directory is not inside a git repo, say so in one line and stop.

2. **Ask which roles to install**, with `AskUserQuestion` (`multiSelect: true` — a
   project keeps only the roles it wants, and there is no "recommended" default to
   fall back on, so confirm the exact set before writing anything):
   - **orchestrator** — Will's session: briefs peers, verifies their claims, relays
     to Will, merges once reviewed, keeps `shared/` memory.
   - **swe-manager** — owns code: turns work into GitHub issues, then
     `/orchestrate --issues`. Never merges, never touches prod.
   - **performance-engineer** — measures and root-causes performance on demand.

3. **Read the shipped templates** from the plugin root (do not edit them in place):
   - `${CLAUDE_PLUGIN_ROOT}/templates/roster.json` — all three rows, keyed by role name.
   - `${CLAUDE_PLUGIN_ROOT}/templates/charter.md`
   - `${CLAUDE_PLUGIN_ROOT}/templates/briefs/<role>.md` — one per role.

4. **Check for existing state before writing anything.** If any of
   `.claude/swarm/roster.json`, `.claude/swarm/charter.md`, or a chosen role's
   `.claude/swarm/inbox/<role>/brief.md` already exists, show me the diff between it
   and what Steps 5–7 would write, and ask before overwriting — never clobber silently,
   same precedent as init-python-project's SKILL.md. A file with no conflict (doesn't
   exist yet) is written straight through.

5. **Write `.claude/swarm/roster.json`**: only the rows for the chosen roles, pulled
   verbatim from `templates/roster.json` — never all three unless all three were
   chosen, and never a row invented rather than copied.

6. **Write `.claude/swarm/charter.md`**: the template, verbatim, unconditionally — it
   is shared by every role, so it is written even if only one role was chosen.

7. **Write one brief per chosen role**, and only for chosen roles, to
   `.claude/swarm/inbox/<role>/brief.md` (create the `inbox/<role>/` directory) —
   the matching `templates/briefs/<role>.md`, verbatim. An unchosen role gets no
   brief and no inbox directory.

8. **Scaffold `.claude/swarm/memory/`** from the roster you just wrote
   (`docs/swarm-design.md` § Memory tiers) — this is the real central mechanism, never
   hand-invent the policy file yourself:
   - Check `command -v vault`. **If found**, run it for real, literally:
     `vault init --layout swarm --roster .claude/swarm/roster.json --vault .claude/swarm/memory`.
     This creates `shared/`, plus `roles/<role>/` and `proposals/<role>/` for every
     chosen role whose `kind` is `manager` or `doer` (orchestrator needs none of its
     own — its policy rule already covers the whole tree), plus
     `.claude/swarm/memory/.vault-policy.json`.
   - **If not found**, print one line — `vault not on PATH — wrote the plain directory
     layout, no policy file (install wilcus-vault to add scoping)` — and create the
     same directories yourself with `mkdir -p`: `.claude/swarm/memory/shared/`, plus
     `.claude/swarm/memory/roles/<role>/` and `.claude/swarm/memory/proposals/<role>/`
     for every chosen role whose `kind` is `manager` or `doer`. No policy file — only
     vault generates one.

9. **Validate before reporting done.** Run the plugin's own roster validator —
   literally `bash "${CLAUDE_PLUGIN_ROOT}/scripts/roster.sh" validate` — against the
   project directory you just wrote to. If it fails, fix the roster and re-run it —
   never report success on a roster you have not validated through the real script.

10. **Report** the files and memory layout written, which roles were installed, and
    whether vault ran or the plain fallback did. Note that `swarm.sh up`/`down`/`attach`
    (spawning these roles) ships in a later issue.

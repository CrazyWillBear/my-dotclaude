---
name: init-swarm
description: Scaffold a project's swarm roster — asks which of the three default roles (orchestrator, swe-manager, performance-engineer) the project wants, then writes .claude/swarm/roster.json, charter.md, and one brief per chosen role from the plugin's templates. Use for "/init-swarm", "set up swarm roles", "initialize the swarm roster".
argument-hint: ""
allowed-tools: Read, Write, Bash, Glob, AskUserQuestion
---

Scaffold `.claude/swarm/` for the current project: a roster of peer roles, the shared
charter, and one brief per role chosen. This implements
`docs/swarm-design.md` § Roster / § Roles shipped in v1 / § Charter. It does **not**
spawn anything — `swarm.sh up|down|attach` (the piece that actually starts peers) is a
later issue; this command only writes the roster, the charter, and the briefs.

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

4. **Write `.claude/swarm/roster.json`**: only the rows for the chosen roles, pulled
   verbatim from `templates/roster.json` — never all three unless all three were
   chosen, and never a row invented rather than copied.

5. **Write `.claude/swarm/charter.md`**: the template, verbatim, unconditionally — it
   is shared by every role, so it is written even if only one role was chosen.

6. **Write one brief per chosen role**, and only for chosen roles, to
   `.claude/swarm/inbox/<role>/brief.md` (create the `inbox/<role>/` directory) —
   the matching `templates/briefs/<role>.md`, verbatim. An unchosen role gets no
   brief and no inbox directory.

7. **Validate before reporting done.** Run the plugin's own
   `scripts/roster.sh validate` against the project directory you just wrote to. If
   it fails, fix the roster and re-run it — never report success on a roster you
   have not validated through the real script.

8. **Report** the files written and which roles were installed. Note that
   `swarm.sh up`/`down`/`attach` (spawning these roles) ships in a later issue.

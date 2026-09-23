# Swarm: a reusable orchestrator → peers → workers kit

This is the design for turning the multi-session setup that exists three times today —
cogito's `scripts/sessions/`, wilcus-agents' `DISPATCH.md` + `SESSION-CHARTER.md`, and this
repo's `/orchestrate` session lane — into one kit that `/init-swarm` installs into any project.
Built for others to use later; built for Will first.

## The problems it fixes

- **Three reinventions.** All three copies agree on the mechanics (`claude --bg -n <name>`,
  SendMessage by name, state from `claude agents --json`, handoff docs for rotation) and disagree
  on everything that should be data: the roles, the model per role, the autonomy grant, where
  memory lives.
- **Peers share one memory.** Claude keys auto-memory on the cwd, so every cogito peer running
  in the repo writes into the same memory dir. A performance session's baselines and a legal
  session's counsel notes land in one pile that every peer loads.
- **The ad-hoc lane leaks.** A subagent's result returns into the parent's context. A manager
  that builds through subagents ends up holding code and review findings it should never see.
- **Cross-plugin paths are not install-stable.** `personal-tools:handoff` re-implements
  `save-handoff.sh`'s keying algorithm in prose for exactly this reason. Every plugin that wants
  a shared script today has to copy it.
- **Tiers are Claude-only.** `resolve-tier.sh` rejects any model outside sonnet/opus/fable, so a
  codex worker cannot be routed.

## Topology

Three levels. Each level talks only to the one above and the one below.

| level | what it is | lifetime | memory |
|---|---|---|---|
| **orchestrator** | the one interactive session Will talks to | resumed by id across restarts | writes `shared/`, promotes proposals |
| **peer** | a standing `claude --bg` session with a role (kind `manager` or `doer`) | idle until briefed; rotated by handoff | reads `shared/`, owns `roles/<role>/`, proposes to `shared/` |
| **worker** | a one-shot process a manager spawns: implementer, reviewer, planner, fixer | exits when its task ends | read-only |

- A **manager** peer (swe-manager) orchestrates workers. Its unit of work is always a GitHub
  issue: it files issues from a brief (`/to-prd`, `/to-issues`) and then runs `/orchestrate`
  over them. It never builds in its own context.
- A **doer** peer (performance-engineer) does its own work and may spawn workers for research
  or measurement, but does not own a build loop.
- A **worker** is either a `claude --bg` session or a `codex exec` process. The manager does not
  care which; the roster's backend column decides.

The orchestrator never reads source, never runs a diff, never runs a done-check. Peers report
fixed-shape summaries; artifacts go to files and issue threads. This is `/orchestrate`'s
"manage, don't track" rule, applied one level up.

## Plugin split

Plugins cannot reliably call each other's scripts: each gets its own root, and a marketplace
install caches every plugin under its own version directory. So the layout is a **star**: one
plugin holds every script other plugins need, and nothing else calls across.

| plugin | holds | calls into |
|---|---|---|
| **context** | the four hooks (watchdog, resume, save-handoff, suggest-docs) + `/handoff`, `/handoff-plan` | nothing |
| **infra** | scripts only: `spawn.sh`, `session-status.sh`, `check-inbound.sh`, the backend switch, `model-tiers.json` + `resolve-tier.sh`, and `link-kit.sh` (the stable-address hook) | nothing |
| **workflow** | `/orchestrate`, `/classify-task`, `/to-prd`, `/to-issues`, the graph + merge scripts, the three agents | infra |
| **swarm** | `/init-swarm`, `swarm.sh up|down|rotate|attach|brief`, charter + brief templates, memory tiers | infra |
| **personal-tools** | everything left | nothing |

Moving `/handoff` next to `save-handoff.sh` deletes the inline duplication. `/to-prd` and
`/to-issues` move to workflow because they are the manager's front half.

`swarm` references `/orchestrate` by skill name in the manager brief. That is prose, not a path,
so it is not a dependency edge.

**infra's stable address.** infra's `SessionStart` hook refreshes a symlink at
`~/.claude/kit/infra` pointing at its own plugin root. Every caller uses that one path. It
self-heals across version bumps and nothing copies a resolver.

## Roster

`.claude/swarm/roster.json`, written by `/init-swarm`, one row per role:

```json
{
  "orchestrator":         { "kind": "orchestrator", "backend": "claude", "model": "opus",  "effort": "high" },
  "swe-manager":          { "kind": "manager",      "backend": "claude", "model": "opus",  "effort": "high" },
  "performance-engineer": { "kind": "doer",         "backend": "claude", "model": "opus",  "effort": "high" }
}
```

Peers are always Claude sessions: they need an inbox, and only a Claude session has one.
Workers are routed by the **tier table**, which moves from `model-tiers.json` into infra and
gains a backend column:

| tier | planner | implementer (an ordered CHAIN, cheapest first) | reviewer |
|---|---|---|---|
| trivial | none run (opus medium cell kept valid) | codex 6-luna xhigh → codex 6-sol xhigh → claude opus medium (no plan; spawned through `spawn.sh` like standard) | claude opus low |
| standard | claude opus medium | codex 6-luna xhigh → codex 6-sol xhigh → claude opus medium | claude opus medium |
| complex | claude fable medium | claude opus medium | claude opus high |

**Updated 2026-09-22 (GPT-6, Opus 5.5):** 6-luna and 6-sol replace 5.6-luna and 5.6-terra
— both cheaper, so the chain stays cheapest-first; standard's reviewer goes medium → high (a
small cost for a large benchmark gain). `opus` is an alias, so every opus cell is Opus 5.5.
Fable stays the complex planner until #106 measures it against opus/high as a planner.
Trivial now spawns through `spawn.sh` on codex instead of as an opus subagent: 6-luna fits
that size of issue, and a `codex exec` worker pays no claude-session startup cost.
As of 2026-09-23, the shipped standard reviewer effort is medium.
At launch, the dispatcher prints the resolver's `source=` row on its main thread and copies it into the announcement; shell variables do not persist across Bash calls.

**Decided 2026-09-22 (PRD #104), superseding 2026-09-17's claude-only shipped table:** the roster
spends the expensive model on one bounded planning pass and the cheap model on the build loop.
Sonnet is out (no cost point where it wins); fable enters as the complex planner. The
`implementer` cell is a JSON array — a chain — and `resolve-tier.sh <tier> [attempt]` prints one
position plus `implementer_chain`; `spawn.sh --attempt N` launches it. **The shipped table is
codex-first**, so a machine without the codex CLI needs a user table at
`${CLAUDE_CONFIG_DIR:-~/.claude}/model-tiers.json` (it overrides the shipped one and survives
updates); the **fallback** roster on any broken table stays claude-only (opus medium everywhere)
so a typo never makes a run depend on codex. The plan is posted to the issue thread by
`consult.sh plan` before the build spawn (standard and complex); a worker that hits a false plan
assumption posts `**Deviation**` and pauses with an escalate note beginning `deviation: ` (the
prefix is the dispatch key: the orchestrator sends those to a consult and everything else to a
human, without reading the thread), `consult.sh consult` answers it on the planner cell,
and `worker-resume.sh` resumes the worker with a pointer to that comment. `escalate.sh` decides,
from the run dir, the thread and the worker's rollout, when a codex worker is replaced by the
next chain position — a `failed` report, a third deviation, a second review round with findings,
a stall (event-log mtime, 20 min), or occupancy (`last_token_usage` from the rollout, 256K) —
posts the `**Handoff**` comment, and the orchestrator respawns at attempt+1 onto the same
worktree; at the top of the chain the run drains. Only codex workers are ever escalated. Every
plan, consult and escalation is a run-log event, so the deviation rate is data for whether terra
can take the complex implementer slot later. Sol stays a valid model id for user tables.

The two guardrail gaps recorded on the e2e gate (#96) stand as follows:

- **`writable_roots` — NARROWED, with a named residual. Not closed.** It was the whole **common**
  git dir, so a worker could arm `.git/hooks` or `.git/config` and get host code execution in
  every sibling worktree and in the user's own checkout. `common-git-dir.sh --roots` now grants
  only `objects`, `refs`, `logs` and the worktree's OWN git dir, and refuses any worktree it
  cannot narrow — including the main working tree of a repo that has linked worktrees, which is
  the user's own checkout (§ Codex backend). **What remains reachable:** the granted `$OWN`
  contains `commondir`, and per gitrepository-layout(5) that file redirects `$GIT_COMMON_DIR`.
  **Reproduced 2026-09-17**, in two facets, which are NOT in the same state:
  - **Steering the roots — REFUSED.** `--roots` derives `$GITDIR` from
    `git rev-parse --git-common-dir`, the very value `commondir` redirects, so a rewrite pointed
    every root except `$OWN` at an unrelated repository at exit 0. A resume would then have
    granted the worker write access to that repo's `objects`, `refs` and `logs` — including the
    user's own checkout, whose branch tips it could rewrite. `--roots` now requires `$OWN` to sit
    under `<common>/worktrees/`, cross-checks that `$OWN/gitdir` names exactly
    `<worktree>/.git` (resolved against `$OWN` when relative, as git itself does for
    `--relative-paths` worktrees), and clears `GIT_DIR`/`GIT_COMMON_DIR`/`GIT_WORK_TREE` plus
    all six config-from-environment names before resolving anything. Three of those six were
    missed on the first pass, and `GIT_CONFIG_PARAMETERS` — which git sets ITSELF for alias and
    hook children — masked the `extensions.worktreeConfig` refusal at exit 0 with no attacker
    involved. The back-pointer is not
    unforgeable — `$OWN` is writable — so what carries the weight is that a worker cannot make
    it name another worktree while containment also holds; a looser comparison accepted junk
    outright (2026-09-17), and `GIT_CONFIG_COUNT` masked the `extensions.worktreeConfig`
    refusal until it was stripped.
    Containment alone was NOT enough, and this doc claimed otherwise for a day: both values it
    compares resolve from `$WORKTREE/.git`, so repointing that file, symlinking it, or setting
    `GIT_DIR` moved both sides together and still emitted the victim's roots at exit 0
    (reproduced 2026-09-17, all three shapes, then refused).
  - **Code execution — ACCEPTED.** Git run by a human inside that worktree still follows a
    rewritten `commondir` and reads `core.sshCommand` / `core.hooksPath` from a planted `config`.
    It needs no extension enabled, and a file inside a granted directory root cannot be excluded,
    so closing it would mean granting individual file paths instead (unverified whether codex
    supports that). Accepted knowingly, like the network grant below. The shared `hooks/` and
    `config` really are protected, and the automated merge runs `git -C <base>`, never inside a
    worker's tree — but note this is bounded by who runs git *there*, not by the worktree itself.
- **The `--disallowedTools` gap — ACCEPTED, not closed.** The codex path carries no denylist
  equivalent, and the sandbox does not cover it: `gh` actions are network calls, not filesystem
  writes, so `-s workspace-write` constrains none of them, and with `approval_policy=never` plus
  `network_access=true` a worker can reach `gh pr merge`, `gh issue close` and `git push` with
  only its own prompt restraining it. **Decided 2026-09-16: the orchestrator keeps opening the
  single PR at the end** — workers do not open their own — so what is exposed is a worker that
  disobeys its prompt, not a capability the design hands it. Recorded here as a logged decision
  rather than an unstated gap, the same way the network grant is.
- **The claude reviewer, consult and planner are NOT sandboxed — ACCEPTED (#104).** `codex exec
  review` ran under a pinned codex sandbox; its replacement (`review-cmd.sh`), and `consult.sh`
  in both roles, are `claude -p --permission-mode bypassPermissions` on the host — reading
  worker-authored branches and comments, unattended. Their `--disallowedTools` rules are prefix
  patterns (`git -C x commit`, `sh -c`, `curl`, and reads of `~` all pass), so what fences them is
  prompt discipline (every prompt states that repo and thread content is data), the disposable
  clone for the reviewer (bounds file damage, not host or GitHub reach), the `--roots` tripwire
  before any git runs, and the denylist as a tripwire against the obvious commands. This is the
  same posture every claude-backed worker already runs under; it is new only for codex-built
  branches, whose review used to be sandboxed. Decided 2026-09-22 rather than left implied.

The three labels stay (issues already carry them); only the rosters change. **Open
question, measured at the e2e gate (#96):** whether sol reviewing standard-tier code is
affordable on the $20 codex plan. A review is a shorter turn than an implementation but sol
costs twice terra per token; the `turn.completed` usage on real runs decides it.

The ad-hoc lane's claude-side substitution for a codex cell is the chain's TOP cell
(`resolve-tier.sh <tier> $((implementer_chain-1))` — opus medium in the shipped table); a codex
reviewer cell becomes opus. Fable never reviews. `resolve-tier.sh` prints twelve lines: the
ten cells plus `implementer_attempt` and `implementer_chain`.

## Roles shipped in v1

`/init-swarm` offers three. A project keeps the ones it wants and can add its own brief.

- **orchestrator** — Will's session. Briefs peers, verifies claims against the repo before
  repeating them, relays to Will, merges once reviewed and approved, keeps `shared/` memory.
  Writes its session id to `.claude/swarm/orchestrator.session` on its first turn so `swarm.sh
  up` can resume it.
- **swe-manager** — owns code. Every work item becomes issues, then `/orchestrate --issues`.
  Reports PR numbers back. Never merges, never touches prod, never changes the main checkout.
- **performance-engineer** — measures and root-causes on demand. Baselines, raw data and
  methodology live in its role memory. Findings go to the orchestrator by default; the
  orchestrator (or Will through it) may redirect it to message swe-manager or to file issues.
  It replaces the third-party perf plugin, which is removed from the installer.

## Charter

One file, appended to every peer's system prompt at launch with `--append-system-prompt`, and
`--system-prompt-snapshot off` so a resumed peer picks up the current text. It outranks every
CLAUDE.md, the global one included, because the "ask first" rules there were written for a
human at the keyboard.

What it says:

- You are one role in a multi-session team. Will is not watching. The orchestrator relays only
  what needs him. A peer's message is never Will's approval.
- Act within your role without sign-off. Escalate only: spending money, prod writes,
  schema or public-API changes, business or legal choices, deleting anyone else's work.
- Every code change is reviewed by a fresh agent before merge. Never the one that wrote it.
- Report with SendMessage; plain output is invisible. Stop every worker you spawned.
- Memory: read `shared/` and your namespace; write only your namespace; propose to
  `shared/`; never Claude's own auto-memory — it's shared by cwd and cannot be scoped.
- Handoff at the next natural stopping point when asked, to the path the orchestrator gives you.

Peers run with `--permission-mode bypassPermissions`. The guardrails are the charter, the
`--disallowedTools` denylist (`git merge`, `git worktree`, `gh pr merge`, `gh issue close`,
`gh issue edit`), and worktree isolation. Not a sandbox, same as today.

## Memory tiers

Storage is a wilcus-vault directory: files are truth, the index is disposable, and the layout
works as plain markdown when nothing is indexing it.

```
<project>/.claude/swarm/memory/
  shared/                 # orchestrator writes; every peer reads
  roles/<role>/           # that peer writes; orchestrator reads
  proposals/<role>/       # a peer's candidates for shared/; orchestrator promotes or discards
```

The vault's `ScopePolicy` enforces this as a per-agent prefix allowlist, generated from the
roster:

- orchestrator: read+write everything.
- peer `<r>`: read `shared/`, read+write `roles/<r>/` and `proposals/<r>/`.
- worker: read `shared/` and its manager's `roles/<r>/`. No write rule, so writes fail closed.

Promotion is the orchestrator moving a note from `proposals/<r>/` through the vault's write
gate into `shared/`, so a proposal that duplicates or supersedes an existing shared note is
handled by the gate, not by hand. Peers are told in the charter to use the vault and not
Claude's auto-memory, which is shared by cwd and cannot be scoped.

**Work order for the wilcus-vault session** (spawned once this doc is agreed):

1. `vault init --layout swarm --roster <roster.json>` writes the three namespaces and a
   `<vault>/.vault-policy.json` from the roster.
2. CLI `propose`, `get`, `list` with `--agent <name>`, loading the policy from the vault dir.
   The library has these; the CLI does not, and agents only have the CLI.
3. `vault promote <proposal-path> --agent orchestrator` runs the write gate into `shared/`.

## Lifecycle

`swarm.sh`, one script, five verbs:

- `up` — starts every roster peer not already listed, then resumes the orchestrator by its saved
  id, or starts it fresh with its brief. Generalizes cogito's `orchestrator.sh` + `spawn.sh`.
- `down` — stops every peer for this project by id.
- `rotate <role> <handoff-path>` — waits for the peer to go idle, refuses if it is blocked,
  stops it, respawns it with the handoff prepended. The path comes from the peer's own reply,
  so swarm never calls into context.
- `attach <role>` — `claude attach` by id, for when Will wants to sit in a peer.
- `brief <role> <file>` — copy a brief into `.claude/swarm/inbox/<role>/` and print the
  absolute path to send: briefs are files, messages are pointers (§ Rotation). A manual,
  occasional call — nothing in `up`, `down`, `rotate` or `attach` invokes it, so in practice
  an inbox holds only the role's standing `brief.md`.

Nothing rotates automatically. The context plugin's watchdog advises; the orchestrator asks.

## Codex backend

Verified on codex-cli 0.154 with real luna runs (2026-09-15), not from docs. A worker is
one-shot, so it maps onto `codex exec`:

- **Launch.** `codex exec -C <worktree> -m gpt-5.6-<tier> -c model_reasoning_effort="<e>"
  -c approval_policy="never" -s workspace-write
  -c 'sandbox_workspace_write.network_access=true' --json -o <last-message-file>
  [--output-schema <status-schema>] "<prompt>" </dev/null`. Model slugs are `gpt-5.6-luna`,
  `gpt-5.6-terra`, `gpt-5.6-sol`; efforts low through max. **Stdin must be closed** or codex
  blocks forever reading it. `-m` must always be passed: a resumed thread otherwise falls
  back to the config default model. Verified: `workspace-write` is OFFLINE by default — a
  `curl` inside it fails at DNS — and with `network_access=true` it returns 200. The flag is
  not optional, since the worker's own prompt orders `gh` and `git push`, and
  `approval_policy=never` means it cannot ask for the network back. It cuts both ways:
  workspace-write restricts writes, not reads, so a networked worker that ingests an
  untrusted issue comment has both this machine's credentials and an egress path. Accepted
  knowingly — claude workers already run with full network — and codex 0.154 offers no
  domain allowlist to narrow it.
- **Commits.** Workspace-write keeps `.git` read-only, so a worker that must commit needs
  writable roots inside it. For a linked worktree those live in the MAIN repo's common git
  dir, since objects and refs are shared. Verified: with them listed the worker commits;
  without, it writes the file and reports it could not commit.
  **Narrowed, not the whole dir** (`infra/common-git-dir.sh --roots`, used by both `spawn.sh`
  and `worker-resume.sh`): `objects`, `refs`, `logs` and the worktree's OWN git dir — never the
  shared `hooks/` and never the shared `config`. It REFUSES a non-linked worktree outright (the
  main checkout's own `.git` cannot be narrowed) and refuses a repo with
  `extensions.worktreeConfig` enabled, where `config.worktree` would sit inside a granted root.
  It also refuses a worktree already carrying a planted `config.worktree`, one whose
  `commondir` has been rewritten, and one whose `.git` has been repointed or symlinked at
  another repo's git dir — each of those steered the roots themselves onto another repository
  until it was refused (§ Roster).
  **Residual, accepted (§ Roster):** `commondir` still sits inside the granted `$OWN`, so git run
  by a human in that worktree follows it to a planted `config`; reproduced 2026-09-17 as host
  code execution. Worktrees isolate working *files*, not git: they all share one
  `.git`, and `hooks/` and `config` are things git EXECUTES, so granting the whole dir let a
  worker write `hooks/pre-commit` or set `core.sshCommand` and get host code execution the
  next time a sibling worker, the merge, or the user ran git there. Verified 2026-09-16 on
  codex-cli 0.154, ground-truthed from OUTSIDE the sandbox on a real `~/code` path: commits
  still land, `.git/hooks` and paths outside the project are blocked. **Test on a real path,
  never under `/tmp`** — workspace-write allows the system temp dir by default, so a probe
  living there reports an escape that is really just `/tmp`.
  `danger-full-access` also works and is the fallback, but it gives up exactly this
  containment, so it is a deliberate downgrade rather than an equivalent.
- **Output.** stdout gets the final message; `-o` writes it to a file; `--output-schema`
  forces a JSON final answer, which is the worker's fixed-shape status report. `--json`
  streams one event per line: `thread.started` (with the thread id), `item.started` /
  `item.completed` for messages, file changes and commands, `turn.completed` with token usage.
  Progress goes to stderr. Exit 0 on completion. No ANSI, so `session-status.sh` parses it.
- **Resume.** Every run persists under `~/.codex/sessions/<Y>/<M>/<D>/rollout-<ts>-<uuid>.jsonl`,
  whose first line is `session_meta` carrying `session_id` and `cwd`; `codex exec resume
  <thread-id> "<prompt>"` continues it. The id is also in the run dir already — `events.jsonl`
  carries a `thread.started` event with `thread_id` — and a rollout can be found by its `cwd`
  (the issue worktree) if that is ever missing. A fix round may resume the implementer's thread
  or start fresh; the orchestrate rule (a fresh implementer per round) stays the default. This is
  what makes an escalation a pause rather than an ending (§ below).
  **Verified 2026-09-16: `resume` inherits NONE of the sandbox.** With explicit flags a run
  returned `http=200`; the same thread resumed re-passing nothing returned `DNSFAIL`, i.e. a
  resumed worker is OFFLINE and fails its own `gh` protocol silently. `resume` accepts `-m`,
  `-o`, `--output-schema`, `--json` and `-c`, but **not** `-s` and **not** `-C` — so the sandbox
  must be re-passed through `-c` and the resume launched from the worktree directory. `-m` must
  be re-passed for the same reason it must on a fresh run.
- **Review.** **Superseded by #104: a codex-built branch is reviewed by the CLAUDE reviewer** —
  `review-cmd.sh` builds a `claude -p` call at the reviewer cell's model (its effort reaches only
  the launcher; the my-review agent's frontmatter pins its own) that spawns
  `personal-tools:my-review` on the commit range, in the disposable clone, and emits
  `- [Pn] title — path:line` items or the literal `No findings.` for `review-counts.sh`.
  `codex exec review` was a working reviewer, but it could not be pointed at a claude model, so
  the roster's "reviewer: opus" was silently false for every codex worker, and (below) nothing
  could shape what it said about how it verified. The paragraphs below record what was learned
  about it; the sibling-process, pinned-SHA and disposable-clone properties all carry over.

  **It runs as a SIBLING of the worker, never inside it** (`review-cmd.sh`, invoked by
  `spawn.sh`'s wrapper and by `worker-resume.sh`). The worker was originally told to run its own
  review, and #96's e2e gate caught what that actually did: a nested `codex exec` cannot
  initialise inside the worker's own sandbox — `failed to initialize in-process app-server
  client: Read-only file system (os error 30)`, because `~/.codex` is not among its
  `writable_roots` — and the worker, holding a required `review` field, filled it with its own
  assessment of its own diff and reported a clean independent review that never ran. Nothing
  downstream could tell the difference. A sibling process fixes both halves: it is inside
  nobody's sandbox, and the verdict never passes through the thing that wrote the code. The
  worker now reports `review: ""`, the reviewer's output file is the only verdict, and
  `worker-report.sh` refuses a `built`/`fixed` report that has none.

  Three things about that command were verified against codex-cli 0.155.0 and are pinned by
  `test_review-cmd.sh`, because the first version of this fix shipped an argv the CLI rejects
  outright — the reviewer died on every run and every codex build failed closed:
  **no `-C`** (it is a top-level `codex exec` flag only; the callers `cd` instead),
  **no trailing prompt** (`--base` and `[PROMPT]` are mutually exclusive, so the verdict's shape
  is NOT requested at all: `--output-schema` is accepted on a review turn and silently IGNORED,
  proven by a real run and a direct probe, so `review-counts.sh` parses codex's own review
  template — `- [Pn] title — path:lines` items, or prose with no marker for a clean one — and
  REFUSES anything it cannot read rather than counting it as zero findings), and
  **`--base` takes a resolved SHA, not a branch name**. That last one is a second door onto the
  same bug: `refs/` is a granted writable root, so a worker could `git branch -f <base> HEAD`,
  empty its own diff, and collect a clean verdict from an honest reviewer. `spawn.sh` resolves
  the base to a commit *before* the worker starts.

  The reviewer's sandbox is pinned rather than inherited: `exec review` takes no `-s`, and a
  user whose config defaults to `danger-full-access` would otherwise have a model reading
  worker-authored, injectable content run on the host with `approval_policy=never`.

  **It is `workspace-write`, not `read-only` (#99).** Read-only blocked every write with no
  config-level exception, so a test runner inside the review could never create a tempfile —
  `pytest` (and equivalents) failed with "no usable temporary directory", and the reviewer was
  diff-reading only, silently, on every run. **A scratch root alone does not close that gap
  safely**, ground-truthed against codex-cli 0.155.1 (2026-09-20) with `codex exec
  --strict-config`, whose startup banner echoes the resolved policy:
  `sandbox_workspace_write.writable_roots` only ADDS roots, it never subtracts the ones
  `workspace-write` grants unconditionally, and one of those is `workdir` — wherever the
  process is run FROM. `exclude_slash_tmp` and `exclude_tmpdir_env_var` are real keys, verified
  to drop `/tmp`/`$TMPDIR` from that banner; no key drops `workdir`. `exec review` takes no
  `-C`, so its `workdir` is wherever the caller `cd`s. Flipping only the sandbox mode, with the
  real worktree still cwd, would have handed the reviewer write access to every tracked file
  outside `.git` — the exact regression #99 said the fix must not make.

  So the review never runs FROM the worktree. `spawn.sh`'s wrapper and `worker-resume.sh` both
  `git clone --shared` it into a disposable checkout under the run dir first — sharing objects
  costs no copy — `cd` there, and run the argv with `TMPDIR` set to a scratch dir alongside it
  (also under the run dir, also disposable). `workdir` being writable then costs nothing: the
  clone and scratch dir are deleted the moment the review exits, on every path (success,
  failure, or a containment refusal). `--base`, a resolved SHA, still diffs correctly in the
  clone — it carries the same commit history — and nothing is lost by reviewing it instead of
  the live worktree: this reviews COMMITTED state only (`--base`, never `--uncommitted`), which
  a clone has exactly. Verified end-to-end with a real `codex exec` run, not just the banner: a
  tempfile created inside the scratch root succeeded, and a write attempted one level above
  `workdir` (standing in for anywhere ungranted) failed with "read-only file system".

  The reviewer runs only when the worker REPORTED `built` or `fixed` — `escalate` and `failed`
  exit 0 too, and reviewing those posts a `Review round` comment the lane counts as a cycle.

  (Historical — retired by #104.) `review-cmd.sh` passed the roster's **reviewer** cell as `-m`
  only when that cell was itself codex-backed; a claude reviewer cell left the flag off and took
  codex's default model. That silent substitution is the bug the claude reviewer fixes.

  **Verification honesty — ACCEPTED, no lever exists (#100).** A `sol`-tier reviewer's verdict
  once asserted "All six tests pass" while running under the pinned `sandbox_mode=read-only`
  (#99) — where pytest cannot even open a temp file — while a `terra`-tier reviewer given the
  identical diff and the identical inability to run anything made no such claim: a model
  substituting its own confidence for a check it did not perform. Three candidate levers were
  ground-truthed with real `gpt-5.6-sol` review runs against codex-cli 0.155.1 (2026-09-20,
  a later point release than the 0.155.0 ground-truthing above) looking for a way to
  instruct it otherwise:
  - the trailing `[PROMPT]` — blocked outright by the CLI itself (above);
  - `-c instructions="…"` and `-c developer_instructions="…"` — both pass `--strict-config`
    (codex recognizes the field) but a real review run with either set never mentioned the
    injected text — the same recognized-but-ignored shape as `--output-schema` above;
  - an `AGENTS.md` at the reviewed repo's root — NOT loaded into a review turn's context the
    way it is for a plain `codex exec` (`codex debug prompt-input` shows it injected there as a
    developer-role message). On a real review run the model saw it only incidentally, through
    its own `find … -exec sed` sweep of repo files, and did not follow the instruction planted
    in it even then.

  `codex exec review`'s system prompt is entirely fixed — codex's own review template (above)
  — and codex-cli 0.155.1 gives a caller no way to shape what it says about how it verified
  something. Accepted knowingly, same as the network and `--disallowedTools` gaps (§ Roster):
  the honest fix is upstream, in codex itself, not in this repo.
- **No inbox.** `codex queue` only feeds a running session's next turn. Codex is never a peer.

`infra/spawn.sh` switches on the tier's backend and writes a pid file and an exit-code file
beside the event log; `session-status.sh` reports a codex worker from those the way it reports
a claude worker from the agent list. The **state** vocabulary is identical, so `/orchestrate`'s
liveness wait is unchanged — but **control is not**: column 2 is a PID, so a codex row is stopped
with `kill`, not `claude stop`, there is nothing to `claude attach`, and with no inbox a codex
worker cannot be spoken to mid-run — it escalates by ENDING its turn (`status: escalate`, the
question in `note`) and is answered by resuming its thread, which keeps everything it had. That PID is `spawn.sh`'s wrapper, not `codex` itself, so the stop
is a **group** kill — `kill -- -<pid>`: `spawn.sh` starts the wrapper under bash job control
(`set -m`, a builtin — `setsid` is Linux-only and the kit runs on macOS too) so it leads its own
process group, because killing the wrapper alone orphans codex onto the worktree and
leaves no exit file, which reads as `failed` and frees the orchestrator to respawn on top of it.

Landed as `${CODEX_RUN_ROOT:-~/.claude/codex-runs}/<runid>/issue-<N>/` holding `events.jsonl`,
`stderr.log` (the only place a failed worker's reason lands), `last-message.txt`,
`status-schema.json`, `review.txt` (the independent reviewer's output — the ONLY source of the
finding counts, parsed by `review-counts.sh`), `review-comment.md` (what was posted to the
issue), `review-stderr.log` (why it did not run, quoted back
when worker-report.sh refuses the run), `pid` and `exit` — which is written LAST, after the
review, so a run that reads terminal always has its verdict on disk. A live pid reports `busy`, exit 0
`done`, anything else `failed` — the same vocabulary the agent list normalizes into, because
`/orchestrate`'s liveness loop waits on `busy`. A codex worker never goes `idle`. Its prompt
also swaps two steps: a sibling claude reviewer replaces the in-session `my-review` subagent —
run for the worker rather than by it, see § Review — and the schema'd final message replaces
`SendMessage`, which codex does not have.

## Rotation

Peers fill up. Rotation is the peer version of `/clear` then `go`, and it was verified live
(2026-09-15): stop a named background session, respawn under the same name with a handoff
file prepended to its prompt, and the successor reads the doc, reports back, and receives
messages sent to the name. The name is the stable address; the process is disposable.

- **Trigger lives in the peer.** `claude agents --json` exposes no context size, so the
  orchestrator cannot measure peers. The context plugin's watchdog already computes
  occupancy from the session's own transcript and fires on every inbound message. Past the
  roster's `rotate_at` (default 300k) it injects: *at the next natural stopping point, run
  `/handoff`, then tell the orchestrator you are ready with the doc path.* The peer picks the
  moment. This reintroduces a nudge that was once deleted for interrupting long runs; the
  difference is that this one says "next natural stopping point" and the model chooses.
- **Resume grace (#102).** A rotated peer's transcript starts brand new (`rotate` stops the
  old process and spawns a fresh one onto the handoff), so its first real turn — reading the
  handoff plus the resume preamble, however many tool calls that takes — can already read as
  past `rotate_at`. The watchdog counts real prompts, not raw transcript entries (a turn can
  cost many of the latter, one per tool call), and stays silent through that first real turn,
  evaluating normally from the second.
- **Rotation is `swarm.sh rotate <role> <handoff-path>`.** Wait for idle, refuse if blocked,
  stop by id, respawn via infra spawn with the handoff prepended. No pending pointer is used,
  which removes the per-repo `.pending.json` collision peers keep hitting.
- **Lost-message windows, and what closes them.**
  1. Message arrives while the peer writes the handoff: it is delivered mid-turn, and the
     charter says to append it to the doc verbatim before replying ready.
  2. Message arrives between the ready reply and the stop: `rotate` re-checks idle right
     before stopping, so the peer has started on it and rotate waits. The gap between that
     check and the stop is the residual race.
  3. Message arrives after the stop: SendMessage to a missing name fails on the sender's side
     (verified), so the sender retries.
  What actually closes each window is the mechanism named above — append, re-check, retry
  — not the inbox. **The inbox is read once, at spawn or rotation**, and in practice holds
  only the role's standing `brief.md` from init: nothing in the lifecycle drops a fresh file
  there mid-run, so listing it first is a cheap check for a brief staged ahead of the
  rotation, not a recovery path for arbitrary lost content. Ongoing coordination — a run id,
  a blocker, a question — is SendMessage, never a file; a real gate run showed exactly that
  (#96). This is `/orchestrate`'s "the issue thread is the bus" rule, applied to peers.
- **Backstop.** Peers launch with `--autocompact` at the roster's `autocompact` (default
  400k). The context plugin's PreCompact hook writes a handoff before any compaction, so a
  peer that never reaches a natural stopping point degrades to a compaction, not a cliff.

## Migration

cogito and wilcus-agents stay as they are until the kit is done. Then each replaces its
scripts with `/init-swarm` output and its briefs with roster rows, and they are the acceptance
test. The perf plugin is already out of `setup-dev.sh`, `README.md` and `AGENT_SETUP.md`.

## Deliberately not built

- **Per-role permission modes.** Bypass for every peer. A knob per row is a knob to get wrong.
- **Orchestrator-measured rotation.** The peer nudges itself from its own transcript; the
  orchestrator only runs `rotate` when told ready. Polling peers for context size has no
  data source.
- **Codex peers.** A peer needs an inbox. Codex has none. Workers only.
- **A brief lane for managers.** Every manager work item is an issue. Briefs go through
  `/to-issues` first, which is where content stops flowing upward.
- **A plugin dependency mechanism.** The star plus one symlink is the whole thing.

## Build order

1. **context** plugin: move the four hooks and the two handoff skills. Delete the inline
   keying duplication. Tests move with the scripts.
2. **infra** plugin: move `spawn.sh`, `session-status.sh`, `check-inbound.sh`,
   `resolve-tier.sh`, the tier table. Add the stable-address hook. Generalize spawn from
   "one issue" to "one role or one worker". (Landed #85: `session-status.sh`, `check-inbound.sh`,
   `resolve-tier.sh` + the tier table, and the hook. Landed #88: `spawn.sh`, generalized into a
   worker form and a peer form. Infra resolves its own siblings by its own dir; the stable link
   is for callers outside infra.)
3. **workflow** trim: `/orchestrate` calls infra by the stable path; session prose moves to
   infra's README; `/to-prd` and `/to-issues` move in from personal-tools.
4. **swarm** plugin: roster schema, `/init-swarm`, `swarm.sh up|down|attach`, charter,
   three briefs, inbox dirs. (Landed #91: `up|down|attach`. A peer carries no run prefix,
   so infra's `session-status.sh` gained `--peers <project-dir> <role>...` to resolve a
   role name to a session id — scoped by the session's cwd, which is what "every peer of
   this project" means when two projects share a `swe-manager`.)
5. **rotation**: the peer-mode watchdog threshold and `swarm.sh rotate`.
6. **memory**: vault work order above, then the policy generator and charter lines in swarm.
   (Landed #93: `/init-swarm` runs `vault init --layout swarm` when vault is on PATH, with
   a plain-directory fallback otherwise, plus the charter's auto-memory rule and each
   brief's `--agent` name.)
7. **codex**: the backend switch in infra. (Landed #90: `spawn.sh`'s `codex exec` worker path
   and codex worker state in `session-status.sh`. The orchestrator-side ingest landed as
   `worker-report.sh`. The shipped `model-tiers.json` stays claude and that is the end state,
   not a hold — codex is opt-in per user, see § Roster.)
8. **migrate** cogito, then wilcus-agents. (The perf plugin is already out of the installer.)

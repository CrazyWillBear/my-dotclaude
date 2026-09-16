plugins/infra/scripts/spawn.sh — switch on the tier's backend; add the codex exec path (pid file + exit-code file beside the event log) alongside the claude path
plugins/infra/scripts/resolve-tier.sh — already emits <role>_backend= and validates codex model names; spawn.sh consumes it to pick backend/model/effort
plugins/infra/scripts/session-status.sh — must report a codex worker (working/completed/failed) from the pid and exit files, as it does for claude from the agent list
plugins/infra/model-tiers.json — THE ROSTER FLIP this issue now owns (amended scope): per the Roster section, trivial implementer=codex luna and reviewer=codex terra, standard implementer and reviewer=codex terra, complex planner/implementer/reviewer=codex sol; all rows currently still say backend=claude
plugins/infra/tests/test_resolve-tier.sh — shipped-config assertions pin every tier to backend=claude and the old model names; update to match the flipped roster
plugins/infra/tests/test_spawn.sh — stub-claude black-box tests; add codex-path tests with a stub codex on PATH pinning every flag: -C, -m, -c model_reasoning_effort, -c approval_policy=never, -s workspace-write, sandbox_workspace_write.writable_roots including the common git dir, --json, -o, --output-schema, closed stdin, pid file, exit-code file
plugins/infra/tests/test_session-status.sh — add tests reading codex worker state from the pid/exit pair (working for a live pid, completed for exit 0, failed otherwise)
docs/swarm-design.md — Roster gives the exact tier-to-backend table; the codex backend section gives the verified codex exec flag set, the writable-roots requirement for commits, and the output shapes
plugins/infra/README.md — documents model-tiers.json and spawn.sh's two forms; only covers the claude flow today
plugins/workflow/skills/orchestrate/SKILL.md — notes this issue wires codex for the session lane only; the ad-hoc lane stays claude-only. Boundary, not edited here
plugins/swarm/tests/test_roster.sh — swarm's own roster fixtures use backend=codex vocabulary; a different config, check it assumes nothing claude-only

Note: no stub codex binary exists yet; add it alongside the existing stub-claude pattern rather than in a new file.

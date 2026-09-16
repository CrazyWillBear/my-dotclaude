plugins/swarm/scripts/swarm.sh — the file to extend; today only implements brief, needs up/down/attach
plugins/swarm/tests/test_swarm_brief.sh — existing black-box suite; the new verbs need sibling tests in the same style
plugins/infra/scripts/spawn.sh — up calls this in its peer form per missing roster peer, passing brief/charter/model/effort/autocompact; its --dry-run is the pattern for pinning argv in tests
plugins/infra/scripts/session-status.sh — enumerates live sessions and resolves a role name to a session id; up needs it to find missing peers, down/attach need it because claude stop/attach reject names
plugins/infra/tests/test_spawn.sh — the stub-claude dry-run testing pattern (fake HOME, PATH-stubbed claude, argv assertions)
plugins/infra/tests/test_session-status.sh — coverage for the id/name resolution down and attach depend on
plugins/swarm/scripts/roster.sh — up reads .claude/swarm/roster.json through this for peers, kind, model/effort/rotate_at/autocompact
plugins/swarm/templates/roster.json — the shipped default roster used by test fixtures
plugins/swarm/tests/test_roster.sh — roster.sh coverage; up depends on its validate-then-answer contract
plugins/swarm/templates/briefs/orchestrator.md — documents .claude/swarm/orchestrator.session, which up reads to resume by saved id vs start fresh
plugins/swarm/templates/briefs/swe-manager.md — brief passed to spawn.sh's peer form
plugins/swarm/templates/briefs/performance-engineer.md — brief passed to spawn.sh's peer form
plugins/swarm/templates/charter.md — appended via spawn.sh's peer charter flag for every peer
plugins/swarm/skills/init-swarm/SKILL.md — defers up/down/attach to this issue; documents the roster shape up consumes
plugins/swarm/tests/test_init-swarm-skill.sh — asserts the skill calls swarm.sh a later issue; may need updating
docs/swarm-design.md — Lifecycle defines up/down/rotate/attach; Roster and Charter define the peer row and brief/charter wiring; Plugin split says swarm calls only into infra
plugins/infra/scripts/resolve-tier.sh — NOT called for peers: peers are not tier-routed, their model and effort come from the roster row

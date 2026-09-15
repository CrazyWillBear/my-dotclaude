# infra

Scripts-only shared layer. Other plugins call these scripts; infra calls into nothing.
See [`docs/swarm-design.md` § Plugin split](../../docs/swarm-design.md).

```
plugins/infra/
├── .claude-plugin/plugin.json   # manifest
├── hooks/hooks.json             # SessionStart → scripts/link-kit.sh
├── model-tiers.json             # tier → {model, effort} roster, read by resolve-tier.sh
├── scripts/
│   ├── link-kit.sh              # SessionStart: point ~/.claude/kit/infra at this plugin's root
│   ├── session-status.sh        # worker session state from `claude agents --json`; --self resolves this session's name
│   ├── check-inbound.sh         # pre-run: can worker reports reach the orchestrator? (crossSessionInbound)
│   └── resolve-tier.sh          # resolve a complexity tier → its {model, effort} roster (awk, no jq; standard fallback)
├── tests/                       # one bash test per script
└── README.md                    # this file
```

## The stable address

A plugin's install path is a versioned cache directory, so no other plugin can find infra
by relative path. Instead, infra's `SessionStart` hook keeps a symlink at
`~/.claude/kit/infra` pointing at its own root, and every caller uses that one path:

```bash
bash ~/.claude/kit/infra/scripts/session-status.sh --self
```

The link appears on the first session start after install, and is repointed on every
start, so it follows version bumps. If a real directory sits at that path, the hook
refuses and says so rather than delete it.

# personal-tools

My personal Claude Code slash commands and subagents, versioned here so they come back
with the rest of my setup on any machine.

```
plugins/personal-tools/
├── .claude-plugin/plugin.json   # manifest
├── commands/recap.md            # /recap — recap work-in-progress in a repo
└── agents/explainer.md          # explainer — plain-English code walkthroughs
```

- **Commands** (`commands/*.md`) become slash commands named after the file:
  `recap.md` → `/recap`. Frontmatter sets the description, argument hint, and the
  tools the command may use.
- **Agents** (`agents/*.md`) become subagents launchable by name. Frontmatter sets the
  name, when-to-use description, and allowed tools.

Adding a tool is just dropping a file in and restarting Claude Code.

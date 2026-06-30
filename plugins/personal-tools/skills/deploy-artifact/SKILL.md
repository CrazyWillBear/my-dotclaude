---
name: deploy-artifact
description: Deploy a claude.ai artifact (HTML/React/SVG/Mermaid/Markdown) live to Vercel — reproduces the claude.ai runtime (shadcn/ui, lucide, recharts, …), builds, deploys via the vercel CLI, and verifies the live URL in a browser. Use for "/deploy-artifact", "deploy this artifact", "ship this to vercel".
argument-hint: "[pasted artifact code, a claude.ai share URL, or a local file/dir path]"
model: inherit
allowed-tools: Read, Write, Edit, Bash, AskUserQuestion, WebFetch, mcp__playwright__browser_tabs, mcp__playwright__browser_navigate, mcp__playwright__browser_console_messages, mcp__playwright__browser_take_screenshot, mcp__playwright__browser_snapshot, mcp__playwright__browser_close
---

# deploy-artifact

Take a **claude.ai Artifact** and deploy it **live to Vercel**, reproducing the claude.ai
runtime so it renders correctly, then verify the live URL in a real browser.

This is a **flexible playbook**, not a rigid script. Reason through it. Artifacts come in
six kinds (HTML, SVG, Mermaid, Markdown, code, React) and may be single- or multi-file.
Handle whatever you're given.

Bundled assets (reference by `${CLAUDE_PLUGIN_ROOT}` — resolves to this plugin's root):
- Template (the "claude.ai env"): `${CLAUDE_PLUGIN_ROOT}/skills/deploy-artifact/template/`
- Dependency scanner: `${CLAUDE_PLUGIN_ROOT}/skills/deploy-artifact/scripts/detect-deps.mjs`

## Honesty rules (read first)

- **Never claim a deploy works** until the Playwright verify step has actually loaded the
  live URL, the root mounted, and the console is error-free.
- Report console errors **verbatim**. A deploy that returns a URL but renders errors is a
  ⚠️ failure, not a success.
- If you can't recover an artifact's source, **ask the user to paste it** — don't guess.

## 1. Acquire the source

From `$ARGUMENTS` and the conversation, get the artifact source:

- **Pasted code** → write it to the build dir (step 3).
- **claude.ai share URL** (`https://claude.ai/public/artifacts/<uuid>`) → best-effort probe:
  open it in the browser and try to extract source. HTML artifacts often expose their source
  via the rendered iframe; **React/others are transpiled and not recoverable** — if you can't
  get clean source, **ask the user to paste the code** and continue. (There is no public
  source API.)
- **Local file or dir path** → read it. Support multi-file artifacts (a dir or several files).

## 2. Detect kind + structure

Sniff the source:

| Signal | Kind |
|---|---|
| `<!doctype html>` / `<html` | HTML |
| leading `<svg` | SVG |
| mermaid keywords (`graph`, `flowchart`, `sequenceDiagram`, `gantt`, `classDiagram`, …) | Mermaid |
| `export default` + JSX, or `import … from 'react'` | React |
| else | Markdown / plain code |

Note whether it's **single-file** or **multi-file** (preserve relative imports between files).

## 3. Choose a build dir

Default: a fresh temp dir under the session scratchpad (e.g.
`<scratchpad>/deploy-artifact-<slug>`). If the user wants to keep the generated project,
accept an output dir from them and use that instead.

## 4. Scaffold by kind

> Every HTML page **you generate** (the static wrappers below, and the template) must include
> `<link rel="icon" href="data:," />` in `<head>`. Without it the browser auto-requests
> `/favicon.ico`, gets a 404, and that logs a console error that trips the zero-errors verify
> gate. (The template already has this line. A favicon 404 in a *user's own* HTML artifact is
> the one benign error you may wave through in step 6.)

### HTML
Drop the source as `index.html` in a fresh dir. Nothing to build — it deploys static.

### SVG
Wrap the SVG inline in a minimal `index.html` (centered, full-viewport). Static.

### Mermaid
Write an `index.html` that loads mermaid (CDN `https://cdn.jsdelivr.net/npm/mermaid/dist/mermaid.esm.min.mjs` is fine — Vercel imposes no CSP) and renders the diagram from a `<pre class="mermaid">` block. Static.

### Markdown
Render to a styled `index.html` (load `marked` from CDN, or pre-render). Add minimal
readable CSS. Static.

### React (the main path)
1. Copy the template into the build dir:
   `cp -r ${CLAUDE_PLUGIN_ROOT}/skills/deploy-artifact/template/* ${CLAUDE_PLUGIN_ROOT}/skills/deploy-artifact/template/.gitignore <build>/` (include dotfiles; or copy the dir then work inside it).
2. Place the artifact code:
   - **Single file** → write it to `<build>/src/artifact.tsx` (must default-export a
     zero-required-props component). `src/main.tsx` already imports `./artifact` and mounts
     to `#root`.
   - **Multi-file** → spread the files into `<build>/src/`, preserving their relative imports.
     Make the **default-export entry component** the thing `src/main.tsx` renders: either name
     the entry `src/artifact.tsx`, or edit `main.tsx`'s `import App from './artifact'` to point
     at the real entry file.
   - The artifact's `@/components/ui/*` (shadcn), `@/lib/utils` (`cn`), `lucide-react`,
     `recharts` imports already resolve against the template — don't rewrite them.
3. Detect extra deps and install:
   ```bash
   cd <build>
   EXTRA=$(node ${CLAUDE_PLUGIN_ROOT}/skills/deploy-artifact/scripts/detect-deps.mjs src/artifact.tsx [other src files])
   npm install            # base (locked template deps)
   # install any extras the scanner found (JSON array on stdout):
   echo "$EXTRA" | node -e 'const a=JSON.parse(require("fs").readFileSync(0,"utf8")); if(a.length) process.stdout.write(a.join(" "))' | xargs -r npm install
   ```
   The scanner skips anything already baked (react, shadcn/radix, lucide, recharts, …) and
   emits only heavy/standalone libs (`d3`, `three`, `plotly.js`, `papaparse`, `lodash`,
   `mathjs`, `tone`, `chart.js`, `xlsx`, `mammoth`, `@tensorflow/tfjs`, …). On-demand installs
   pull **latest** versions — note possible API drift (e.g. `three`) and fix the artifact if a
   build error points at it.
4. Build: `npm run build` → produces `dist/`. If the build fails, read the error, fix the
   artifact/template, and rebuild before deploying. (The build uses esbuild type-stripping —
   it won't fail on type errors, only on real syntax/module-resolution errors.)

## 5. Deploy via the `vercel` CLI

(MCP can't push local files; the CLI is required. The output is **pre-built static** — for
React, deploy `dist/`; for static kinds, deploy the dir.)

The project name derives from the **basename of the deployed dir**, so stage the output in a
dir named for the project (e.g. copy `dist/` → `<project-name>/`) before deploying.

1. Auth: `vercel whoami`. If it fails, tell the user to run `vercel login` and **stop**.
2. Pick the **scope (team)**: in non-interactive `-F json` mode vercel refuses to guess when
   the account has more than one team — it returns `{"status":"action_required","reason":"missing_scope", choices:[…]}`. List teams with `vercel teams ls`, pick the user's personal scope
   (matches `vercel whoami`), and pass `--scope <team-slug>` on every `deploy`/`link` call.
3. Ask the user (`AskUserQuestion`), unless they already told you:
   - **Preview or production?**
   - **Project name?** (Reuse it if it already exists.)
   - **Make it publicly viewable?** — the account may have **Deployment Protection (Vercel
     Authentication) ON by default**, which puts every deploy behind a Vercel login (the live
     URL redirects to `vercel.com/login`). Ask per deploy:
     - **Yes, public** → after deploying, disable SSO protection on the project (see below).
     - **No, keep protected** → only people logged into the user's Vercel account can view it.
       Tell the user this plainly; the URL is not shareable to logged-out visitors.
4. If the name already exists (`vercel project ls --scope <team>` lists it), link first:
   `vercel link --yes --project <name> --cwd <deploy-dir> --scope <team>`.
5. Deploy the staged output dir:
   ```bash
   # React: stage <build>/dist as <name>/   |   static kinds: the wrapped dir IS <name>/
   vercel deploy --cwd <name-dir> --yes -F json --scope <team>           # preview
   vercel deploy --cwd <name-dir> --yes --prod -F json --scope <team>    # production
   ```
   Parse the URL from `.deployment.url` in the JSON (NOT `.url`), e.g.
   `… | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).deployment.url))'`.
6. **If the user chose "public"**, disable Vercel Authentication on the project so logged-out
   visitors can load it. The CLI has no command for this; PATCH the REST API with the CLI's
   token (read from `~/.local/share/com.vercel.cli/auth.json` — **never print the token**). The
   project/team ids are in `<name-dir>/.vercel/project.json`:
   ```bash
   TOKEN=$(node -e "process.stdout.write(require(process.env.HOME+'/.local/share/com.vercel.cli/auth.json').token)")
   curl -s -X PATCH "https://api.vercel.com/v9/projects/<projectId>?teamId=<orgId>" \
     -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"ssoProtection": null}' >/dev/null
   ```
   This is a security-loosening change; only run it when the user explicitly said "public" this
   deploy. (The Claude Code auto-classifier will block it unless the user pre-authorizes the
   command — if blocked, tell the user and let them decide.)

## 6. Verify in a real browser (Playwright) — REQUIRED

Don't skip this. Using the `mcp__playwright__browser_*` tools:

1. Open the live URL: `browser_navigate` to `https://<url>` (or `browser_tabs` new tab). If the
   page is the **`vercel.com/login`** screen, the deploy is still protected — either the user
   chose "keep protected" (the verifying browser must be logged into the user's Vercel account
   to see it) or the public-toggle didn't apply. Note it and proceed accordingly.
2. `browser_console_messages` — collect console output; **filter for errors**.
3. `browser_snapshot` — confirm the app actually mounted (root has content, not a blank page
   or an error overlay).
4. `browser_take_screenshot` — capture the rendered page; surface it to the user.

Verdict:
- ✅ **mounted + zero console errors** → success. (A lone `/favicon.ico` 404 from a user's own
  HTML artifact is benign — wave it through. Your generated wrappers already suppress it.)
- ⚠️ **otherwise** → report the console errors verbatim and the screenshot; fix and redeploy.

Then **stop and tell the user to open the URL and eyeball it.**

## 7. Print the live URL

Output the final `https://…` URL plainly so the user can click it.

## Cleanup (only for self-tests)

When *you* generated throwaway test deploys, remove them afterward:
`vercel remove <name> --yes`, then confirm `vercel project ls` is clean. Never remove a
user's real project without asking.

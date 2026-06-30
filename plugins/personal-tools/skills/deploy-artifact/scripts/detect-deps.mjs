#!/usr/bin/env node
// detect-deps.mjs — scan artifact source files for bare imports that are NOT already
// baked into the template, and print them as a JSON array of npm package roots to install.
//
// Usage:  node detect-deps.mjs <file1> [file2 ...]
// Stdout: JSON array, e.g. ["three","d3"]   (clean — the skill parses this)
// Stderr: human-readable log of what was detected / skipped.
//
// The template already bakes react, react-dom, the full shadcn/ui set and its @radix-ui
// deps, lucide-react, recharts, and the shadcn helper libs. Anything the artifact imports
// that is a real npm package and is NOT in the template's package.json is emitted for
// on-demand `npm install`.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'
import { builtinModules } from 'node:module'

const here = dirname(fileURLToPath(import.meta.url))

let baked = new Set()
try {
  const pkg = JSON.parse(readFileSync(resolve(here, '../template/package.json'), 'utf8'))
  baked = new Set([
    ...Object.keys(pkg.dependencies || {}),
    ...Object.keys(pkg.devDependencies || {}),
  ])
} catch (e) {
  console.error(`[detect-deps] warning: could not read template package.json (${e.message})`)
}

const ALWAYS_SKIP = new Set(['react', 'react-dom', ...builtinModules])

// Normalize a bare specifier to its installable package root:
//   'chart.js/auto'   -> 'chart.js'
//   '@scope/name/sub' -> '@scope/name'
//   'lodash/debounce' -> 'lodash'
function pkgRoot(spec) {
  const parts = spec.split('/')
  if (spec.startsWith('@')) return parts.slice(0, 2).join('/')
  return parts[0]
}

const patterns = [
  /import\s+(?:[^'"]*?\s+from\s+)?['"]([^'"]+)['"]/g, // import x from 'y' | import 'y'
  /export\s+[^'"]*?\s+from\s+['"]([^'"]+)['"]/g,      // export { x } from 'y'
  /import\(\s*['"]([^'"]+)['"]\s*\)/g,                // dynamic import('y')
  /\brequire\(\s*['"]([^'"]+)['"]\s*\)/g,             // CJS require('y')
]

const files = process.argv.slice(2)
if (files.length === 0) {
  console.error('[detect-deps] no input files given')
  process.stdout.write('[]')
  process.exit(0)
}

const specs = new Set()
for (const f of files) {
  let src
  try {
    src = readFileSync(f, 'utf8')
  } catch (e) {
    console.error(`[detect-deps] skip unreadable file ${f}: ${e.message}`)
    continue
  }
  for (const re of patterns) {
    re.lastIndex = 0
    let m
    while ((m = re.exec(src)) !== null) specs.add(m[1])
  }
}

const install = new Set()
const skippedBaked = []
for (const s of specs) {
  if (s.startsWith('.') || s.startsWith('/')) continue   // relative / absolute
  if (s.startsWith('@/')) continue                       // '@' alias -> baked components/lib
  if (/^[a-z]+:/i.test(s)) continue                      // http:, https:, node:, data:
  const root = pkgRoot(s)
  if (ALWAYS_SKIP.has(root)) continue
  if (baked.has(root)) { skippedBaked.push(root); continue }
  install.add(root)
}

const result = [...install].sort()
if (result.length) console.error(`[detect-deps] on-demand installs: ${result.join(', ')}`)
else console.error('[detect-deps] no extra installs needed (all imports baked)')
if (skippedBaked.length) {
  console.error(`[detect-deps] already baked: ${[...new Set(skippedBaked)].sort().join(', ')}`)
}

process.stdout.write(JSON.stringify(result))

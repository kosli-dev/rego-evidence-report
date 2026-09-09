// Proof that editing the object does not cost the prose.
//
// Follows fieldkit/bundle.py's idiom: transform, then prove the transform
// preserved what it was not supposed to touch. Three properties, over the real
// example policies rather than over toys:
//
//   1. Applying a document's own YAML back to it changes nothing at all.
//   2. Touching every check forces every bullet through the writer, and the
//      recompiled object still equals the one asked for — which is
//      matchRule(write(c)) === c for every operator the examples use.
//   3. Every paragraph of prose in the source is still there afterwards, byte
//      for byte.
//
//   npm run roundtrip

import {readFileSync} from 'node:fs'
import {dirname, join} from 'node:path'
import {fileURLToPath} from 'node:url'
import process from 'node:process'
import {stringify as toYaml} from 'yaml'
import {analyze} from './core/index.ts'
import {applyYaml} from './web.ts'
import customOps from '../custom_ops.json' with {type: 'json'}
import type {CustomOpRegistry} from './core/types.ts'

const registry = (): CustomOpRegistry => {
	const raw = {...(customOps as Record<string, unknown>)}
	delete raw['_comment']
	return raw as CustomOpRegistry
}

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')

const POLICIES = ['examples/prod_deploy_md/policy.md', 'examples/control_43_md/policy.md', 'examples/multi_subject_md/policy.md']

let failures = 0
const fail = (where: string, message: string): void => {
	failures++
	console.log(`  FAIL ${where}: ${message}`)
}
const pass = (where: string): void => console.log(`  ok   ${where}`)

const yamlOf = (requirements: unknown): string => toYaml({requirements}, {lineWidth: 0})

/** The source text of every prose block, which no edit is allowed to disturb. */
function proseOf(markdown: string): string[] {
	const lines = markdown.split('\n')
	return analyze(markdown, {customOps: registry()})
		.blocks.filter((b) => b.kind === 'prose')
		.map((b) => lines.slice(b.line - 1, b.endLine).join('\n').trim())
		.filter((t) => t.length > 40)
}

for (const file of POLICIES) {
	console.log(`\n${file}`)
	const markdown = readFileSync(join(ROOT, file), 'utf8')
	const analysis = analyze(markdown, {customOps: registry()})
	if (!analysis.ok) {
		fail('compiles', analysis.diagnostics.filter((d) => d.severity === 'error').map((d) => d.message).join('; '))
		continue
	}

	// 1. The identity patch.
	const identity = applyYaml(markdown, yamlOf(analysis.requirements))
	if (identity.markdown !== markdown) fail('identity', 'applying the document’s own YAML rewrote it')
	else if (identity.changes.length || identity.refusals.length) fail('identity', `reported ${identity.changes.length} changes, ${identity.refusals.length} refusals`)
	else pass('identity')

	// 2. Every bullet through the writer.
	const target = JSON.parse(JSON.stringify(analysis.requirements)) as Record<string, Record<string, Record<string, Record<string, unknown>>>>
	let touched = 0
	for (const req of Object.values(target))
		for (const field of ['checks', 'applies_to'])
			for (const check of Object.values(req[field] ?? {})) {
				check['description'] = `rewritten by the round trip ${++touched}`
			}
	const rewritten = applyYaml(markdown, yamlOf(target))
	if (rewritten.refusals.length) fail('rewrite', `refused: ${rewritten.refusals.join('; ')}`)
	else if (rewritten.drift.length) fail('rewrite', `drift at ${rewritten.drift.join(', ')}`)
	else if (rewritten.changes.length !== touched) fail('rewrite', `rewrote ${rewritten.changes.length} of ${touched} checks`)
	else pass(`rewrite (${touched} checks through the writer)`)

	// 2b. Only the descriptions were asked for, so every rule sentence must come
	// back word for word — the writer reusing the author's own spelling, not the
	// declared one.
	const wording = (text: string): string[] => (text.match(/\*\*[^*]+\*\*/g) ?? []).sort()
	if (!rewritten.refusals.length && !rewritten.drift.length) {
		const was = wording(markdown)
		const now = wording(rewritten.markdown)
		if (was.join('|') !== now.join('|')) fail('wording', `bold spans changed: ${was.filter((w) => !now.includes(w)).join(', ')} -> ${now.filter((w) => !was.includes(w)).join(', ')}`)
		else pass('wording unchanged')
	}

	// 3. The prose is still there.
	const missing = proseOf(markdown).filter((p) => !rewritten.markdown.includes(p))
	if (missing.length) fail('prose', `${missing.length} paragraph(s) lost, first: "${missing[0]!.slice(0, 60)}…"`)
	else pass('prose survives')

	// 4. A check on a path the table does not name. The object is complete; the
	// Markdown is the side that is missing something, and the writer names it.
	const grown = JSON.parse(JSON.stringify(analysis.requirements)) as Record<string, {checks: Record<string, unknown>; subject_type?: string}>
	const host = Object.keys(grown)[0]!
	grown[host]!.checks['round_trip_probe'] = {
		op: 'non_empty_string',
		path: ['probe', 'undeclared_field'],
		description: 'A field nobody named in the table',
	}
	const added = applyYaml(markdown, yamlOf(grown))
	if (added.refusals.length) fail('declare', `refused: ${added.refusals.join('; ')}`)
	else if (added.drift.length) fail('declare', `drift at ${added.drift.join(', ')}`)
	else if (!/\|\s*`probe\.undeclared_field`\s*\|/.test(added.markdown)) fail('declare', 'the property table gained no row')
	else if (proseOf(markdown).some((p) => !added.markdown.includes(p))) fail('declare', 'prose lost')
	else pass('declare a path the table does not name')

	// 5. Typing your way to a path repoints one row; it does not stack a row per
	// keystroke. Three successive edits to the same path, each applied to what
	// the last one produced.
	const rows = (text: string): number => text.split('\n').filter((l) => /^\s*\|/.test(l)).length
	const pick = (spec: Record<string, {checks?: Record<string, {path?: unknown[]}>}>): [string, string] | null => {
		for (const [req, body] of Object.entries(spec))
			for (const [check, def] of Object.entries(body.checks ?? {}))
				if (Array.isArray(def.path) && typeof def.path[def.path.length - 1] === 'string') return [req, check]
		return null
	}
	const chosen = pick(analysis.requirements as never)
	if (chosen) {
		const [req, check] = chosen
		const width = rows(markdown)
		let doc = markdown
		let broke = ''
		for (const suffix of ['z', 'zz', '_2']) {
			const spec = JSON.parse(JSON.stringify(analyze(doc, {customOps: registry()}).requirements)) as Record<string, {checks: Record<string, {path: string[]}>}>
			const path = spec[req]!.checks[check]!.path
			path[path.length - 1] = String(path[path.length - 1]).replace(/(z|zz|_2)$/, '') + suffix
			const step = applyYaml(doc, yamlOf(spec))
			if (!step.ok) {
				broke = `${suffix}: ${[...step.refusals, ...step.drift].join('; ')}`
				break
			}
			doc = step.markdown
		}
		if (broke) fail('repoint', broke)
		else if (rows(doc) !== width) fail('repoint', `the table went from ${width} lines to ${rows(doc)}`)
		else pass(`repoint ${req}.${check} through three path edits`)
	}

	// 6. Removing one check takes its bullet and nothing else.
	const firstReq = Object.keys(analysis.requirements)[0]!
	const cut = JSON.parse(JSON.stringify(analysis.requirements)) as Record<string, {checks: Record<string, unknown>}>
	const names = Object.keys(cut[firstReq]!.checks)
	if (names.length > 1) {
		delete cut[firstReq]!.checks[names[names.length - 1]!]
		const removed = applyYaml(markdown, yamlOf(cut))
		const stillThere = proseOf(markdown).filter((p) => !removed.markdown.includes(p))
		if (removed.drift.length) fail('remove', `drift at ${removed.drift.join(', ')}`)
		else if (stillThere.length) fail('remove', `${stillThere.length} paragraph(s) lost`)
		else pass(`remove ${firstReq}.${names[names.length - 1]}`)
	}
}

console.log(failures ? `\n${failures} failing\n` : '\nall round trips hold\n')
process.exit(failures ? 1 : 0)

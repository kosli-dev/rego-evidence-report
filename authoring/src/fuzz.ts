// A QA harness: long random sequences of object edits, each applied to what the
// last one produced, with the invariants checked after every step.
//
//   npx tsx src/fuzz.ts [steps] [seeds]

import {readFileSync} from 'node:fs'
import {dirname, join} from 'node:path'
import {fileURLToPath} from 'node:url'
import process from 'node:process'
import {stringify as toYaml} from 'yaml'
import {analyze} from './core/index.ts'
import {applyYaml} from './web.ts'
import customOps from '../custom_ops.json' with {type: 'json'}
import type {CustomOpRegistry} from './core/types.ts'

const reg = (): CustomOpRegistry => {
	const raw = {...(customOps as Record<string, unknown>)}
	delete raw['_comment']
	return raw as CustomOpRegistry
}
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const POLICIES = ['examples/prod_deploy_md/policy.md', 'examples/control_43_md/policy.md', 'examples/multi_subject_md/policy.md']

const yamlOf = (r: unknown): string => toYaml({requirements: r}, {lineWidth: 0})
const clone = <T>(v: T): T => JSON.parse(JSON.stringify(v)) as T

function rng(seed: number): () => number {
	let a = seed >>> 0
	return () => {
		a += 0x6d2b79f5
		let t = a
		t = Math.imul(t ^ (t >>> 15), t | 1)
		t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
		return ((t ^ (t >>> 14)) >>> 0) / 4294967296
	}
}
const pick = <T>(r: () => number, xs: T[]): T => xs[Math.floor(r() * xs.length)]!

type Spec = Record<string, Record<string, unknown>>
const checksOf = (req: Record<string, unknown>): Record<string, Record<string, unknown>> => (req['checks'] ?? {}) as never
const scopeOf = (req: Record<string, unknown>): Record<string, Record<string, unknown>> => (req['applies_to'] ?? {}) as never

/** Prose paragraphs: blocks outside every bullet. A check's description lives
 *  in a bullet, so removing a check must still cost none of these. */
function prose(markdown: string): string[] {
	const lines = markdown.split('\n')
	return analyze(markdown, {customOps: reg()})
		.blocks.filter((b) => b.kind === 'prose')
		.map((b) => lines.slice(b.line - 1, b.endLine).join('\n').trim())
		.filter((t) => t.length > 40)
}

/** An edit made to the document itself, between object edits. The object must
 *  come out unchanged: these are all things only the Markdown can say. */
interface Hand {
	name: string
	go: (doc: string, r: () => number) => string | null
}

const HANDS: Hand[] = [
	{
		name: 'insert a paragraph of rationale',
		go: (doc, r) => {
			// Not straight after a lead-in: "In scope:", "Must hold:" and the
			// sentence naming a constant all bind to the list under them, and
			// pushing them apart is an edit that ought to fail.
			const spots = [...doc.matchAll(/\n\n/g)].map((m) => m.index + 2).filter((at) => !/:\s*$/.test(doc.slice(0, at - 2).split('\n').pop() ?? ''))
			if (!spots.length) return null
			const at = pick(r, spots)
			const text = `Rationale ${Math.floor(r() * 9000 + 1000)}: this paragraph explains a decision and must survive every edit that follows it.`
			return doc.slice(0, at) + text + '\n\n' + doc.slice(at)
		},
	},
	{
		name: 'reflow a bullet onto one line',
		go: (doc, r) => {
			const lines = doc.split('\n')
			const starts = lines.map((l, i) => [l, i] as const).filter(([l]) => /^- `/.test(l)).map(([, i]) => i)
			if (!starts.length) return null
			const at = pick(r, starts)
			let end = at
			while (end + 1 < lines.length && /^\s\s\S/.test(lines[end + 1] ?? '')) end++
			if (end === at) return null
			const joined = lines.slice(at, end + 1).map((l) => l.trim()).join(' ')
			return [...lines.slice(0, at), joined, ...lines.slice(end + 1)].join('\n')
		},
	},
	{
		name: 'declare a property nothing reads',
		go: (doc, r) => {
			const lines = doc.split('\n')
			let last = -1
			for (let i = 0; i < lines.length; i++) if (/^\|/.test(lines[i] ?? '')) last = i
			if (last < 0) return null
			const n = Math.floor(r() * 9000 + 1000)
			return [...lines.slice(0, last + 1), `| spare ${n} | \`spare_${n}\` |`, ...lines.slice(last + 1)].join('\n')
		},
	},
]

interface Move {
	name: string
	/** Returns a label, or null when it does not apply to this document. */
	go: (spec: Spec, r: () => number) => string | null
	/** True when the move is allowed to cost prose. */
	destructive?: boolean
	/** Refusals this move is expected to provoke, because it can produce an
	 *  object with no prose form. Anything else it is refused for is a bug. */
	mayRefuse?: RegExp
}

const MOVES: Move[] = [
	{
		name: 'rename a check',
		go: (spec, r) => {
			const req = pick(r, Object.keys(spec))
			const names = Object.keys(checksOf(spec[req]!))
			if (names.length < 2) return null
			const from = pick(r, names)
			const to = `${from}_r${Math.floor(r() * 900 + 100)}`
			checksOf(spec[req]!)[to] = checksOf(spec[req]!)[from]!
			delete checksOf(spec[req]!)[from]
			return `${req}.${from} -> ${to}`
		},
	},
	{
		name: 'rename a scope filter',
		go: (spec, r) => {
			const req = Object.keys(spec).find((k) => Object.keys(scopeOf(spec[k]!)).length)
			if (!req) return null
			const from = pick(r, Object.keys(scopeOf(spec[req]!)))
			const to = `${from}_s${Math.floor(r() * 900 + 100)}`
			scopeOf(spec[req]!)[to] = scopeOf(spec[req]!)[from]!
			delete scopeOf(spec[req]!)[from]
			return `${req}.${from} -> ${to}`
		},
	},
	{
		name: 'change a description',
		go: (spec, r) => {
			const req = pick(r, Object.keys(spec))
			const names = Object.keys(checksOf(spec[req]!))
			if (!names.length) return null
			const name = pick(r, names)
			checksOf(spec[req]!)[name]!['description'] = `Reworded ${Math.floor(r() * 1000)}`
			return `${req}.${name}`
		},
	},
	{
		name: 'drop a description',
		go: (spec, r) => {
			const req = pick(r, Object.keys(spec))
			const named = Object.keys(checksOf(spec[req]!)).filter((n) => checksOf(spec[req]!)[n]!['description'])
			if (!named.length) return null
			const name = pick(r, named)
			delete checksOf(spec[req]!)[name]!['description']
			return `${req}.${name}`
		},
	},
	{
		name: 'change a leaf value',
		go: (spec, r) => {
			for (const req of Object.keys(spec))
				for (const [name, check] of Object.entries(checksOf(spec[req]!)))
					if (check['op'] === 'equals') {
						check['value'] = `v${Math.floor(r() * 1000)}`
						return `${req}.${name}`
					}
			return null
		},
	},
	{
		name: 'change a path',
		go: (spec, r) => {
			const spots: Array<[string, string, string[]]> = []
			for (const req of Object.keys(spec))
				for (const [name, check] of Object.entries(checksOf(spec[req]!))) {
					const path = check['path']
					if (check['expression']) continue
					if (Array.isArray(path) && path.length && typeof path[path.length - 1] === 'string') spots.push([req, name, path as string[]])
				}
			if (!spots.length) return null
			const [req, name, path] = pick(r, spots)
			path[path.length - 1] = `f${Math.floor(r() * 1000)}`
			return `${req}.${name}`
		},
	},
	{
		name: 'add a check',
		go: (spec, r) => {
			const req = pick(r, Object.keys(spec))
			const name = `added_${Math.floor(r() * 9000 + 1000)}`
			checksOf(spec[req]!)[name] = {op: 'non_empty_string', path: [`field_${Math.floor(r() * 100)}`], description: 'Added by the fuzzer'}
			return `${req}.${name}`
		},
	},
	{
		name: 'remove a check',
		destructive: true,
		go: (spec, r) => {
			const req = Object.keys(spec).find((k) => Object.keys(checksOf(spec[k]!)).length > 1)
			if (!req) return null
			const name = pick(r, Object.keys(checksOf(spec[req]!)))
			delete checksOf(spec[req]!)[name]
			return `${req}.${name}`
		},
	},
	{
		name: 'remove a scope filter',
		destructive: true,
		go: (spec, r) => {
			const req = Object.keys(spec).find((k) => Object.keys(scopeOf(spec[k]!)).length)
			if (!req) return null
			const name = pick(r, Object.keys(scopeOf(spec[req]!)))
			delete scopeOf(spec[req]!)[name]
			if (!Object.keys(scopeOf(spec[req]!)).length) delete spec[req]!['applies_to']
			return `${req}.${name}`
		},
	},
	{
		name: 'add a scope filter',
		go: (spec, r) => {
			const req = pick(r, Object.keys(spec))
			const name = `scope_${Math.floor(r() * 9000 + 1000)}`
			spec[req]!['applies_to'] = {...scopeOf(spec[req]!), [name]: {op: 'present', path: [`gate_${Math.floor(r() * 100)}`]}}
			return `${req}.${name}`
		},
	},
	{
		name: 'set min_subjects',
		go: (spec, r) => {
			const req = pick(r, Object.keys(spec))
			spec[req]!['min_subjects'] = Math.floor(r() * 3)
			return `${req} = ${String(spec[req]!['min_subjects'])}`
		},
		destructive: true,
	},
	{
		name: 'unset min_subjects',
		destructive: true,
		go: (spec, r) => {
			const req = Object.keys(spec).find((k) => spec[k]!['min_subjects'] !== undefined)
			if (!req) return null
			delete spec[req]!['min_subjects']
			return req
		},
	},
	{
		name: 'toggle require',
		go: (spec, r) => {
			const req = pick(r, Object.keys(spec))
			if (spec[req]!['require'] === 'some') delete spec[req]!['require']
			else spec[req]!['require'] = 'some'
			return req
		},
	},
	{
		name: 'an awkward description',
		mayRefuse: /trailing full stop|cannot be written as Markdown/,
		go: (spec, r) => {
			const req = pick(r, Object.keys(spec))
			const names = Object.keys(checksOf(spec[req]!))
			if (!names.length) return null
			const name = pick(r, names)
			const awkward = [
				'It ends with a full stop.',
				'Two sentences. The second one matters as much as the first.',
				'The field is `approved_by`, and it is read verbatim',
				'A **bold** claim, and an em dash \u2014 both of them',
				'A pipe | in the middle, which a table cell could not hold',
				'Records for audit are kept elsewhere',
				'A very long description that will certainly have to wrap more than once because it goes on and on well past any sensible column width',
				'\u00abGuillemets\u00bb and a \u2014 dash',
			]
			const text = pick(r, awkward)
			checksOf(spec[req]!)[name]!['description'] = text
			return `${req}.${name} = "${text.slice(0, 24)}\u2026"`
		},
	},
	{
		name: 'an awkward value',
		mayRefuse: /would be read back as/,
		go: (spec, r) => {
			for (const req of Object.keys(spec))
				for (const [name, check] of Object.entries(checksOf(spec[req]!)))
					if (check['op'] === 'equals') {
						check['value'] = pick(r, ['a b c', 'with `backtick`', 'a|pipe', 'trailing.', '\u2014dash', 'true', '42'])
						return `${req}.${name}`
					}
			return null
		},
	},
	{
		name: 'an awkward path segment',
		mayRefuse: /cannot be declared/,
		go: (spec, r) => {
			for (const req of Object.keys(spec))
				for (const [name, check] of Object.entries(checksOf(spec[req]!))) {
					const path = check['path']
					if (check['expression'] || check['inputs']) continue
					if (Array.isArray(path) && path.length && typeof path[path.length - 1] === 'string') {
						path[path.length - 1] = pick(r, ['with space', 'with|pipe', 'with`tick', 'UPPER_case', 'x'.repeat(60)])
						return `${req}.${name}`
					}
				}
			return null
		},
	},
	{
		name: 'change patterns',
		go: (spec, r) => {
			for (const req of Object.keys(spec))
				for (const [name, check] of Object.entries(checksOf(spec[req]!)))
					if (check['op'] === 'matches_any' || check['op'] === 'not_matches_any') {
						check['patterns'] = [`^a.${Math.floor(r() * 100)}$`, '^b|c$']
						return `${req}.${name}`
					}
			return null
		},
	},
	{
		name: 'reorder the checks',
		go: (spec, r) => {
			const req = pick(r, Object.keys(spec))
			const entries = Object.entries(checksOf(spec[req]!))
			if (entries.length < 2) return null
			spec[req]!['checks'] = Object.fromEntries(entries.reverse())
			return req
		},
	},
	{
		name: 'add a requirement',
		go: (spec, r) => {
			const first = spec[Object.keys(spec)[0]!]!
			const name = `req_${Math.floor(r() * 9000 + 1000)}`
			spec[name] = {
				subject_type: first['subject_type'],
				from: clone(first['from']),
				id: clone(first['id']),
				checks: {[`${name}_check`]: {op: 'present', path: [`brand_new_${Math.floor(r() * 100)}`], description: 'Added whole'}},
			}
			return name
		},
	},
	{
		name: 'remove a requirement',
		destructive: true,
		go: (spec, r) => {
			const names = Object.keys(spec)
			if (names.length < 2) return null
			const name = pick(r, names)
			delete spec[name]
			return name
		},
	},
	{
		name: 'change an operator',
		go: (spec, r) => {
			for (const req of Object.keys(spec))
				for (const [name, check] of Object.entries(checksOf(spec[req]!)))
					if (check['op'] === 'non_empty_string') {
						check['op'] = 'present'
						return `${req}.${name}`
					}
			return null
		},
	},
]

const steps = Number(process.argv[2] ?? 14)
const seeds = Number(process.argv[3] ?? 30)
/** `npx tsx src/fuzz.ts 40 250 114` replays one seed and dumps the failure. */
const only = process.argv[4] ? Number(process.argv[4]) : null
const failures = new Map<string, {where: string; detail: string}>()

for (const file of POLICIES) {
	const source = readFileSync(join(ROOT, file), 'utf8')
	for (let seed = only ?? 1; seed <= (only ?? seeds); seed++) {
		const r = rng(seed * 7919)
		let doc = source
		const trail: string[] = []

		for (let step = 0; step < steps; step++) {
			const before = analyze(doc, {customOps: reg()})
			if (!before.ok) break
			const spec = clone(before.requirements) as Spec
			const order = [...MOVES].sort(() => r() - 0.5)
			let move: Move | null = null
			let label: string | null = null
			for (const candidate of order) {
				label = candidate.go(spec, r)
				if (label) {
					move = candidate
					break
				}
			}
			if (!move) break
			trail.push(`${move.name} (${label})`)

			// Every few steps, edit the document by hand instead — the object
			// must come back unchanged, and the anchors must survive it.
			if (r() < 0.35) {
				const hand = pick(r, HANDS)
				const edited = hand.go(doc, r)
				if (edited) {
					const now = analyze(edited, {customOps: reg()})
					const key = `${hand.name}: by hand`
					if (!now.ok) failures.set(key, {where: `${file} seed ${seed} step ${step + 1}`, detail: now.diagnostics.filter((d) => d.severity === 'error').map((d) => d.message).join('; ')})
					else if (yamlOf(now.requirements) !== yamlOf(analyze(doc, {customOps: reg()}).requirements))
						failures.set(key, {where: `${file} seed ${seed} step ${step + 1}`, detail: 'the object changed'})
					else {
						doc = edited
						trail.push(`[by hand] ${hand.name}`)
					}
				}
			}

			const was = doc
			const res = applyYaml(doc, yamlOf(spec))
			const say = (kind: string, detail: string): void => {
				const key = `${move!.name}: ${kind}`
				if (only) {
					const at = res.drift[0]?.split('.') ?? []
					const dig = (o: unknown): unknown => at.reduce<unknown>((v, k) => (v as Record<string, unknown> | undefined)?.[k], o)
					console.log(`\n${key}\n  wanted ${JSON.stringify(dig(spec))}\n  got    ${JSON.stringify(dig(analyze(res.markdown, {customOps: reg()}).requirements))}`)
					console.log(res.markdown.split('\n').filter((l) => /^\s*- `/.test(l)).join('\n'))
				}
				if (!failures.has(key)) failures.set(key, {where: `${file} seed ${seed} step ${step + 1}`, detail: `${detail}\n      after: ${trail.join(' -> ')}`})
			}

			const expected = move.mayRefuse && res.refusals.length && res.refusals.every((x) => move.mayRefuse!.test(x))
			if (res.error) say('yaml did not parse', res.error)
			else if (expected) {
				// A refusal it is entitled to. The document must be left alone.
				const still = analyze(doc, {customOps: reg()})
				if (!still.ok) say('refused but broke the document', res.refusals.join('; '))
			} else if (res.refusals.length) say('refused', res.refusals.join('; '))
			else if (res.drift.length) say('drift', res.drift.join(', '))
			else {
				const after = analyze(res.markdown, {customOps: reg()})
				if (!after.ok) say('document no longer compiles', after.diagnostics.filter((d) => d.severity === 'error').map((d) => `L${d.line} ${d.message}`).join('; '))
				else {
					if (!move.destructive) {
						const lost = prose(was).filter((p) => !res.markdown.includes(p))
						if (lost.length) say('prose lost', `"${lost[0]!.slice(0, 70)}…"`)
					}
					const again = applyYaml(res.markdown, yamlOf(after.requirements))
					if (again.markdown !== res.markdown || again.changes.length) say('not idempotent', `re-applying its own YAML changed ${again.changes.length} thing(s)`)
				}
				doc = res.markdown
			}
		}
	}
}

if (!failures.size) console.log('\nno failures\n')
else {
	console.log(`\n${failures.size} distinct failure(s):\n`)
	for (const [what, {where, detail}] of failures) console.log(`  ${what}\n    ${where}\n      ${detail}\n`)
}
process.exit(failures.size ? 1 : 0)

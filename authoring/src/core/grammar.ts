// Sentence matching. A sentence becomes a check only if it references a
// *declared* property, which is what lets rationale say "must" as often as it
// likes without being parsed.
//
// Inline markup is flattened to atoms and then to a normalised string in which
// every bold span is «pN» and every code span is «cN». Matching is then plain
// regex over a string with no markup in it, and the captured indices point back
// at the original spans.

import type {Check, CustomOpRegistry, Path, PropertyDef} from './types.ts'
import {literal} from './paths.ts'

export type Atom = {kind: 'text' | 'code' | 'prop'; text: string}

export interface Ctx {
	props: Map<string, PropertyDef>
	constants: Map<string, unknown[]>
	substitutes: Map<string, Check>
	customOps: CustomOpRegistry
}

interface Inline {
	type: string
	value?: string
	children?: Inline[]
}

/** Flatten an mdast paragraph's inline children into atoms. */
export function atomize(children: Inline[]): Atom[] {
	const out: Atom[] = []
	const walk = (nodes: Inline[], strong: boolean): void => {
		for (const n of nodes) {
			if (n.type === 'text') out.push({kind: strong ? 'prop' : 'text', text: n.value ?? ''})
			else if (n.type === 'inlineCode') out.push({kind: strong ? 'prop' : 'code', text: n.value ?? ''})
			else if (n.type === 'strong') walk(n.children ?? [], true)
			else if (n.type === 'break') out.push({kind: 'text', text: ' '})
			else if (n.children) walk(n.children, strong)
		}
	}
	walk(children, false)
	// A bold span split across nodes arrives as adjacent prop atoms; join them.
	const merged: Atom[] = []
	for (const a of out) {
		const last = merged[merged.length - 1]
		if (last && last.kind === a.kind && a.kind !== 'code') last.text += a.text
		else merged.push({...a})
	}
	return merged
}

/** Split atoms into sentences at `. ` boundaries in plain text only, so a full
 *  stop inside a regex or a path never ends a sentence. */
export function sentences(atoms: Atom[]): Atom[][] {
	const out: Atom[][] = []
	let cur: Atom[] = []
	for (const a of atoms) {
		if (a.kind !== 'text') {
			cur.push(a)
			continue
		}
		let rest = a.text
		for (;;) {
			const m = /\.(\s+|$)/.exec(rest)
			if (!m) break
			cur.push({kind: 'text', text: rest.slice(0, m.index + 1)})
			out.push(cur)
			cur = []
			rest = rest.slice(m.index + m[0].length)
		}
		if (rest) cur.push({kind: 'text', text: rest})
	}
	if (cur.some((a) => a.text.trim())) out.push(cur)
	return out
}

export function plain(atoms: Atom[]): string {
	return atoms
		.map((a) => a.text)
		.join('')
		.replace(/\s+/g, ' ')
		.trim()
}

interface Norm {
	s: string
	props: string[]
	codes: string[]
}

export function normalize(atoms: Atom[]): Norm {
	const props: string[] = []
	const codes: string[] = []
	let s = ''
	for (const a of atoms) {
		if (a.kind === 'prop') s += `«p${props.push(a.text) - 1}»`
		else if (a.kind === 'code') s += `«c${codes.push(a.text) - 1}»`
		else s += a.text
	}
	return {s: s.replace(/\s+/g, ' ').trim(), props, codes}
}

const P = '«p(\\d+)»'
const C = '«c(\\d+)»'

/** Look a property up tolerantly: rules read naturally in the singular even
 *  when the table declares a plural, and vice versa. */
export function lookup(ctx: Ctx, display: string): PropertyDef | undefined {
	const key = display.toLowerCase().replace(/\s+/g, ' ').trim()
	return (
		ctx.props.get(key) ??
		ctx.props.get(key + 's') ??
		(key.endsWith('s') ? ctx.props.get(key.slice(0, -1)) : undefined)
	)
}

/** The path of a property up to its first collection boundary. */
function outerPath(p: PropertyDef): Path {
	return p.splits.length ? p.path.slice(0, p.splits[0]) : p.path
}

/** The path of a property after its last collection boundary — what a check
 *  inside `all`/`any` addresses, relative to one element. */
function innerPath(p: PropertyDef): Path {
	return p.splits.length ? p.path.slice(p.splits[p.splits.length - 1]) : p.path
}

const CMP: Record<string, {cmp: string; time: boolean}> = {
	'equal to': {cmp: 'eq', time: false},
	'different from': {cmp: 'ne', time: false},
	'greater than': {cmp: 'gt', time: false},
	'at least': {cmp: 'gte', time: false},
	'less than': {cmp: 'lt', time: false},
	'at most': {cmp: 'lte', time: false},
	after: {cmp: 'gt', time: true},
	'at or after': {cmp: 'gte', time: true},
	before: {cmp: 'lt', time: true},
	'at or before': {cmp: 'lte', time: true},
}

export class RuleError extends Error {}

function patternsOf(n: Norm, rest: string, ctx: Ctx): unknown[] {
	const one = new RegExp(`^${P}$`).exec(rest)
	if (one) {
		const name = (n.props[Number(one[1])] ?? '').toLowerCase().trim()
		const found = ctx.constants.get(name)
		if (!found) throw new RuleError(`no constant named "${name}"`)
		return found
	}
	const out: unknown[] = []
	const re = new RegExp(C, 'g')
	for (let m = re.exec(rest); m; m = re.exec(rest)) out.push(n.codes[Number(m[1])])
	if (!out.length) throw new RuleError(`expected a list of patterns, or a constant, in "${rest}"`)
	return out
}

/** The predicate half of a leaf rule, applied at `path`. */
function predicate(n: Norm, rest: string, path: Path, ctx: Ctx): Check {
	let m: RegExpExecArray | null

	if (/^(?:be present|exist)$/.test(rest)) return {op: 'present', path}
	if (rest === 'be a non-empty string') return {op: 'non_empty_string', path}

	if ((m = new RegExp(`^be ${C}$`).exec(rest))) return {op: 'equals', path, value: literal(n.codes[Number(m[1])] ?? '')}

	if ((m = new RegExp(`^be between ${C} and ${C}$`).exec(rest)))
		return {op: 'range', path, min: literal(n.codes[Number(m[1])] ?? ''), max: literal(n.codes[Number(m[2])] ?? '')}

	if ((m = new RegExp(`^include ${C}$`).exec(rest))) return {op: 'includes', path, value: literal(n.codes[Number(m[1])] ?? '')}
	if ((m = new RegExp(`^not include ${C}$`).exec(rest))) return {op: 'excludes', path, value: literal(n.codes[Number(m[1])] ?? '')}

	if ((m = /^match one of (.+)$/.exec(rest))) return {op: 'matches_any', path, patterns: patternsOf(n, m[1] ?? '', ctx)}
	if ((m = /^match none of (.+)$/.exec(rest))) return {op: 'not_matches_any', path, patterns: patternsOf(n, m[1] ?? '', ctx)}

	if ((m = new RegExp(`^be (${Object.keys(CMP).join('|')}) the ${P}$`).exec(rest))) {
		const spec = CMP[m[1] ?? '']
		const right = lookup(ctx, n.props[Number(m[2])] ?? '')
		if (!spec) throw new RuleError(`unknown comparison "${m[1]}"`)
		if (!right) throw new RuleError(`no declared property named "${n.props[Number(m[2])]}"`)
		return {op: spec.time ? 'compare_time' : 'compare', left: path, right: right.path, cmp: spec.cmp}
	}

	throw new RuleError(`no operator matches "${rest}"`)
}

/** The clause inside `every X must …` / `at least one X must …`, addressed
 *  relative to one element of the collection. */
function elementCheck(n: Norm, rest: string, ctx: Ctx): Check {
	let m: RegExpExecArray | null
	if ((m = new RegExp(`^have an? ${P} of ${C}$`).exec(rest))) {
		const prop = lookup(ctx, n.props[Number(m[1])] ?? '')
		if (!prop) throw new RuleError(`no declared property named "${n.props[Number(m[1])]}"`)
		return {op: 'equals', path: innerPath(prop), value: literal(n.codes[Number(m[2])] ?? '')}
	}
	if ((m = new RegExp(`^have an? ${P} that must (.+)$`).exec(rest))) {
		const prop = lookup(ctx, n.props[Number(m[1])] ?? '')
		if (!prop) throw new RuleError(`no declared property named "${n.props[Number(m[1])]}"`)
		return predicate(n, m[2] ?? '', innerPath(prop), ctx)
	}
	return predicate(n, rest, [], ctx)
}

export interface Matched {
	check: Check
	op: string
}

/**
 * Match one sentence. Returns null when it is not a rule at all — no declared
 * property, or no operator — which is the ordinary case for rationale.
 * Throws RuleError when it is *nearly* a rule, which is the case worth
 * reporting: the library would have accepted the result and never passed it.
 */
export function matchRule(atoms: Atom[], ctx: Ctx, nearMiss = true): Matched | null {
	const n = normalize(atoms)
	let s = n.s.replace(/\.$/, '')
	let m: RegExpExecArray | null

	const extra: Check = {}

	// ", or else `name`" — a declared substitute.
	if ((m = new RegExp(`,? or else ${C}$`).exec(s))) {
		const name = n.codes[Number(m[1])] ?? ''
		const sub = ctx.substitutes.get(name)
		if (!sub) throw new RuleError(`no substitute named "${name}"`)
		extra['substitute'] = sub
		s = s.slice(0, m.index).trim()
	}

	// ", treating **constant** as explained" — a pattern list for a custom op.
	if ((m = new RegExp(`,? treating ${P} as explained$`).exec(s))) {
		const name = (n.props[Number(m[1])] ?? '').toLowerCase().trim()
		const found = ctx.constants.get(name)
		if (!found) throw new RuleError(`no constant named "${name}"`)
		extra['patterns'] = found
		s = s.slice(0, m.index).trim()
	}

	// A custom operator: the prose names it and what it applies to.
	if ((m = new RegExp(`^(?:some|every|at least one|the) ${P} must (.+)$`).exec(s))) {
		const phrase = m[2] ?? ''
		for (const [op, def] of Object.entries(ctx.customOps)) {
			if (def.phrase !== phrase) continue
			const prop = lookup(ctx, n.props[Number(m[1])] ?? '')
			if (!prop) throw new RuleError(`no declared property named "${n.props[Number(m[1])]}"`)
			const path = outerPath(prop)
			return {
				op,
				check: {
					op,
					expression: def.expression,
					path,
					...extra,
					inputs: def.inputs.map((i) => ('subject' in i ? i.subject : {path, each: i.each})),
				},
			}
		}
	}

	// Collection operators.
	if ((m = new RegExp(`^every ${P} must (.+)$`).exec(s))) {
		const prop = lookup(ctx, n.props[Number(m[1])] ?? '')
		if (!prop) throw new RuleError(`no declared property named "${n.props[Number(m[1])]}"`)
		return {op: 'all', check: {op: 'all', ...collection(prop), check: elementCheck(n, m[2] ?? '', ctx), ...extra}}
	}
	if ((m = new RegExp(`^(?:at least one|some) ${P} must (.+)$`).exec(s))) {
		const prop = lookup(ctx, n.props[Number(m[1])] ?? '')
		if (!prop) throw new RuleError(`no declared property named "${n.props[Number(m[1])]}"`)
		return {op: 'any', check: {op: 'any', ...collection(prop), check: elementCheck(n, m[2] ?? '', ctx), ...extra}}
	}

	// Leaf operators.
	if ((m = new RegExp(`^the ${P} must (.+)$`).exec(s))) {
		const prop = lookup(ctx, n.props[Number(m[1])] ?? '')
		if (!prop) throw new RuleError(`no declared property named "${n.props[Number(m[1])]}"`)
		const check = predicate(n, m[2] ?? '', prop.path, ctx)
		return {op: String(check['op']), check: {...check, ...extra}}
	}

	// Not a rule. Report it only if it looks like one that failed to land.
	if (nearMiss && /\b(?:must|shall|never|always)\b/.test(n.s) && (n.props.length || n.codes.length))
		throw new RuleError(`this looks like a rule but matches no operator: "${n.s}"`)

	return null
}

function collection(prop: PropertyDef): Check {
	if (prop.splits.length >= 2)
		return {
			path: prop.path.slice(0, prop.splits[0]),
			each: prop.path.slice(prop.splits[0], prop.splits[1]),
		}
	return {path: outerPath(prop)}
}

/** "Records the **X**' `field`." — an extra entry in the check's `inputs`. */
export function matchRecords(atoms: Atom[], ctx: Ctx): Check | null {
	const n = normalize(atoms)
	const m = new RegExp(`^Records the ${P}'?s? ${C}\\.?$`).exec(n.s)
	if (!m) return null
	const prop = lookup(ctx, n.props[Number(m[1])] ?? '')
	if (!prop) throw new RuleError(`no declared property named "${n.props[Number(m[1])]}"`)
	return {path: outerPath(prop), each: [n.codes[Number(m[2])] ?? '']}
}

// The other direction: a check, written back as the sentence that produces it.
//
// This exists so an edit made to the compiled object can be returned to the
// Markdown that produced it. It is deliberately *not* a Markdown generator —
// nothing here ever writes a document. It writes one bullet, and patch.ts
// splices that bullet into the source the author wrote, leaving every
// surrounding paragraph exactly as it was.
//
// The predicate half of each rule is written by the same table that matches it
// (`LEAVES` in grammar.ts, one row carrying prose, regex, builder and writer),
// so the two directions cannot drift apart in the ordinary way — and
// `npm run roundtrip` asserts matchRule(render(c)) === c for every operator.

import type {Check, CustomOpRegistry, DocContext, Path, PropertyDef} from './types.ts'
import {LEAF_TABLE, type RenderHelp, RuleError, outerPath, innerPath} from './grammar.ts'

export interface RenderCtx {
	props: PropertyDef[]
	constants: Record<string, unknown[]>
	substitutes: Record<string, Check>
	customOps: CustomOpRegistry
}

export function contextFor(doc: DocContext, requirement: string, customOps: CustomOpRegistry): RenderCtx {
	return {
		props: doc.properties[requirement] ?? doc.all,
		constants: doc.constants,
		substitutes: doc.substitutes,
		customOps,
	}
}

const same = (a: unknown, b: unknown): boolean => JSON.stringify(a) === JSON.stringify(b)

/** The same tolerant match `lookup` in grammar.ts makes, so a spelling the
 *  author used is only reused when it still names the property it named. */
function names(prop: PropertyDef, written: string | undefined): boolean {
	if (!written) return false
	const norm = (t: string): string => t.toLowerCase().replace(/\s+/g, ' ').trim()
	const a = norm(written)
	const b = norm(prop.display)
	return a === b || a + 's' === b || a === b + 's'
}

/** The subject property, spelled the way the author spelled it where that
 *  still resolves — "every **CI check**" over a table that says "CI checks". */
const spell = (prop: PropertyDef, written?: string): string => bold(names(prop, written) ? written! : prop.display)

/** A literal, back in backticks. A value holding a backtick is fenced with two,
 *  which is what CommonMark asks for and what the parser reads back. */
export function code(v: unknown): string {
	const text = v === null ? 'null' : String(v)
	if (!text.includes('`')) return `\`${text}\``
	return `\`\` ${text} \`\``
}

const bold = (display: string): string => `**${display}**`
const article = (word: string): string => (/^[aeiou]/i.test(word) ? 'an' : 'a')

function property(ctx: RenderCtx, path: Path): PropertyDef {
	const found = ctx.props.find((p) => same(p.path, path))
	if (!found) throw new RuleError(`no declared property has the path \`${JSON.stringify(path)}\` — add a row to the Subjects table first`)
	return found
}

function patternsClause(ctx: RenderCtx, values: unknown[]): string {
	for (const [name, held] of Object.entries(ctx.constants)) if (same(held, values)) return bold(name)
	return values.map(code).join(', ')
}

function help(ctx: RenderCtx): RenderHelp {
	return {
		code,
		patterns: (values) => patternsClause(ctx, values),
		property: (path) => bold(property(ctx, path).display),
	}
}

/** The predicate half — everything after "must". */
function predicate(ctx: RenderCtx, check: Check): string {
	const row = LEAF_TABLE.find((l) => l.produces === check['op'])
	if (!row) throw new RuleError(`no prose writes the operator "${String(check['op'])}"`)
	return row.write(check, help(ctx))
}

/** The clause inside `every X must …`, addressed relative to one element. */
function element(ctx: RenderCtx, outer: PropertyDef, inner: Check): string {
	const path = (inner['path'] ?? inner['left'] ?? []) as Path
	if (!path.length) return predicate(ctx, inner)

	const prop = ctx.props.find((p) => same(innerPath(p), path) && startsWith(p.path, outerPath(outer)))
	if (!prop) throw new RuleError(`no declared property is \`${JSON.stringify(path)}\` inside ${outer.display}`)

	if (inner['op'] === 'equals' && !('substitute' in inner))
		return `have ${article(prop.display)} ${bold(prop.display)} of ${code(inner['value'])}`
	return `have ${article(prop.display)} ${bold(prop.display)} that must ${predicate(ctx, {...inner, path: []} as Check)}`
}

const startsWith = (path: Path, prefix: Path): boolean => same(path.slice(0, prefix.length), prefix)

function substituteName(ctx: RenderCtx, sub: unknown): string {
	for (const [name, held] of Object.entries(ctx.substitutes)) if (same(held, sub)) return name
	throw new RuleError('a substitute that is not declared in the document cannot be written as prose')
}

/** `Records the **X**' \`field\`.` — an extra entry in the check's inputs. */
function records(ctx: RenderCtx, entry: unknown): string {
	const e = entry as {path?: Path; each?: string[]}
	if (!e || !e.path || !e.each || e.each.length !== 1) throw new RuleError('an input that is not a single projection cannot be written as prose')
	const prop = ctx.props.find((p) => same(outerPath(p), e.path))
	if (!prop) throw new RuleError(`no declared property has the path \`${JSON.stringify(e.path)}\``)
	const possessive = prop.display.endsWith('s') ? "'" : "'s"
	return `Records the ${bold(prop.display)}${possessive} ${code(e.each[0])}.`
}

/** The inputs a custom operator derives from the registry, which the prose
 *  never spells out. Anything past them was written as a Records sentence. */
function derivedInputs(ctx: RenderCtx, op: string, path: Path): unknown[] {
	const def = ctx.customOps[op]
	if (!def) return []
	return def.inputs.map((i) => ('subject' in i ? i.subject : {path, each: i.each}))
}

export interface Written {
	/** The rule sentence, without its full stop. */
	rule: string
	/** `Records …` sentences, in full. */
	records: string[]
	description: string
}

/**
 * Write one check back. Throws RuleError when the check has no prose form —
 * an operator outside the vocabulary, a path no property declares — which is
 * how a YAML-only edit is refused rather than silently mangled.
 */
export function writeCheck(ctx: RenderCtx, check: Check, lead?: string, head?: string): Written {
	const c = {...check}
	const description = typeof c['description'] === 'string' ? c['description'] : ''
	delete c['description']

	let tail = ''
	if ('substitute' in c) {
		const name = substituteName(ctx, c['substitute'])
		tail = `, or else ${code(name)}` + tail
		delete c['substitute']
	}

	const op = String(c['op'])
	const custom = ctx.customOps[op]
	const extraInputs: unknown[] = []

	if (custom) {
		const path = (c['path'] ?? []) as Path
		if (c['patterns']) {
			let named: string | null = null
			for (const [name, held] of Object.entries(ctx.constants)) if (same(held, c['patterns'])) named = name
			if (!named) throw new RuleError(`the patterns on "${op}" are not a declared constant`)
			tail = `, treating ${bold(named)} as explained` + tail
		}
		if (c['expression'] !== custom.expression) throw new RuleError(`"${op}" carries an expression the registry does not define`)
		const derived = derivedInputs(ctx, op, path)
		const inputs = (c['inputs'] ?? []) as unknown[]
		if (!same(inputs.slice(0, derived.length), derived)) throw new RuleError(`"${op}" carries inputs the registry does not derive`)
		extraInputs.push(...inputs.slice(derived.length))
		const prop = ctx.props.find((p) => same(outerPath(p), path))
		if (!prop) throw new RuleError(`no declared property has the path \`${JSON.stringify(path)}\``)
		return {rule: `${lead ?? 'some'} ${spell(prop, head)} must ${custom.phrase}${tail}`, records: extraInputs.map((e) => records(ctx, e)), description}
	}

	if (c['inputs']) extraInputs.push(...(c['inputs'] as unknown[]))
	const rendered = extraInputs.map((e) => records(ctx, e))

	if (op === 'all' || op === 'any') {
		const path = (c['path'] ?? []) as Path
		const each = c['each'] as Path | undefined
		const prop = ctx.props.find((p) =>
			each
				? p.splits.length >= 2 && same(p.path.slice(0, p.splits[0]), path) && same(p.path.slice(p.splits[0], p.splits[1]), each)
				: p.splits.length < 2 && same(outerPath(p), path),
		)
		if (!prop) throw new RuleError(`no declared property has the collection path \`${JSON.stringify(path)}\``)
		const quantifier = op === 'all' ? 'every' : (lead ?? 'some')
		return {rule: `${quantifier} ${spell(prop, head)} must ${element(ctx, prop, (c['check'] ?? {}) as Check)}${tail}`, records: rendered, description}
	}

	const path = (c['path'] ?? c['left'] ?? []) as Path
	const prop = property(ctx, path)
	return {rule: `the ${spell(prop, head)} must ${predicate(ctx, c)}${tail}`, records: rendered, description}
}

/** One bullet, wrapped, ready to splice in place of the one it replaces. */
export function writeBullet(ctx: RenderCtx, name: string, check: Check, indent = '', lead?: string, head?: string): string {
	const {rule, records: recorded, description} = writeCheck(ctx, check, lead, head)
	const sentences = [`${code(name)} — ${rule}.`, ...recorded]
	if (description) sentences.push(description.replace(/\.?$/, '.'))
	return wrap(sentences.join(' '), indent)
}

/**
 * Wrap at word boundaries, never inside a code span: a soft break inside
 * backticks becomes a space in the value, which would quietly rewrite a regex.
 */
export function wrap(text: string, indent: string, width = 78): string {
	// Words, except that a code span holding spaces is one word: a soft break
	// inside backticks becomes a space in the value, which would quietly
	// rewrite a regex.
	const tokens: string[] = []
	for (const word of text.split(/\s+/).filter(Boolean)) {
		const last = tokens[tokens.length - 1]
		if (last && ((last.match(/`/g) ?? []).length % 2 === 1)) tokens[tokens.length - 1] = `${last} ${word}`
		else tokens.push(word)
	}

	const lines: string[] = []
	let line = `${indent}- `
	let empty = true
	for (const token of tokens) {
		if (!empty && line.length + 1 + token.length > width) {
			lines.push(line)
			line = `${indent}  `
			empty = true
		}
		line += empty ? token : ` ${token}`
		empty = false
	}
	lines.push(line)
	return lines.join('\n')
}

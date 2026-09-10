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
import {fromMarkdown} from 'mdast-util-from-markdown'
import {literal, renderDeclared, renderPath} from './paths.ts'
import {atomize, plain} from './grammar.ts'
import {LEAF_TABLE, type RenderHelp, RuleError, outerPath, innerPath} from './grammar.ts'

export interface RenderCtx {
	props: PropertyDef[]
	constants: Record<string, unknown[]>
	substitutes: Record<string, Check>
	customOps: CustomOpRegistry
	/**
	 * Name a path the table does not name yet.
	 *
	 * The property table is the one construct with no counterpart in the
	 * object: `from`, `id` and `subject_type` are fields the requirement needs
	 * anyway, but naming `approved_by` "**approver**" is a Markdown-only act.
	 * So a check added to the object can be perfectly valid and still have no
	 * prose form, for a reason that is not the object's fault. When a caller
	 * supplies this, the writer declares the path instead of refusing it.
	 */
	invent?: (path: Path, splits: number[]) => PropertyDef
	/** Told about every property a rule reads. A caller uses it to work out
	 *  which rows of the table are still spoken for. */
	record?: (prop: PropertyDef) => void
}

export function contextFor(doc: DocContext, requirement: string, customOps: CustomOpRegistry): RenderCtx {
	return {
		props: [...(doc.properties[requirement] ?? doc.all)],
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

/** An identifier, back in backticks: a check's name, a substitute's, a field.
 *  One holding a backtick is fenced with two, as CommonMark asks. */
export function code(v: unknown): string {
	const text = v === null ? 'null' : String(v)
	if (!text.includes('`')) return `\`${text}\``
	return `\`\` ${text} \`\``
}

/**
 * A sentence of the author's own words, escaped so the document reads it back
 * as the same words.
 *
 * Descriptions are prose and may contain anything — a `*`, a backtick, a
 * bracket — all of which mean something in Markdown. Rather than guess at a
 * safe escape set, escape lightly, read the result back through the same
 * parser the transpiler uses, and escalate only if it came back different.
 */
export function prose(text: string): string {
	const light = text.replace(/[\\`*_[\]<&]/g, (c) => `\\${c}`)
	if (readsBack(light, text)) return light
	const heavy = text.replace(/[!-/:-@[-`{-~]/g, (c) => `\\${c}`)
	if (readsBack(heavy, text)) return heavy
	throw new RuleError('this description cannot be written as Markdown without changing what it says')
}

function readsBack(markdown: string, want: string): boolean {
	const tree = fromMarkdown(markdown) as {children?: Array<{children?: unknown[]}>}
	const para = (tree.children ?? [])[0]
	if (!para || (tree.children ?? []).length !== 1) return false
	return plain(atomize((para.children ?? []) as never[])) === want
}

/**
 * A literal, back in backticks — and only where the document reads it back as
 * the same value.
 *
 * Prose writes a bare token, so the string "true" and the boolean true have one
 * spelling between them and the reader takes the boolean; a code span also eats
 * a leading space and turns a newline into one. Rather than enumerate those,
 * write the span, read it back through the same parser, and insist.
 */
export function value(v: unknown): string {
	const text = v === null ? 'null' : String(v)
	const written = text.includes('`') ? `\`\` ${text} \`\`` : `\`${text}\``
	const back = readCode(written)
	if (back === null) throw new RuleError(`the value ${JSON.stringify(text)} cannot be written as a code span`)
	const read = literal(back)
	if (read !== v)
		throw new RuleError(
			typeof read !== typeof v
				? `the value \`${back}\` would be read back as ${read === null ? 'null' : typeof read}, not ${typeof v} — prose writes a bare token, so a ${typeof v} that looks like ${read === null ? 'null' : `a ${typeof read}`} has no spelling`
				: `the value ${JSON.stringify(text)} would be read back as ${JSON.stringify(String(read))}`,
		)
	return written
}

/** The one inline code span a fragment holds, or null if it is not one. */
function readCode(markdown: string): string | null {
	const tree = fromMarkdown(markdown) as {children?: Array<{children?: Array<{type: string; value?: string}>}>}
	const kids = (tree.children ?? [])[0]?.children ?? []
	if ((tree.children ?? []).length !== 1 || kids.length !== 1 || kids[0]?.type !== 'inlineCode') return null
	return kids[0].value ?? ''
}

const bold = (display: string): string => `**${display}**`
const article = (word: string): string => (/^[aeiou]/i.test(word) ? 'an' : 'a')

function property(ctx: RenderCtx, path: Path): PropertyDef {
	const found = ctx.props.find((p) => same(p.path, path))
	return found ? use(ctx, found) : declare(ctx, path, [], renderPath(path))
}

/** Note that a rule reads this property, and hand it back. */
function use(ctx: RenderCtx, prop: PropertyDef): PropertyDef {
	ctx.record?.(prop)
	return prop
}

/** Ask the caller to name a path, or say plainly that nobody has. */
function declare(ctx: RenderCtx, path: Path, splits: number[], shown: string): PropertyDef {
	// A declaration is a code span in a table cell, and the path notation reads
	// `.` and `[]` itself, so a segment carrying any of those cannot be written
	// down — it would come back as a different path, or as a broken table.
	for (const seg of path)
		if (typeof seg === 'string' && /[|`.[\]\n]/.test(seg))
			throw new RuleError(`the path segment \`${seg}\` cannot be declared: a table cell holds it as a code span, and \` . [ ] |\` all mean something there`)
	if (!ctx.invent) throw new RuleError(`no declared property has the path \`${shown}\` — add a row to the Subjects table first`)
	const made = ctx.invent(path, splits)
	ctx.props.push(made)
	return use(ctx, made)
}

function patternsClause(ctx: RenderCtx, values: unknown[]): string {
	for (const [name, held] of Object.entries(ctx.constants)) if (same(held, values)) return bold(name)
	return values.map(code).join(', ')
}

function help(ctx: RenderCtx): RenderHelp {
	return {
		code: value,
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

	const stem = outerPath(outer)
	const held = ctx.props.find((p) => same(innerPath(p), path) && startsWith(p.path, stem))
	const prop = held ? use(ctx, held) : declare(ctx, [...stem, ...path], [stem.length], renderDeclared([...stem, ...path], [stem.length]))

	if (inner['op'] === 'equals' && !('substitute' in inner))
		return `have ${article(prop.display)} ${bold(prop.display)} of ${value(inner['value'])}`
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
	const held = ctx.props.find((p) => same(outerPath(p), e.path))
	const prop = held ? use(ctx, held) : declare(ctx, e.path, [], renderPath(e.path))
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
	// A description is the sentences after the rule, and the reader drops the
	// full stop that ends the last one. So a description carrying its own is
	// unreachable: it would come back one character shorter, every time.
	if (/\.\s*$/.test(description))
		throw new RuleError('a description is a phrase, not a sentence — drop the trailing full stop, the writer adds one')

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
		if (c['expression'] !== custom.expression)
			throw new RuleError(`"${op}" carries an \`expression\` the registry does not define — a custom operator's expression comes from authoring/custom_ops.json, not from the spec`)
		const derived = derivedInputs(ctx, op, path)
		const inputs = (c['inputs'] ?? []) as unknown[]
		if (!same(inputs.slice(0, derived.length), derived))
			throw new RuleError(`"${op}" reads \`inputs\` the registry does not derive from its \`path\` — a custom operator's inputs follow its path, so the two have to move together`)
		extraInputs.push(...inputs.slice(derived.length))
		const held = ctx.props.find((p) => same(outerPath(p), path))
		const prop = held ? use(ctx, held) : declare(ctx, path, [], renderPath(path))
		return {rule: `${lead ?? 'some'} ${spell(prop, head)} must ${custom.phrase}${tail}`, records: extraInputs.map((e) => records(ctx, e)), description}
	}

	if (c['inputs']) extraInputs.push(...(c['inputs'] as unknown[]))
	const rendered = extraInputs.map((e) => records(ctx, e))

	if (op === 'all' || op === 'any') {
		const path = (c['path'] ?? []) as Path
		const each = c['each'] as Path | undefined
		const found = ctx.props.find((p) =>
			each
				? p.splits.length >= 2 && same(p.path.slice(0, p.splits[0]), path) && same(p.path.slice(p.splits[0], p.splits[1]), each)
				: p.splits.length < 2 && same(outerPath(p), path),
		)
		// Two boundaries are declared `a[].b[]`, one is the bare path.
		const shape: [Path, number[]] = each ? [[...path, ...each], [path.length, path.length + each.length]] : [path, []]
		const prop = found ? use(ctx, found) : declare(ctx, shape[0], shape[1], renderDeclared(shape[0], shape[1]))
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
	if (description) sentences.push(`${prose(description)}.`)
	return wrap(sentences.join(' '), indent)
}

/** Wrap at word boundaries, but never inside a code span or in front of a
 *  token that would start a new block. */
export function wrap(text: string, indent: string, width = 78): string {
	// Words, except that a code span is one word however many spaces it holds
	// and however it is fenced: a line break inside backticks becomes a space in
	// the value, which would quietly rewrite a regex.
	const tokens: string[] = []
	let buf = ''
	for (let i = 0; i < text.length; ) {
		const ch = text[i]!
		if (ch === '`') {
			const fence = /^`+/.exec(text.slice(i))![0]
			const close = text.indexOf(fence, i + fence.length)
			const end = close < 0 ? text.length : close + fence.length
			buf += text.slice(i, end)
			i = end
			continue
		}
		if (/\s/.test(ch)) {
			if (buf) tokens.push(buf)
			buf = ''
			i++
			continue
		}
		buf += ch
		i++
	}
	if (buf) tokens.push(buf)

	// A line that began with a list marker, a heading or a quote would end the
	// paragraph and take the rest of the description with it. Rather than escape
	// the author's words, simply never break before such a token.
	const startsBlock = (t: string): boolean => /^(?:[-+>#]|\d+[.)])/.test(t)

	const lines: string[] = []
	let line = `${indent}- `
	let empty = true
	for (const token of tokens) {
		if (!empty && line.length + 1 + token.length > width && !startsBlock(token)) {
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

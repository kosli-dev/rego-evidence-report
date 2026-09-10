// Writing an edited requirements object back into the Markdown that produced it.
//
// The rule that makes this safe: never regenerate the document. Markdown ->
// object is deliberately lossy — the rationale paragraphs are not in the
// object — so object -> Markdown cannot be a function. What is a function is
// the *diff*: every difference between the compiled object and the edited one
// names a construct, every construct has a recorded source range (Anchor), and
// a patch replaces those ranges and nothing else. Prose survives because
// nothing ever addressed it.
//
// Inside a check bullet there is no prose-only text: every sentence that is not
// a rule and not a `Records …` becomes `description`, which is in the object.
// So a bullet may be rewritten whole and lose nothing. The prose that exists
// only in Markdown lives between bullets, and a check-level edit never reaches
// it.
//
// Where a change has no prose form, it is refused by name rather than
// approximated. The caller then recompiles the patched source and asserts it
// equals what was asked for — see verifiedPatch in web.ts.

import type {Analysis, Anchor, Check, CustomOpRegistry, Path, PropertyDef} from './types.ts'
import {RuleError} from './grammar.ts'
import {renderDeclared} from './paths.ts'
import {type RenderCtx, contextFor, writeBullet, writeCheck, wrap} from './render.ts'

type Req = Record<string, unknown>

export interface PatchResult {
	markdown: string
	/** What was rewritten, in the author's terms. */
	changes: string[]
	/** What had no prose form and was left out. */
	refusals: string[]
	/** The names of the checks that moved, so a caller can show them. */
	touched: string[]
}

/** A property the writer had to name because the object used a path the table
 *  does not. Held per subject, since that is the table it goes in. */
interface Invented {
	display: string
	pathText: string
}

/** The properties one check reads, found by writing it with nothing to invent.
 *  The writer is asked rather than the paths compared, so this cannot disagree
 *  with what the prose will actually say. */
function readsOf(analysis: Analysis, req: string, check: Check, customOps: CustomOpRegistry): PropertyDef[] {
	const seen: PropertyDef[] = []
	const ctx = contextFor(analysis.context, req, customOps)
	ctx.record = (p) => {
		if (!seen.includes(p)) seen.push(p)
	}
	try {
		writeCheck(ctx, check)
	} catch {
		// It has no prose form, so it names nothing this can free.
	}
	return seen
}

/** Every property still spoken for once the edit lands — one bullet excepted,
 *  because that is the bullet whose old reading is up for reuse. */
function spokenFor(
	analysis: Analysis,
	target: Record<string, unknown>,
	customOps: CustomOpRegistry,
	except: {req: string; name: string},
): Set<string> {
	const out = new Set<string>()
	const note = (req: string, check: Check): void => {
		for (const p of readsOf(analysis, req, check, customOps)) out.add(p.display)
	}
	for (const [req, body] of Object.entries(target))
		for (const field of ['checks', 'applies_to'])
			for (const [name, check] of Object.entries(map(body as Req, field)))
				if (req !== except.req || name !== except.name) note(req, check)
	// Substitutes are declared once and shared, and their bullets are not
	// patched here — but they read properties, so their rows are not free.
	for (const check of Object.values(analysis.context.substitutes)) note('\u0000document', check)
	return out
}

interface Edit {
	start: number
	end: number
	text: string
}

const same = (a: unknown, b: unknown): boolean => JSON.stringify(a) === JSON.stringify(b)

/**
 * Every place two objects disagree, named by its path. Key order is not a
 * disagreement: a check added at the end of a list compiles to the end of the
 * map, wherever the edit put it in the YAML.
 */
export function differences(got: unknown, want: unknown, at = ''): string[] {
	if (same(got, want)) return []
	const flat = (v: unknown): boolean => typeof v !== 'object' || v === null || Array.isArray(v)
	if (flat(got) || flat(want)) return [at || '(document)']
	const a = got as Record<string, unknown>
	const b = want as Record<string, unknown>
	const out: string[] = []
	for (const key of new Set([...Object.keys(a), ...Object.keys(b)])) out.push(...differences(a[key], b[key], at ? `${at}.${key}` : key))
	return out
}
const map = (r: Req | undefined, field: string): Record<string, Check> => ((r?.[field] ?? {}) as Record<string, Check>)

export function applyRequirements(
	markdown: string,
	analysis: Analysis,
	target: Record<string, unknown>,
	customOps: CustomOpRegistry,
): PatchResult {
	const current = analysis.requirements as Record<string, Req>
	const edits: Edit[] = []
	const changes: string[] = []
	const refusals: string[] = []
	const touched: string[] = []

	// A path the object uses and the table does not name. The object is not at
	// fault — naming a path is a Markdown-only act — so the writer declares it
	// rather than refusing the edit, and says so.
	const invented = new Map<string, Invented[]>()
	const repointed = new Map<string, Invented[]>()
	const contexts = new Map<string, RenderCtx>()
	// Rows the bullet being written is free to take over: the ones its previous
	// reading named, that nothing else reads any more. Editing a path is then a
	// path edit, not a fresh declaration — which is what stops a table growing
	// a row for every keystroke on the way to the path you meant.
	let offer: PropertyDef[] = []

	const ctxFor = (req: string): RenderCtx => {
		const held = contexts.get(req)
		if (held) return held
		const ctx = contextFor(analysis.context, req, customOps)
		// A requirement the document does not have yet is about the subject its
		// own object names, since the analysis has never seen it.
		const subject = analysis.context.subjectOf[req] ?? String((target[req] as Req | undefined)?.['subject_type'] ?? '')
		ctx.invent = (path, splits) => {
			if (!subject) throw new RuleError('this requirement is about no declared subject, so a new property has nowhere to go')
			const pathText = renderDeclared(path, splits)

			// A property is only interchangeable with one of the same shape: a
			// leaf for a leaf, a collection for a collection.
			const spare = offer.findIndex((p) => p.splits.length === splits.length)
			if (spare >= 0) {
				const [old] = offer.splice(spare, 1)
				const at = ctx.props.indexOf(old!)
				if (at >= 0) ctx.props.splice(at, 1)
				repointed.set(subject, [...(repointed.get(subject) ?? []), {display: old!.display, pathText}])
				return {display: old!.display, path, splits}
			}

			const rows = invented.get(subject) ?? []
			const made: PropertyDef = {display: nameFor(ctx, rows, path), path, splits}
			rows.push({display: made.display, pathText})
			invented.set(subject, rows)
			return made
		}
		contexts.set(req, ctx)
		return ctx
	}

	/** Everything a bullet may have touched, so a failed write leaves none of
	 *  it behind: a refusal must not half-declare a subject. */
	const mark = (req: string): (() => void) => {
		const ctx = contexts.get(req)
		const subject = analysis.context.subjectOf[req] ?? ''
		const props = ctx ? [...ctx.props] : []
		const made = [...(invented.get(subject) ?? [])]
		const moved = [...(repointed.get(subject) ?? [])]
		return () => {
			if (ctx) ctx.props.splice(0, ctx.props.length, ...props)
			if (invented.has(subject)) invented.set(subject, made)
			if (repointed.has(subject)) repointed.set(subject, moved)
		}
	}

	const anchor = (kind: Anchor['kind'], requirement?: string, name?: string): Anchor | undefined =>
		analysis.anchors.find((a) => a.kind === kind && a.requirement === requirement && a.name === name)

	const names = [...new Set([...Object.keys(current), ...Object.keys(target)])]

	for (const req of names) {
		const before = current[req] as Req | undefined
		const after = target[req] as Req | undefined

		if (before && !after) {
			const region = anchor('requirement', req, req)
			if (!region) {
				refusals.push(`${req}: cannot find where it was written`)
				continue
			}
			edits.push(cut(markdown, region.start, region.end))
			changes.push(`removed ${req}, and the prose written under it`)
			continue
		}
		if (!before && after) {
			const ctx = ctxFor(req)
			const undo = mark(req)
			try {
				edits.push(addRequirement(markdown, analysis, req, after, ctx))
				changes.push(`added ${req}`)
			} catch (e) {
				undo()
				refusals.push(`${req}: ${(e as Error).message}`)
			}
			continue
		}
		if (!before || !after) continue

		for (const field of ['subject_type', 'from', 'id']) {
			if (!same(before[field], after[field]))
				refusals.push(`${req}: \`${field}\` is declared in the Subjects section — change it there`)
		}

		if (!same(before['min_subjects'], after['min_subjects']))
			directive(markdown, analysis, edits, changes, refusals, req, 'min_subjects', minSubjectsProse(after), before['min_subjects'] !== undefined)
		if (!same(before['require'], after['require']))
			directive(markdown, analysis, edits, changes, refusals, req, 'require', requireProse(after), before['require'] !== undefined)

		for (const field of ['applies_to', 'checks'] as const) {
			const kind = field === 'checks' ? 'rule' : 'scope'
			const was = map(before, field)
			const now = map(after, field)

			const gone = Object.keys(was).filter((n) => !(n in now))
			const fresh = Object.keys(now).filter((n) => !(n in was))

			// A name that disappeared and one that appeared carrying the same
			// check is a rename. Rewriting that bullet in place keeps its
			// position and the description under it; deleting it and appending
			// a stranger at the end of the list would lose both.
			const renamed = new Map<string, string>()
			for (const from of [...gone]) {
				const to = fresh.find((f) => same(was[from], now[f]))
				if (!to) continue
				renamed.set(from, to)
				gone.splice(gone.indexOf(from), 1)
				fresh.splice(fresh.indexOf(to), 1)
			}
			// One out, one in, and neither matched: a rename with an edit.
			if (gone.length === 1 && fresh.length === 1) {
				renamed.set(gone[0]!, fresh[0]!)
				gone.length = 0
				fresh.length = 0
			}

			const rewrite = (from: string, to: string): void => {
				const spot = anchor(kind, req, from)
				if (!spot) {
					refusals.push(`${req}.${from}: cannot find where it was written`)
					return
				}
				const ctx = ctxFor(req)
				const undo = mark(req)
				// Rows this bullet is free to take over: the ones its previous
				// reading named, less the ones anything else reads — and less
				// the ones its *new* reading still needs, which is how a check
				// that records a field from one path while testing another
				// keeps both rows when only one of them moves.
				const busy = spokenFor(analysis, target, customOps, {req, name: to})
				const keeps = new Set(readsOf(analysis, req, now[to]!, customOps).map((p) => p.display))
				offer = readsOf(analysis, req, was[from]!, customOps).filter((p) => !busy.has(p.display) && !keeps.has(p.display))
				try {
					// The author's quantifier and their spelling of the property
					// only survive an edit that leaves the operator alone; past
					// that they may no longer describe the check.
					const kept = was[from]?.['op'] === now[to]?.['op']
					edits.push({
						start: lineStart(markdown, spot.start),
						end: spot.end,
						text: writeBullet(ctx, to, now[to]!, spot.indent ?? '', kept ? spot.lead : undefined, kept ? spot.head : undefined),
					})
					changes.push(from === to ? `rewrote ${req}.${to}` : `renamed ${req}.${from} to ${to}`)
					touched.push(to)
				} catch (e) {
					undo()
					refusals.push(`${req}.${to}: ${(e as Error).message}`)
				}
			}

			for (const [from, to] of renamed) rewrite(from, to)
			for (const name of Object.keys(now)) if (name in was && !same(was[name], now[name])) rewrite(name, name)

			for (const name of gone) {
				const spot = anchor(kind, req, name)
				if (!spot) {
					refusals.push(`${req}.${name}: cannot find where it was written`)
					continue
				}
				edits.push(cut(markdown, spot.start, spot.end))
				changes.push(`removed ${req}.${name}, and its description`)
				touched.push(name)
			}

			const LEAD = {applies_to: 'In scope:', checks: 'Must hold:'} as const
			const leadOf = (f: 'applies_to' | 'checks'): Anchor | undefined =>
				analysis.anchors.find((a) => a.kind === 'directive' && a.requirement === req && a.name === `${f}:lead`)

			// Emptied, and its lead-in goes with it: an "In scope:" standing over
			// nothing is not just untidy, it runs into the sentence below it and
			// stops being read as a lead-in at all.
			if (!Object.keys(now).length && Object.keys(was).length) {
				const orphan = leadOf(field)
				if (orphan) {
					edits.push(cut(markdown, orphan.start, orphan.end))
					changes.push(`removed ${req}'s "${LEAD[field]}", which now heads nothing`)
				}
			}

			if (!fresh.length) continue

			const list = anchor('list', req, field)
			const lead = leadOf(field)
			// Where a new bullet goes: after the last item still standing, so an
			// insertion can never land inside a deletion.
			const standing = list ? analysis.anchors.filter((a) => a.kind === kind && a.requirement === req && a.name && !gone.includes(a.name)) : []
			const tail = standing[standing.length - 1]
			const gap = list && markdown.slice(list.start, list.end).includes('\n\n') ? '\n\n' : '\n'

			const bullets: string[] = []
			for (const name of fresh) {
				const ctx = ctxFor(req)
				const undo = mark(req)
				offer = []
				try {
					bullets.push(writeBullet(ctx, name, now[name]!, list?.indent ?? ''))
					changes.push(`added ${req}.${name}`)
					touched.push(name)
				} catch (e) {
					undo()
					refusals.push(`${req}.${name}: ${(e as Error).message}`)
				}
			}
			if (!bullets.length) continue
			const text = bullets.join(gap)

			// A list to join, a lead-in whose list has gone, or neither — in
			// which case both are written, and a scope filter goes in front of
			// "Must hold:", where the reader expects it.
			if (tail) edits.push({start: tail.end, end: tail.end, text: gap + text})
			else if (list) edits.push({start: list.start, end: list.start, text: text + gap})
			else if (lead) edits.push({start: lead.end, end: lead.end, text: `\n\n${text}`})
			else {
				const ahead = field === 'applies_to' ? (leadOf('checks') ?? anchor('list', req, 'checks')) : undefined
				const region = anchor('requirement', req, req)
				if (ahead) edits.push({start: lineStart(markdown, ahead.start), end: lineStart(markdown, ahead.start), text: `${LEAD[field]}\n\n${text}\n\n`})
				else if (region) edits.push({start: region.end, end: region.end, text: `\n\n${LEAD[field]}\n\n${text}`})
				else {
					for (const name of fresh) refusals.push(`${req}.${name}: cannot find where to write it`)
					continue
				}
				changes.push(`opened ${req}'s "${LEAD[field]}" list`)
			}
		}
	}

	// The table, once every bullet that wanted a row has been written.
	for (const subject of new Set([...invented.keys(), ...repointed.keys()])) {
		const added = invented.get(subject) ?? []
		const moved = repointed.get(subject) ?? []
		if (!added.length && !moved.length) continue
		const table = analysis.anchors.find((a) => a.kind === 'table' && a.name === subject)
		if (!table) {
			refusals.push(`${subject}: has no property table, so \`${(added[0] ?? moved[0])!.pathText}\` cannot be named`)
			continue
		}
		edits.push({start: table.start, end: table.end, text: editTable(markdown.slice(table.start, table.end), moved, added)})
		for (const r of moved) changes.push(`pointed **${r.display}** at \`${r.pathText}\``)
		for (const r of added) changes.push(`named \`${r.pathText}\` **${r.display}** under ${subject}`)
	}

	return {markdown: splice(markdown, edits), changes, refusals, touched}
}

/** A name for a path nobody named: its last plain segment, read aloud. */
function nameFor(ctx: RenderCtx, pending: Invented[], path: Path): string {
	const words = path.filter((seg): seg is string => typeof seg === 'string')
	const taken = new Set([...ctx.props.map((p) => p.display.toLowerCase()), ...pending.map((p) => p.display.toLowerCase())])
	const say = (raw: string): string => raw.replace(/[_-]+/g, ' ').replace(/\s+/g, ' ').trim().toLowerCase()
	for (let take = 1; take <= words.length; take++) {
		const candidate = say(words.slice(words.length - take).join(' '))
		if (candidate && !taken.has(candidate)) return candidate
	}
	// Every suffix is spoken for; fall back to the whole path, which cannot be.
	return say(words.join(' ')) + ' path'
}

/** The table, with rows repointed or appended and every column realigned.
 *  Rewriting it whole is what keeps a longer path from breaking the alignment
 *  the author had; a table that already fits comes back byte for byte. */
function editTable(source: string, moved: Invented[], added: Invented[]): string {
	const lines = source.split('\n').filter((l) => l.trim())
	const cells = (line: string): string[] =>
		line
			.trim()
			.replace(/^\||\|$/g, '')
			.split('|')
			.map((c) => c.trim())
	const key = (t: string): string => t.toLowerCase().replace(/\s+/g, ' ').trim()
	const repoint = new Map(moved.map((r) => [key(r.display), r.pathText]))
	const header = cells(lines[0] ?? '| Property | Path |')
	const body = [
		...lines.slice(2).map((l) => {
			const row = cells(l)
			const to = repoint.get(key(row[0] ?? ''))
			return to ? [row[0] ?? '', `\`${to}\``, ...row.slice(2)] : row
		}),
		...added.map((r) => [r.display, `\`${r.pathText}\``]),
	]
	const width = header.map((h, i) => Math.max(h.length, ...body.map((r) => (r[i] ?? '').length)))
	const line = (r: string[]): string => `| ${width.map((w, i) => (r[i] ?? '').padEnd(w)).join(' | ')} |`
	return [line(header), `| ${width.map((w) => '-'.repeat(w)).join(' | ')} |`, ...body.map(line)].join('\n')
}

function directive(
	markdown: string,
	analysis: Analysis,
	edits: Edit[],
	changes: string[],
	refusals: string[],
	req: string,
	field: string,
	prose: string | null,
	existed: boolean,
): void {
	const spot = analysis.anchors.find((a) => a.kind === 'directive' && a.requirement === req && a.name === field)
	if (existed && !spot) {
		refusals.push(`${req}: cannot find where \`${field}\` was written`)
		return
	}
	if (spot && prose === null) {
		edits.push(cut(markdown, spot.start, spot.end))
		changes.push(`removed ${req}'s \`${field}\` sentence`)
		return
	}
	if (prose === null) return
	if (spot) {
		edits.push({start: lineStart(markdown, spot.start), end: spot.end, text: prose})
		changes.push(`rewrote ${req}'s \`${field}\` sentence${field === 'min_subjects' ? ', and the reasoning written in it' : ''}`)
		return
	}
	const region = analysis.anchors.find((a) => a.kind === 'requirement' && a.requirement === req)
	if (!region) {
		refusals.push(`${req}: cannot find where to write \`${field}\``)
		return
	}
	edits.push({start: region.insertAt ?? region.start, end: region.insertAt ?? region.start, text: `\n\n${prose}`})
	changes.push(`added ${req}'s \`${field}\` sentence`)
}

function minSubjectsProse(req: Req): string | null {
	const n = req['min_subjects']
	if (n === undefined) return null
	if (n === 0) return 'No minimum.'
	const count = n === 1 ? 'one' : String(n)
	return `At least ${count} **${String(req['subject_type'] ?? 'subject')}** must be in scope.`
}

function requireProse(req: Req): string | null {
	if (req['require'] !== 'some') return null
	return `One **${String(req['subject_type'] ?? 'subject')}** must satisfy all of these.`
}

/** A requirement the document does not have yet. Its heading text is the
 *  author's to write; the name stands in until they do. */
function addRequirement(markdown: string, analysis: Analysis, name: string, req: Req, ctx: RenderCtx): Edit {
	const parts: string[] = [`## ${name.replace(/_/g, ' ')} \`${name}\``]
	if (analysis.subjects.length > 1 && req['subject_type']) parts.push(`For each **${String(req['subject_type'])}**.`)
	const min = minSubjectsProse(req)
	if (min) parts.push(min)
	const some = requireProse(req)
	if (some) parts.push(some)

	const scope = map(req, 'applies_to')
	if (Object.keys(scope).length) {
		parts.push('In scope:')
		parts.push(Object.entries(scope).map(([n, c]) => writeBullet(ctx, n, c)).join('\n\n'))
	}
	const checks = map(req, 'checks')
	if (!Object.keys(checks).length) throw new RuleError('a requirement with no checks asserts nothing')
	parts.push('Must hold:')
	parts.push(Object.entries(checks).map(([n, c]) => writeBullet(ctx, n, c)).join('\n\n'))

	const at = markdown.replace(/\s+$/, '').length
	return {start: at, end: at, text: `\n\n${parts.join('\n\n')}\n`}
}

const lineStart = (s: string, at: number): number => s.lastIndexOf('\n', at - 1) + 1

/**
 * The span to remove for a block, blank lines included.
 *
 * One of the two blank lines around it goes too, or the document grows a hole
 * where the block was — and it has to be the one *before*, so that whatever
 * follows keeps the blank line that separates it. Taking the one after instead
 * closes the list onto the paragraph below, and that paragraph is then read as
 * the last bullet's description: prose silently becoming policy.
 */
function cut(s: string, start: number, end: number): Edit {
	let from = lineStart(s, start)
	const nl = s.indexOf('\n', end)
	const before = /\n[ \t]*\n$/.exec(s.slice(0, from))
	if (before) from -= before[0].length - 1
	return {start: from, end: nl < 0 ? s.length : nl + 1, text: ''}
}

function splice(s: string, edits: Edit[]): string {
	let out = s
	for (const e of [...edits].sort((a, b) => b.start - a.start || b.end - a.end)) out = out.slice(0, e.start) + e.text + out.slice(e.end)
	return out
}

export {wrap}

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

import type {Analysis, Anchor, Check, CustomOpRegistry} from './types.ts'
import {RuleError} from './grammar.ts'
import {contextFor, writeBullet, wrap} from './render.ts'

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

interface Edit {
	start: number
	end: number
	text: string
}

const same = (a: unknown, b: unknown): boolean => JSON.stringify(a) === JSON.stringify(b)
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
			edits.push({start: lineStart(markdown, region.start), end: swallow(markdown, region.end), text: ''})
			changes.push(`removed ${req}, and the prose written under it`)
			continue
		}
		if (!before && after) {
			try {
				edits.push(addRequirement(markdown, analysis, req, after, customOps))
				changes.push(`added ${req}`)
			} catch (e) {
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
			for (const name of new Set([...Object.keys(was), ...Object.keys(now)])) {
				const spot = anchor(kind, req, name)
				if (was[name] && !now[name]) {
					if (!spot) {
						refusals.push(`${req}.${name}: cannot find where it was written`)
						continue
					}
					edits.push({start: lineStart(markdown, spot.start), end: swallow(markdown, spot.end), text: ''})
					changes.push(`removed ${req}.${name}, and its description`)
					touched.push(name)
					continue
				}
				if (same(was[name], now[name])) continue
				const ctx = contextFor(analysis.context, req, customOps)
				try {
					if (was[name] && spot) {
						// The author's quantifier and their spelling of the property
						// only survive an edit that leaves the operator alone;
						// past that they may no longer describe the check.
						const kept = was[name]?.['op'] === now[name]?.['op']
						edits.push({start: lineStart(markdown, spot.start), end: spot.end, text: writeBullet(ctx, name, now[name]!, spot.indent ?? '', kept ? spot.lead : undefined, kept ? spot.head : undefined)})
						changes.push(`rewrote ${req}.${name}`)
						touched.push(name)
					} else {
						const list = anchor('list', req, field)
						if (!list) throw new RuleError(`there is no ${field === 'checks' ? '"Must hold:"' : '"In scope:"'} list to add it to`)
						const gap = markdown.slice(list.start, list.end).includes('\n\n') ? '\n\n' : '\n'
						edits.push({start: list.end, end: list.end, text: gap + writeBullet(ctx, name, now[name]!, list.indent ?? '')})
						changes.push(`added ${req}.${name}`)
						touched.push(name)
					}
				} catch (e) {
					refusals.push(`${req}.${name}: ${(e as Error).message}`)
				}
			}
		}
	}

	return {markdown: splice(markdown, edits), changes, refusals, touched}
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
		edits.push({start: lineStart(markdown, spot.start), end: swallow(markdown, spot.end), text: ''})
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
function addRequirement(markdown: string, analysis: Analysis, name: string, req: Req, customOps: CustomOpRegistry): Edit {
	const ctx = contextFor(analysis.context, name, customOps)
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

/** Take the blank line after a deleted block with it, so removing a bullet
 *  does not leave a hole in the list. */
function swallow(s: string, end: number): number {
	let i = end
	for (;;) {
		const m = /^[ \t]*\n/.exec(s.slice(i))
		if (!m) return i
		i += m[0].length
	}
}

function splice(s: string, edits: Edit[]): string {
	let out = s
	for (const e of [...edits].sort((a, b) => b.start - a.start || b.end - a.end)) out = out.slice(0, e.start) + e.text + out.slice(e.end)
	return out
}

export {wrap}

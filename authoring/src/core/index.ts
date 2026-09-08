// analyze(markdown) -> {blocks, requirements, diagnostics}
//
// One function serves every consumer. `blocks` classifies every block of the
// document with its source range, which is what an editor highlights from and
// what `--explain` prints; `requirements` is the emitted spec; `diagnostics`
// is what a linter reports. They are the same data by construction, so the
// editor cannot disagree with the transpiler about what is a rule.
//
// Nothing here reads a file, writes one, or exits. Keep it that way: the same
// module has to run in a browser.

import {fromMarkdown} from 'mdast-util-from-markdown'
import {gfmTable} from 'micromark-extension-gfm-table'
import {gfmTableFromMarkdown} from 'mdast-util-gfm-table'

import type {Analysis, Block, Check, CustomOpRegistry, Diagnostic, PropertyDef, SubjectDef, SubjectSummary} from './types.ts'
import {type Atom, type Ctx, RuleError, atomize, matchRecords, matchRule, plain, sentences} from './grammar.ts'
import {parseConstantHead, parseSubject, parseTable} from './declare.ts'
import {validateRequirements} from './validate.ts'
import {renderDeclared, renderPath} from './paths.ts'

interface Node {
	type: string
	depth?: number
	value?: string
	children?: Node[]
	position?: {start: {line: number}; end: {line: number}}
}

const subjectKey = (s: string): string => s.toLowerCase().replace(/\*/g, '').replace(/\s+/g, ' ').trim()

const lineOf = (n: Node): number => n.position?.start.line ?? 0
const endOf = (n: Node): number => n.position?.end.line ?? lineOf(n)

function textOf(n: Node): string {
	if (n.type === 'text' || n.type === 'inlineCode') return n.value ?? ''
	return (n.children ?? []).map(textOf).join('')
}

/** A declared subject, with the properties declared under it. Properties are
 *  scoped per subject: two subjects may both have a `name`, and a rule resolves
 *  against the subject its requirement is about. */
interface SubjectEntry {
	def: SubjectDef
	props: Map<string, PropertyDef>
}

/** A requirement under construction. */
interface Req {
	name: string
	line: number
	subject: SubjectEntry | null
	minSubjects?: number
	require?: string
	appliesTo: Record<string, Check>
	checks: Record<string, Check>
}

export function analyze(markdown: string, opts: {customOps?: CustomOpRegistry} = {}): Analysis {
	const tree = fromMarkdown(markdown, {
		extensions: [gfmTable()],
		mdastExtensions: [gfmTableFromMarkdown()],
	}) as unknown as Node

	const blocks: Block[] = []
	const diagnostics: Diagnostic[] = []
	const subjects = new Map<string, SubjectEntry>()
	// Document-level constructs — substitutes, constants — are declared before
	// any requirement picks a subject, so they resolve against every property
	// declared anywhere.
	const allProps = new Map<string, PropertyDef>()
	let lastSubject: SubjectEntry | null = null
	const ctx: Ctx = {
		props: allProps,
		constants: new Map<string, unknown[]>(),
		substitutes: new Map<string, Check>(),
		customOps: opts.customOps ?? {},
	}
	const customOpNames = new Set(Object.keys(ctx.customOps))

	let section: 'none' | 'subjects' | 'constants' | 'substitutes' | 'requirement' = 'none'
	let req: Req | null = null
	let listRole: 'scope' | 'checks' | 'patterns' | 'substitutes' | null = null
	let pendingConstant: string | null = null
	const reqs: Req[] = []

	const err = (line: number, message: string): number => diagnostics.push({severity: 'error', line, message})
	const warn = (line: number, message: string): number => diagnostics.push({severity: 'warning', line, message})

	/** Point rule resolution at one subject's properties. */
	const useSubject = (r: Req, entry: SubjectEntry | null): void => {
		r.subject = entry
		ctx.props = entry ? entry.props : allProps
	}

	/** The subject a requirement is about, when the document leaves it implicit. */
	const soleSubject = (): SubjectEntry | null => (subjects.size === 1 ? [...subjects.values()][0]! : null)

	/** Read one bullet as `name — rule sentence. description sentences.` */
	const readRule = (item: Node): {name: string; check: Check; description: string} | null => {
		const para = (item.children ?? [])[0]
		if (!para) return null
		const atoms = atomize((para.children ?? []) as never[])
		const line = lineOf(para)

		let rest = atoms
		let name = ''
		if (atoms[0]?.kind === 'code') {
			name = atoms[0].text
			rest = atoms.slice(1)
			const sep = rest[0]
			if (sep && sep.kind === 'text') rest = [{kind: 'text', text: sep.text.replace(/^\s*[\u2014\u2013-]\s*/, '')}, ...rest.slice(1)]
		}
		if (!name) {
			err(line, 'a rule needs a name: put it in backticks at the start of the bullet')
			return null
		}

		const sents = sentences(rest)
		const first = sents[0]
		if (!first) {
			err(line, `${name}: no rule sentence`)
			return null
		}

		let matched
		try {
			matched = matchRule(first, ctx, false)
		} catch (e) {
			err(line, `${name}: ${(e as Error).message}`)
			return null
		}
		if (!matched) {
			err(line, `${name}: "${plain(first)}" matches no operator`)
			return null
		}

		const check: Check = {...matched.check}
		const descriptions: string[] = []
		for (const s of sents.slice(1)) {
			let record: Check | null = null
			try {
				record = matchRecords(s, ctx)
			} catch (e) {
				err(line, `${name}: ${(e as Error).message}`)
			}
			if (record) {
				check['inputs'] = [...((check['inputs'] as unknown[]) ?? []), record]
				continue
			}
			descriptions.push(plain(s))
		}
		// Trailing full stop dropped: every description in the existing specs is
		// a phrase, not a sentence, and the report renders them inline.
		const description = descriptions.join(' ').trim().replace(/\.$/, '')
		if (description) check['description'] = description

		return {name, check, description}
	}

	for (const node of tree.children ?? []) {
		const line = lineOf(node)

		if (node.type === 'heading') {
			const kids = node.children ?? []
			const last = kids[kids.length - 1]
			const label = textOf(node).trim()

			if ((node.depth ?? 1) >= 2 && last?.type === 'inlineCode') {
				req = {name: last.value ?? '', line, subject: null, appliesTo: {}, checks: {}}
				useSubject(req, soleSubject())
				reqs.push(req)
				section = 'requirement'
				listRole = null
				// The heading's own text, less the backticked name it ends with —
				// repeating the label as its own description reads as a bug.
				const prose = label.replace(/\s*`?[\w-]+`?$/, '').trim()
				blocks.push({kind: 'requirement', line, endLine: endOf(node), label: req.name, detail: prose})
				continue
			}
			const key = label.toLowerCase()
			section = key === 'subjects' ? 'subjects' : key === 'constants' ? 'constants' : key === 'substitutes' ? 'substitutes' : 'none'
			listRole = section === 'substitutes' ? 'substitutes' : null
			req = null
			blocks.push({kind: 'prose', line, endLine: endOf(node), detail: label})
			continue
		}

		if (node.type === 'table') {
			if (section !== 'subjects') {
				blocks.push({kind: 'prose', line, endLine: endOf(node), detail: 'table'})
				continue
			}
			const rows = (node.children ?? []) as {children?: {children?: unknown[]}[]}[]
			try {
				const parsed = parseTable(rows, (c) => textOf(c as Node))
				if (!lastSubject) err(line, 'declare a subject before its properties')
				for (const [k, v] of parsed) {
					lastSubject?.props.set(k, v)
					allProps.set(k, v)
				}
				blocks.push({kind: 'properties', line, endLine: endOf(node), detail: `${parsed.size} properties`,
					label: lastSubject?.def.subjectType})
			} catch (e) {
				err(line, (e as Error).message)
			}
			continue
		}

		if (node.type === 'paragraph') {
			const atoms = atomize((node.children ?? []) as never[])
			const text = plain(atoms)

			if (section === 'subjects') {
				const parsed = parseSubject(atoms, line)
				if (parsed) {
					const key = parsed.subjectType.toLowerCase().replace(/\s+/g, ' ').trim()
					if (subjects.has(key)) err(line, `a subject named "${parsed.subjectType}" is already declared`)
					lastSubject = {def: parsed, props: new Map<string, PropertyDef>()}
					subjects.set(key, lastSubject)
					blocks.push({
						kind: 'subject',
						line,
						endLine: endOf(node),
						label: parsed.subjectType,
						detail: `from=${renderPath(parsed.from)} id=${renderPath(parsed.id)}`,
					})
					continue
				}
			}

			if (section === 'constants') {
				const name = parseConstantHead(atoms)
				if (name) {
					pendingConstant = name
					listRole = 'patterns'
					blocks.push({kind: 'constant', line, endLine: endOf(node), label: name})
					continue
				}
			}

			if (req) {
				let m: RegExpExecArray | null
				if (/^In scope:?$/i.test(text)) {
					listRole = 'scope'
					blocks.push({kind: 'directive', line, endLine: endOf(node), detail: 'applies_to follows'})
					continue
				}
				if (/^Must hold:?$/i.test(text)) {
					listRole = 'checks'
					blocks.push({kind: 'directive', line, endLine: endOf(node), detail: 'checks follow'})
					continue
				}
				if ((m = /^(?:For|About) each \*?\*?(.+?)\*?\*?\.?$/i.exec(text)) && subjects.has(subjectKey(m[1] ?? ''))) {
					const entry = subjects.get(subjectKey(m[1] ?? ''))!
					useSubject(req, entry)
					blocks.push({kind: 'directive', line, endLine: endOf(node), detail: `subject: ${entry.def.subjectType}`})
					continue
				}
				if ((m = /^At least (\d+|one) \S.* must be in scope\.?$/i.exec(text))) {
					req.minSubjects = m[1] === 'one' ? 1 : Number(m[1])
					// The bold span names the subject, and `plain` has already
					// dropped the markup — so read the atom, not the text.
					const key = subjectKey(atoms.find((a) => a.kind === 'prop')?.text ?? '')
					if (!req.subject && subjects.has(key)) useSubject(req, subjects.get(key)!)
					blocks.push({kind: 'directive', line, endLine: endOf(node), detail: `min_subjects: ${req.minSubjects}`})
					continue
				}
				if (/^No minimum\b/i.test(text)) {
					req.minSubjects = 0
					blocks.push({kind: 'directive', line, endLine: endOf(node), detail: 'min_subjects: 0'})
					continue
				}
				if (/^One \S.* must satisfy all of these\.?$/i.test(text)) {
					req.require = 'some'
					blocks.push({kind: 'directive', line, endLine: endOf(node), detail: 'require: some'})
					continue
				}
			}

			// Prose. Warn only if a sentence looks like a rule that failed to land.
			for (const s of sentences(atoms)) {
				try {
					matchRule(s, ctx, true)
				} catch (e) {
					if (e instanceof RuleError) warn(line, e.message)
				}
			}
			blocks.push({kind: 'prose', line, endLine: endOf(node), detail: text.slice(0, 60)})
			continue
		}

		if (node.type === 'list') {
			if (listRole === 'patterns' && pendingConstant) {
				const patterns = (node.children ?? []).map((item) => plain(atomize(((item.children ?? [])[0]?.children ?? []) as never[])))
				ctx.constants.set(pendingConstant, patterns)
				// The heading paragraph and its list are one declaration, not two.
				const head = blocks[blocks.length - 1]
				if (head && head.kind === 'constant' && head.label === pendingConstant) {
					head.endLine = endOf(node)
					head.detail = `${patterns.length} patterns`
				} else {
					blocks.push({kind: 'constant', line, endLine: endOf(node), label: pendingConstant, detail: `${patterns.length} patterns`})
				}
				pendingConstant = null
				listRole = null
				continue
			}

			if (listRole === 'substitutes') {
				for (const item of node.children ?? []) {
					const parsed = readRule(item)
					if (!parsed) continue
					ctx.substitutes.set(parsed.name, parsed.check)
					blocks.push({
						kind: 'substitute',
						line: lineOf(item),
						endLine: endOf(item),
						label: parsed.name,
						op: String(parsed.check['op']),
					})
				}
				continue
			}

			if (req && (listRole === 'scope' || listRole === 'checks')) {
				for (const item of node.children ?? []) {
					const parsed = readRule(item)
					if (!parsed) continue
					const target = listRole === 'scope' ? req.appliesTo : req.checks
					if (target[parsed.name]) err(lineOf(item), `${parsed.name}: already defined in this requirement`)
					target[parsed.name] = parsed.check
					blocks.push({
						kind: listRole === 'scope' ? 'scope' : 'rule',
						line: lineOf(item),
						endLine: endOf(item),
						label: parsed.name,
						op: String(parsed.check['op']),
						detail: String(parsed.check['expression'] ?? ''),
					})
				}
				continue
			}

			blocks.push({kind: 'prose', line, endLine: endOf(node), detail: 'list'})
			continue
		}

		blocks.push({kind: 'prose', line, endLine: endOf(node), detail: node.type})
	}

	// ---------------------------------------------------------------- emit

	const requirements: Record<string, unknown> = {}
	if (subjects.size === 0) err(0, 'no subject declared: say `A **thing** is each of `path`, identified by its `path`.`')

	for (const r of reqs) {
		if (!Object.keys(r.checks).length) {
			err(r.line, `${r.name}: declares no checks, so it asserts nothing`)
			continue
		}
		if (!r.subject && subjects.size > 1) {
			err(r.line, `${r.name}: several subjects are declared, so say which one this is about — \`For each **${[...subjects.values()][0]!.def.subjectType}**.\``)
			continue
		}
		const out: Record<string, unknown> = {}
		const subject = r.subject?.def
		if (subject) {
			out['subject_type'] = subject.subjectType
			out['from'] = subject.from
			out['id'] = subject.id
		}
		if (r.minSubjects !== undefined) out['min_subjects'] = r.minSubjects
		if (r.require !== undefined) out['require'] = r.require
		if (Object.keys(r.appliesTo).length) out['applies_to'] = r.appliesTo
		out['checks'] = r.checks
		requirements[r.name] = out
	}

	diagnostics.push(...validateRequirements(requirements, customOpNames))

	const summaries: SubjectSummary[] = [...subjects.values()].map((e) => ({
		name: e.def.subjectType,
		subjectType: e.def.subjectType,
		from: e.def.from,
		id: e.def.id,
		line: e.def.line,
		properties: [...e.props.values()].map((p) => ({display: p.display, path: p.path, pathText: renderDeclared(p.path, p.splits)})),
	}))

	return {
		blocks,
		subjects: summaries,
		requirements,
		diagnostics,
		ok: !diagnostics.some((d) => d.severity === 'error'),
	}
}

export type {Analysis, Block, Diagnostic} from './types.ts'
export {validateRequirements} from './validate.ts'

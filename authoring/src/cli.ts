#!/usr/bin/env -S npx tsx
// The shell around core/. Everything that touches a file, the process or the
// terminal lives here and nowhere below, so core/ stays usable in a browser.
//
//   evidence-md policy.md -o data.yaml    emit the requirements object
//   evidence-md policy.md --explain       what each block became
//   evidence-md policy.md --check         diff against the committed object
//   evidence-md --lint spec.yaml          validate any requirements object
//   evidence-md policy.md --apply s.yaml  write an edited object back into the
//                                         Markdown, rewriting only the bullets
//                                         whose checks changed

import {execFileSync} from 'node:child_process'
import {readFileSync, writeFileSync} from 'node:fs'
import {dirname, join, relative} from 'node:path'
import {fileURLToPath} from 'node:url'
import {parse as parseYaml, stringify as toYaml} from 'yaml'

import {analyze} from './core/index.ts'
import {applyRequirements, differences} from './core/patch.ts'
import {validateRequirements} from './core/validate.ts'
import type {Analysis, Check, CustomOpRegistry, Diagnostic} from './core/types.ts'
import {renderPath} from './core/paths.ts'

const HERE = dirname(fileURLToPath(import.meta.url))

function registry(): CustomOpRegistry {
	const raw = JSON.parse(readFileSync(join(HERE, '..', 'custom_ops.json'), 'utf8')) as Record<string, unknown>
	delete raw['_comment']
	return raw as CustomOpRegistry
}

const HEADER = `# GENERATED from %s by authoring/src/cli.ts — do not edit.
#
# The Markdown is the source of truth; this object is what gets loaded, hashed
# and attested. Regenerate with:
#
#   npx tsx authoring/src/cli.ts %s -o %s
#
# A check that used to be here and no longer compiles fails the build rather
# than vanishing quietly: \`--check\` diffs this file against a fresh compile.
`

function report(diagnostics: Diagnostic[], file: string): void {
	for (const d of diagnostics) {
		const where = d.line ? `${file}:${d.line}` : file
		process.stderr.write(`${d.severity}: ${where}: ${d.message}\n`)
	}
}

/**
 * The rendered expression of every check, taken from the library itself rather
 * than reimplemented here. `expression_of`/`leaf_describe` in src/library.rego
 * are the canonical rendering; a second copy in TypeScript would be one more
 * thing to keep in step, and the whole point of showing it is that it is what
 * the evaluator will say.
 *
 * Needs `opa` on PATH. Without it `--explain` still works, showing the emitted
 * check instead — which is also what a browser editor would show.
 */
function renderedExpressions(requirements: Record<string, unknown>): Map<string, string> {
	const out = new Map<string, string>()
	try {
		const library = join(HERE, '..', '..', 'src', 'library.rego')
		const raw = execFileSync('opa', ['eval', '-d', library, '-I', '--format=json', 'data.kosli.evidence.report(input.doc, input.req)'], {
			input: JSON.stringify({doc: {}, req: requirements}),
			encoding: 'utf8',
			stdio: ['pipe', 'pipe', 'ignore'],
		})
		const value = JSON.parse(raw).result?.[0]?.expressions?.[0]?.value as
			| {requirements?: Record<string, {checks?: Record<string, {expression?: string}>}>}
			| undefined
		for (const [rname, req] of Object.entries(value?.requirements ?? {}))
			for (const [cname, check] of Object.entries(req.checks ?? {}))
				if (check.expression) out.set(`${rname}.${cname}`, check.expression)
	} catch {
		// opa absent or the spec does not evaluate; fall back to structure.
	}
	return out
}

/** A structural one-liner for a check, for when the library cannot be asked. */
function shape(check: Check): string {
	const op = String(check['op'])
	const path = Array.isArray(check['path']) ? renderPath(check['path'] as never) : ''
	if (op === 'all' || op === 'any') return `${op} ${path} -> ${shape(check['check'] as Check)}`
	if (check['value'] !== undefined) return `${path} == ${String(check['value'])}`
	return `${op} ${path}`.trim()
}

function explain(result: Analysis, file: string): void {
	const blocks = result.blocks
	process.stdout.write(`${file}\n\n`)
	const rendered = renderedExpressions(result.requirements as Record<string, unknown>)
	// Fallback for anything the library does not render by name: applies_to
	// filters land in the synthesised `$applies` row, and substitutes are
	// carried inside the check they belong to.
	const shapes = new Map<string, string>()
	for (const req of Object.values(result.requirements as Record<string, Record<string, unknown>>))
		for (const group of ['checks', 'applies_to'])
			for (const [name, check] of Object.entries((req[group] ?? {}) as Record<string, Check>)) shapes.set(name, shape(check))
	const width = Math.max(...blocks.map((b) => String(b.line).length), 2)
	let requirement = ''

	for (const b of blocks) {
		if (b.kind === 'requirement') requirement = b.label ?? ''
		const line = `L${String(b.line).padStart(width)}`
		const head = `  ${line}  ${b.kind.padEnd(12)}`

		if (b.kind === 'prose') {
			const snippet = (b.detail ?? '').replace(/\s+/g, ' ').trim()
			if (!snippet) continue
			process.stdout.write(`${head}${snippet.length > 56 ? snippet.slice(0, 53) + '...' : snippet}\n`)
			continue
		}

		process.stdout.write(`${head}${b.label ?? ''}${b.op ? `  ${b.op}` : ''}\n`)

		const isCheck = b.kind === 'rule' || b.kind === 'scope' || b.kind === 'substitute'
		const expr = isCheck ? (rendered.get(`${requirement}.${b.label}`) ?? shapes.get(b.label ?? '')) : undefined
		const detail = expr ? `"${expr}"` : isCheck ? '' : b.detail
		if (detail) process.stdout.write(`  ${' '.repeat(width + 14)}${detail}\n`)
	}

	const n = (k: string): number => blocks.filter((b) => b.kind === k).length
	const near = result.diagnostics.filter((d) => d.severity === 'warning').length
	const plural = (c: number, word: string): string => `${c} ${word}${c === 1 ? '' : 's'}`
	process.stdout.write(
		`\n  ${plural(n('rule'), 'check')}, ${plural(n('scope'), 'scope filter')}, ` +
			`${plural(n('substitute'), 'substitute')}, ` +
			`${plural(near, 'unclaimed sentence')} that look like rules\n`,
	)
}

/** Name what changed, rather than printing two objects and leaving the reader
 *  to find it. A lost check is the case this exists for. */
function diffChecks(before: unknown, after: unknown): {lost: string[]; added: string[]; changed: string[]} {
	const flat = (o: unknown): Map<string, string> => {
		const out = new Map<string, string>()
		for (const [rname, req] of Object.entries((o ?? {}) as Record<string, Record<string, unknown>>))
			for (const group of ['checks', 'applies_to'])
				for (const [cname, check] of Object.entries((req?.[group] ?? {}) as Record<string, unknown>))
					out.set(`${rname}.${cname}`, JSON.stringify(check, Object.keys(check as object).sort()))
		return out
	}
	const a = flat(before)
	const b = flat(after)
	return {
		lost: [...a.keys()].filter((k) => !b.has(k)),
		added: [...b.keys()].filter((k) => !a.has(k)),
		changed: [...a.keys()].filter((k) => b.has(k) && a.get(k) !== b.get(k)),
	}
}

function main(argv: string[]): number {
	const lintAt = argv.indexOf('--lint')
	if (lintAt >= 0) {
		const file = argv[lintAt + 1]
		if (!file) {
			process.stderr.write('--lint needs a file\n')
			return 2
		}
		const doc = parseYaml(readFileSync(file, 'utf8')) as {requirements?: unknown}
		const diagnostics = validateRequirements(doc?.requirements ?? doc, new Set(Object.keys(registry())))
		report(diagnostics, file)
		if (!diagnostics.length) process.stdout.write(`${file}: valid\n`)
		return diagnostics.some((d) => d.severity === 'error') ? 1 : 0
	}

	const file = argv.find((a) => !a.startsWith('-') && a.endsWith('.md'))
	if (!file) {
		process.stderr.write('usage: evidence-md <policy.md> [-o data.yaml] [--explain] [--check] [--apply spec.yaml]\n')
		return 2
	}

	const source = readFileSync(file, 'utf8')
	const result = analyze(source, {customOps: registry()})

	if (argv.includes('--explain')) {
		explain(result, file)
		report(result.diagnostics, file)
		return result.ok ? 0 : 1
	}

	report(result.diagnostics, file)
	if (!result.ok) return 1

	const applyAt = argv.indexOf('--apply')
	if (applyAt >= 0) {
		const spec = argv[applyAt + 1]
		if (!spec) {
			process.stderr.write('--apply needs a requirements file\n')
			return 2
		}
		const doc = parseYaml(readFileSync(spec, 'utf8')) as {requirements?: Record<string, unknown>}
		const patch = applyRequirements(source, result, doc?.requirements ?? {}, registry())

		// The patch is best-effort; this is what makes it safe. Recompile what
		// it produced and insist it says exactly what was asked for, so an
		// operator the writer cannot spell fails the command rather than
		// half-landing in the document.
		const after = analyze(patch.markdown, {customOps: registry()})
		const drift = differences(after.requirements, doc?.requirements ?? {})
		for (const r of patch.refusals) process.stderr.write(`error: ${file}: ${r}\n`)
		if (patch.refusals.length || drift.length) {
			if (drift.length && !patch.refusals.length)
				for (const d of drift) process.stderr.write(`error: ${file}: ${d} does not come back from the patched document\n`)
			process.stderr.write(`${file}: not written\n`)
			return 1
		}
		for (const c of patch.changes) process.stdout.write(`  ${c}\n`)
		if (!patch.changes.length) process.stdout.write(`${file}: already says this\n`)
		else writeFileSync(file, patch.markdown)
		return 0
	}

	const outAt = argv.indexOf('-o')
	const out = outAt >= 0 ? argv[outAt + 1] : undefined
	const body = toYaml({requirements: result.requirements}, {lineWidth: 0})

	if (argv.includes('--check')) {
		const target = out ?? join(dirname(file), 'data.yaml')
		const committed = parseYaml(readFileSync(target, 'utf8')) as {requirements?: unknown}
		const {lost, added, changed} = diffChecks(committed?.requirements, result.requirements)
		for (const k of lost) process.stderr.write(`error: ${target}: check "${k}" no longer compiles from ${file}\n`)
		for (const k of added) process.stderr.write(`error: ${target}: check "${k}" is new and not committed\n`)
		for (const k of changed) process.stderr.write(`error: ${target}: check "${k}" changed\n`)
		if (lost.length || added.length || changed.length) return 1
		if (toYaml(committed, {lineWidth: 0}) !== toYaml({requirements: result.requirements}, {lineWidth: 0})) {
			process.stderr.write(`error: ${target}: differs from a fresh compile of ${file}\n`)
			return 1
		}
		process.stdout.write(`${target}: up to date with ${file}\n`)
		return 0
	}

	if (!out) {
		process.stdout.write(body)
		return 0
	}
	const rel = relative(dirname(out), file) || file
	writeFileSync(out, HEADER.replace('%s', rel).replace('%s', file).replace('%s', out) + body)
	process.stdout.write(`${out}: ${Object.keys(result.requirements).length} requirements\n`)
	return 0
}

process.exit(main(process.argv.slice(2)))

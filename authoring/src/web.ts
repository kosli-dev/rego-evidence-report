// The browser shell around core/, symmetric with cli.ts.
//
// cli.ts brings fs, process and exit codes; this brings the custom-op registry
// and a YAML renderer. Neither adds a line of parsing. core/ is imported
// unchanged and unbundled-for — the point of keeping it free of node:* imports
// is that an editor and the transpiler cannot disagree about what is a rule.
//
//   npm run bundle   ->  dist/web.js

import {fromMarkdown} from 'mdast-util-from-markdown'
import {gfmTable} from 'micromark-extension-gfm-table'
import {gfmTableFromMarkdown} from 'mdast-util-gfm-table'
import {parse as fromYaml, stringify as toYaml} from 'yaml'
import customOps from '../custom_ops.json' with {type: 'json'}
import {analyze} from './core/index.ts'
import {applyRequirements, differences} from './core/patch.ts'
import {validateRequirements} from './core/validate.ts'
import type {Analysis, CustomOpRegistry} from './core/types.ts'

const registry = (): CustomOpRegistry => {
	const raw = {...(customOps as Record<string, unknown>)}
	delete raw['_comment']
	return raw as CustomOpRegistry
}

export function compile(markdown: string): Analysis & {yaml: string} {
	const result = analyze(markdown, {customOps: registry()})
	return {...result, yaml: toYaml({requirements: result.requirements}, {lineWidth: 0})}
}

/**
 * The parsed document, for rendering it. Same parser and same options as
 * core/index.ts uses, so a rendered view cannot show a structure the
 * transpiler did not see — which is the whole reason not to reach for a
 * second Markdown library in the page.
 */
export function parse(markdown: string): unknown {
	return fromMarkdown(markdown, {extensions: [gfmTable()], mdastExtensions: [gfmTableFromMarkdown()]})
}

export interface ApplyResult {
	markdown: string
	/** What the patch rewrote, in the author's terms. */
	changes: string[]
	/** What had no prose form and was left in the YAML only. */
	refusals: string[]
	/** The checks that moved, so a caller can point at the first of them. */
	touched: string[]
	/** Where the recompiled document still disagrees with what was asked for.
	 *  Empty is the contract; anything here means the patch is not accepted. */
	drift: string[]
	ok: boolean
	error?: string
}

/**
 * Write an edited requirements object back into the Markdown that produced it.
 *
 * The patch itself is best-effort — an operator with no prose form is refused
 * by name. What makes it safe to run on every keystroke is the last step:
 * recompile the patched source and check it says exactly what was asked for.
 * An incomplete writer then shows up as a refusal, never as mangled prose.
 */
export function applyYaml(markdown: string, yamlText: string): ApplyResult {
	let target: Record<string, unknown>
	try {
		const doc = fromYaml(yamlText) as {requirements?: Record<string, unknown>} | null
		target = (doc?.requirements ?? {}) as Record<string, unknown>
		if (typeof target !== 'object' || Array.isArray(target)) throw new Error('`requirements` must be a mapping')
	} catch (e) {
		return {markdown, changes: [], refusals: [], touched: [], drift: [], ok: false, error: (e as Error).message}
	}

	const before = analyze(markdown, {customOps: registry()})
	const patched = applyRequirements(markdown, before, target, registry())
	const after = analyze(patched.markdown, {customOps: registry()})
	const drift = differences(after.requirements, target)

	return {
		markdown: patched.markdown,
		changes: patched.changes,
		refusals: patched.refusals,
		touched: patched.touched,
		drift,
		ok: drift.length === 0 && after.ok,
	}
}

export {analyze, validateRequirements, differences}
export {VOCABULARY} from './core/grammar.ts'
export const customOpNames = (): string[] => Object.keys(registry())

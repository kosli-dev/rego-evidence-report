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
import {stringify as toYaml} from 'yaml'
import customOps from '../custom_ops.json' with {type: 'json'}
import {analyze} from './core/index.ts'
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

export {analyze, validateRequirements}
export {VOCABULARY} from './core/grammar.ts'
export const customOpNames = (): string[] => Object.keys(registry())

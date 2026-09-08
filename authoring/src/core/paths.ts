// Dotted path notation, and the two forms that are not plain keys.
//
//   ci_checks[].conclusion
//     -> ["ci_checks", "conclusion"], one boundary after segment 1
//
//   compliance_status.attestations_statuses[attestation_type=pull_request]
//     -> ["compliance_status", "attestations_statuses",
//         {where: {attestation_type: "pull_request"}}]
//
// A selector is `the one element whose key is value`, and the library fails
// closed on two matches. A boundary is where a collection is quantified over;
// two is the limit, because Rego forbids recursion and the library buys each
// level of nesting with a distinct rule name.

import type {Path, Segment} from './types.ts'

export interface ParsedPath {
	path: Path
	splits: number[]
}

/** Coerce a literal written in the document. `true` is a boolean because the
 *  library compares with `==` and would never match the string. */
export function literal(raw: string): unknown {
	if (raw === 'true') return true
	if (raw === 'false') return false
	if (raw === 'null') return null
	if (/^-?\d+$/.test(raw)) return Number(raw)
	if (/^-?\d*\.\d+$/.test(raw)) return Number(raw)
	return raw
}

/** Split on `.`, but not inside brackets — a selector value may contain one. */
function tokenize(text: string): string[] {
	const out: string[] = []
	let buf = ''
	let depth = 0
	for (const ch of text) {
		if (ch === '[') depth++
		else if (ch === ']') depth--
		if (ch === '.' && depth === 0) {
			out.push(buf)
			buf = ''
			continue
		}
		buf += ch
	}
	out.push(buf)
	return out.filter((t) => t.length > 0)
}

export function parsePath(text: string): ParsedPath {
	const path: Path = []
	const splits: number[] = []

	for (const token of tokenize(text.trim())) {
		const m = /^([^[\]]*)(\[(.*)\])?$/.exec(token)
		if (!m) throw new Error(`cannot read path segment "${token}"`)
		const [, key = '', bracket, inner] = m

		if (key) path.push(key)

		if (bracket === undefined) continue

		if (inner === '') {
			// A collection boundary: everything after this is inside an element.
			splits.push(path.length)
			continue
		}

		const eq = (inner ?? '').indexOf('=')
		if (eq < 0) throw new Error(`selector "${inner}" is not key=value`)
		const field = (inner ?? '').slice(0, eq).trim()
		const value = (inner ?? '').slice(eq + 1).trim()
		path.push({where: {[field]: literal(value)}})
	}

	return {path, splits}
}

/** Render a path back for diagnostics, in the same notation it was written. */
export function renderPath(path: Path): string {
	return path
		.map((seg: Segment) =>
			typeof seg === 'string'
				? seg
				: '[' +
					Object.entries(seg.where)
						.map(([k, v]) => `${k}=${String(v)}`)
						.join(' ') +
					']',
		)
		.join('.')
		.replace(/\.\[/g, '[')
}

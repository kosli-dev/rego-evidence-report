// The shape of everything the core produces. No I/O appears anywhere under
// core/ — it takes a Markdown string and returns data, so the same module runs
// in a CLI, an editor and a linter without change.

/** One segment of a path into the input document, or a selector over it. */
export type Segment = string | {where: Record<string, unknown>}
export type Path = Segment[]

/** A check as the library consumes it. Deliberately loose: the vocabulary is
 *  closed but the object is plain data, and validate.ts is what narrows it. */
export type Check = Record<string, unknown>

/** A property declared in the subject table. `splits` records where `[]`
 *  boundaries fell, as counts of segments before each one — one boundary makes
 *  the property quantifiable, two produce the `each` projection. */
export interface PropertyDef {
	display: string
	path: Path
	splits: number[]
}

export interface SubjectDef {
	subjectType: string
	from: Path
	id: Path
	line: number
}

export type BlockKind =
	| 'prose'
	| 'subject'
	| 'properties'
	| 'constant'
	| 'substitute'
	| 'requirement'
	| 'directive'
	| 'scope'
	| 'rule'

/** Every block of the document, classified. An editor highlights from this,
 *  `--explain` prints it, and the two are the same data by construction. */
export interface Block {
	kind: BlockKind
	line: number
	endLine: number
	/** Machine name, where the block has one. */
	label?: string
	/** What it resolved to, in one line. */
	detail?: string
	/** For a rule: the operator it matched. */
	op?: string
}

export interface Diagnostic {
	severity: 'error' | 'warning'
	line: number
	message: string
}

/** A declared subject and the properties that belong to it. Part of the
 *  analysis because an editor needs to show what a document declares, not only
 *  what it compiles to. */
export interface SubjectSummary {
	name: string
	subjectType: string
	from: Path
	id: Path
	line: number
	properties: Array<{display: string; path: Path; pathText: string}>
}

export interface Analysis {
	blocks: Block[]
	subjects: SubjectSummary[]
	/** Names a rule may refer to: `, or else \`initial_commit\`` and
	 *  `treating **web-flow authors** as explained`. */
	substitutes: string[]
	constants: string[]
	requirements: Record<string, unknown>
	diagnostics: Diagnostic[]
	/** True when nothing of severity 'error' was raised. */
	ok: boolean
}

/** What a custom operator needs that the library cannot derive: its own
 *  human-readable expression, and the fields it reads. */
export interface CustomOp {
	/** The prose that selects this operator, after any leading quantifier. */
	phrase: string
	expression: string
	/** Each entry is either a path relative to the subject, or a projection
	 *  through the property the rule names. */
	inputs: Array<{subject: string[]} | {each: string[]}>
}

export type CustomOpRegistry = Record<string, CustomOp>

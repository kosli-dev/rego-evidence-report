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
	/** The table row it was declared on, where it was declared in a table. */
	line?: number
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

/**
 * Where a construct came from, as source offsets, so an edit made to the
 * compiled object can be written back into the Markdown that produced it.
 *
 * Offsets rather than lines because a patch replaces a span, not a row, and
 * recorded here rather than recomputed by a second traversal — a writer that
 * finds bullets its own way would eventually disagree with the reader about
 * which bullet is which, which is the one failure this must not have.
 */
export interface Anchor {
	kind: 'rule' | 'scope' | 'substitute' | 'requirement' | 'list' | 'directive' | 'table'
	/** The requirement a rule, scope filter, list or directive belongs to. */
	requirement?: string
	/** A check's name, or for a directive the field it sets. */
	name?: string
	start: number
	end: number
	/** For a list: the indent of its items, so an appended one lines up. */
	indent?: string
	/** For a rule: the quantifier the author wrote. It does not survive into
	 *  the object, so re-rendering an edited bullet would otherwise silently
	 *  replace "every" with "some". */
	lead?: string
	/** For a rule: the bold text the author used for the property it is about,
	 *  which the plural-tolerant lookup means the object cannot recover. */
	head?: string
	/** For a requirement: where a directive or a new list may be inserted. */
	insertAt?: number
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
	properties: Array<{
		display: string
		path: Path
		pathText: string
		line?: number
		/** Whether any rule reads it. A declared name nothing reads is dead
		 *  prose: harmless, but the author is the only one who can say so. */
		used: boolean
	}>
}

/** What a rendered rule resolves against: the same declarations the parser
 *  read, kept so the two directions cannot disagree about what `**X**` means. */
export interface DocContext {
	constants: Record<string, unknown[]>
	substitutes: Record<string, Check>
	/** Requirement name -> the properties its subject declares. */
	properties: Record<string, PropertyDef[]>
	/** Everything declared anywhere, for document-level constructs. */
	all: PropertyDef[]
	/** Requirement name -> the subject type it is about, which is how a new
	 *  property finds the table it belongs in. */
	subjectOf: Record<string, string>
}

export interface Analysis {
	blocks: Block[]
	anchors: Anchor[]
	context: DocContext
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

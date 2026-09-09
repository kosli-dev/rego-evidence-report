# The Markdown policy grammar

A control is a Markdown document that compiles to a `kosli.evidence`
`requirements` object. The object stays the artifact that is hashed, attested
and evaluated; the Markdown is the authoring and review surface.

Two conventions carry the whole notation:

- **bold** — a subject, a declared property, or a declared constant. A sentence
  is only ever read as a rule if it references one, which is why rationale may
  say "must" as often as it likes without being parsed.
- `code` — a raw path, a literal value, or an identifier. In *name position* it
  is an identifier: at the **end of a heading** it names a requirement, at the
  **start of a bullet** it names a check.

Everything that is not a rule is prose, and prose is never guessed at.

## Document structure

**Headings are yours.** Their text and their level carry no meaning, with one
exception: a heading ending in a backticked name opens a requirement, and a
heading at the same level or shallower closes it. Everything else is found by
its own shape, wherever it sits — so a section may be called "Subjects",
"Considered items" or nothing at all, and a subject may sit under its own H3.

| Written like this | Produces |
| --- | --- |
| `A **thing** is each of \`path\`, identified by its \`path\`.` | a subject |
| a two-column table, second column paths | that subject's properties |
| `**Name** are …:` then a list of `` `patterns` `` | a named constant |
| a named bullet outside any requirement | a named substitute |
| `## Any text \`name\`` | a requirement named `name` |
| `In scope:` + bullets | that requirement's `applies_to` |
| `Must hold:` + bullets | that requirement's `checks` |
| anything else | prose, and never guessed at |

Those last two are the **only** keywords in the language, and they are
irreducible: a scope filter and a check are the same sentence in the same shape,
and nothing can tell them apart from the outside. A list of named bullets with
neither lead-in is an error — it used to be silently discarded, which took the
scope filter with it and left a policy that had quietly stopped exempting
anything.

A declaration may appear anywhere, including after the requirement that uses it:
the transpiler reads declarations first and rules second.

### Subjects

```markdown
A **deployment** is each of `deployments`, identified by its `name`.
```

→ `subject_type: deployment`, `from: [deployments]`, `id: [name]`.

Then a property table binding a prose name to a path:

```markdown
| Property   | Path                     |
| ---------- | ------------------------ |
| approver   | `approved_by`            |
| conclusion | `ci_checks[].conclusion` |
```

Paths are dotted. Two forms are special:

- `[key=value]` is a **selector** — *the one element of this collection whose
  `key` is `value`* — and becomes `{"where": {key: value}}`. One per path.
  Ambiguity fails closed: two matching elements is not a match.
- `[]` marks a **collection boundary**. One `[]` lets a property be quantified
  over with `every`/`at least one`; two produce the `each` projection. Two is
  the limit, because Rego forbids recursion and the library buys each level of
  nesting with a distinct rule name.

A rule naming an undeclared property is an **error**. This is deliberate: the
library itself validates nothing, so a misspelled field silently becomes a check
that can never pass. The transpiler is where that gets caught.

### More than one subject

A document may declare several, and a real control often must — an artifact, an
attestation and a pull request are not the same kind of thing, live at different
paths and are identified differently. Each subject sentence starts a new subject,
and the property tables that follow it belong to that subject:

```markdown
An **artifact** is each of `artifacts`, identified by its `fingerprint`.

| Property    | Path          |
| ----------- | ------------- |
| fingerprint | `fingerprint` |

A **pull request** is each of `pull_requests`, identified by its `url`.

| Property | Path       |
| -------- | ---------- |
| state    | `state`    |
```

**Properties are scoped to their subject.** Two subjects may each declare a
`state`, and a rule resolves against its own requirement's subject only —
reaching for another subject's property is an error, not a silent mis-binding.

A requirement then says which subject it is about:

| Prose | Effect |
| --- | --- |
| `For each **artifact**.` | this requirement's subject |
| `At least one **artifact** must be in scope.` | the same, and `min_subjects` with it |

With exactly one subject declared, neither line is needed. With more than one, a
requirement that names none is an error — the alternative is guessing, and a
requirement bound to the wrong subject produces a report that reads as though it
judged something it never looked at.

### Requirements

```markdown
## Every production deployment `prod_deploy`
```

The heading is prose; the backticked token at its end is the machine name, which
appears in every report row and in `violations`. It is written explicitly rather
than slugified from the heading, so that rewording the heading does not silently
rename the check an auditor has been reading for a year.

Two optional lines before the bullets:

| Prose | Produces |
| --- | --- |
| `At least N **X** must be in scope.` | `min_subjects: N` |
| `No minimum — …` | `min_subjects: 0` |
| `One **X** must satisfy all of these.` | `require: some` |

Default is `min_subjects: 1` and `require: every`.

### Checks

```markdown
- `approved` — the **approver** must be a non-empty string.
  A named approver signed off on the deployment.
```

The first sentence is the rule. Every sentence after it, in the same bullet,
becomes the check's `description` — which is what `violations` reports and what
an auditor reads. The rule is stated once, not once in code and again in a
description maintained beside it.

The description's trailing full stop is dropped, because every description in
the existing specs is a phrase rather than a sentence and the report renders
them inline.

## Operators

Ten leaf operators, over a declared property:

| Prose | `op` |
| --- | --- |
| the **X** must be `v` | `equals` |
| the **X** must be present | `present` |
| the **X** must be a non-empty string | `non_empty_string` |
| the **X** must match one of `p`, `q` | `matches_any` |
| the **X** must match none of `p`, `q` | `not_matches_any` |
| the **X** must be between `0` and `10` | `range` |
| the **X** must include `v` | `includes` |
| the **X** must not include `v` | `excludes` |
| the **X** must be *&lt;cmp&gt;* the **Y** | `compare` |
| the **X** must be after / before the **Y** | `compare_time` |

`matches_any` and `not_matches_any` may name a constant instead of listing
patterns: *the **author** must match one of **web-flow authors***.

`compare` and `compare_time` take **two properties of the same subject**, never
a literal — to bound a field against a constant, use `between`:

| Prose | `cmp` |
| --- | --- |
| equal to / different from | `eq` / `ne` |
| greater than / at least | `gt` / `gte` |
| less than / at most | `lt` / `lte` |
| after / at or after | `gt` / `gte` |
| before / at or before | `lt` / `lte` |

Two collection operators, over a property with a `[]` boundary:

| Prose | `op` |
| --- | --- |
| every **X** must … | `all` |
| at least one **X** must … | `any` |

Both fail on a missing, non-array or **empty** collection. A property with two
`[]` boundaries compiles to the same operator with an `each` projection.

One combinator, for when two fields must agree with each other:

```markdown
- `permitted` — one of these must hold:
  - `standard` — the **type** must match one of `^Story$`,
    and the **state** must match one of `^CLOSED$`.
  - `cloud` — the **type** must match one of `^JS Story$`,
    and the **state** must match one of `^DONE$`.
```

→ `any_of`. Each nested bullet is a named option, all of whose clauses must
hold; the check passes if some option does. **Name the options** — the name is
what the rendered expression shows.

Reach for it the moment a rule says *"both of these, or both of those"*. Writing
the two fields as independent checks accepts every cross-product and silently
over-passes.

Options contain leaf clauses only, and collection operators contain a single
leaf clause or an `any_of`. This is the recursion limit again, and it is why
depth is bought one level at a time.

## Substitutes

```markdown
- `initial_commit` — the **initial-commit evidence** must be `true`.
  A compliant initial-commit-by-verified-committer attestation stands in.
```

Referenced from any check by appending `, or else \`initial_commit\``. The
rendered expression becomes `<check>, or substitute: <substitute>`, so the
report shows both readings.

A substitute is for *"this check, or this different evidence entirely"* — a case
the rule was never meant to catch. It is not a second option of the same rule;
that is `any_of`.

## Custom operators

When the vocabulary cannot express a rule, prose names the operator and what it
applies to:

```markdown
- `independently_approved` — some **pull request** must be independently
  approved, treating **web-flow authors** as explained.
  Some pull request has an approval from someone other than each of its authors.
```

The operator's `expression` and `inputs` come from
`authoring/custom_ops.json`, maintained once beside the Rego file that defines
it. The library cannot render an operator it does not know, so a custom operator
must declare its own human-readable expression; `inputs` is the list of fields it
reads, so the row still carries enough to recompute its verdict.

This is the one place a step-like translation layer returns — **one entry per
operator**, not one per sentence.

## Recording extra inputs

```markdown
  Records the **pull requests**' `url`.
```

Adds an entry to the check's `inputs`, so the failing row echoes that field.
Only needed when the interesting evidence is not the field the check tested.

## What the transpiler will not do

- **Guess.** A sentence that references no declared property is prose, full
  stop, whatever verbs it uses.
- **Silently drop a rule.** `--check` recompiles and diffs against the committed
  object; a check that used to exist and no longer compiles fails the build,
  naming what was lost. Removing a rule on purpose means committing the diff.
- **Accept an unknown operator.** The library would turn it into a check that
  can never pass. Here it is an error.

For a new document there is no committed object to diff against, so `--explain`
additionally warns on any block containing a code span and a modal verb that
matched nothing.

## Editing the object instead

The YAML is editable too, and a change made there is written back into the
Markdown without disturbing a word of the prose around it.

```sh
npx tsx authoring/src/cli.ts policy.md --apply spec.yaml
```

The Markdown stays the document of record, and it is never regenerated —
regeneration would be lossy, since the rationale paragraphs are not in the
object. What is applied is the *diff*: every difference between the compiled
object and the edited one names a construct, every construct has a recorded
source range, and the patch rewrites those ranges and nothing else. A changed
threshold rewrites one bullet; the four paragraphs around it are never
addressed, so they cannot move.

Inside a bullet there is nothing to lose either: every sentence that is not the
rule and not a `Records …` becomes `description`, which is in the object. So a
bullet can be rewritten whole. The author's own wording survives the rewrite —
the quantifier they chose, and their spelling of a property the table declares
in the plural — because both are recorded when the sentence is read.

**The property table is the one thing the object does not have.** `from`, `id`
and `subject_type` are fields the requirement needs anyway, but *naming*
`approved_by` "**approver**" happens only in the Markdown. So a check added to
the object can be entirely valid and still have no prose form, for a reason that
is not the object's fault — nobody has named the path it reads. The writer
declares it rather than refusing: it adds a row to the subject's table, names it
after the path's last segment, and says so.

```
added prod_deploy.window_open · named `release.change_window` **change window**
```

The name is mechanical, and renaming it is a one-word edit that changes nothing
in the object — which is the point: prose names have no counterpart to break.

Two edits are lossy, and say so:

- **Deleting a check** deletes its bullet, and the description written under it.
  That prose existed to explain that check.
- **Changing `min_subjects`** rewrites the sentence that set it, and any
  reasoning written into that sentence goes with it.

An edit with no prose form — an operator outside the vocabulary, a path no
property declares — is refused by name rather than approximated. Nothing is
written at all in that case: the patch is applied, recompiled, and checked
against what was asked for, and only a document that compiles back to exactly
that object is kept. So an incomplete writer shows up as a refusal, never as
mangled prose.

`npm run roundtrip` holds that to three properties over the real policies:
applying a document's own YAML to it changes nothing; touching every check
sends every bullet through the writer and still recompiles to the object asked
for; and every paragraph of prose is still there afterwards, byte for byte.

## What has no home yet

Requirement-level rationale. The report projects a requirement as exactly
`{require, satisfied, subjects, checks}`, so prose attached to a requirement
lives in the Markdown and never reaches the report. Carrying it through is a
small additive library change, tracked separately.

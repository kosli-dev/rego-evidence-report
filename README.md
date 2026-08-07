# kosli.evidence

A Rego library that turns policy evaluation into a structured, hashable
**evidence report**, instead of a bare `allow`/`deny` plus hand-written
violation strings.

You don't write evaluation or reporting logic. You declare, as data, the things
being checked and the checks that apply to them — and the library produces a
uniform report: which checks ran, against which things, what values they read,
and what each one concluded. The same shape regardless of which policy produced
it, so it can be hashed, attested, and consumed without parsing Rego.

The practical difference: a hand-written policy fails with a string someone
wrote. This library fails with a row naming the thing that failed, the named
check that failed, and the input values it read.

**New here?** Read [Vocabulary](#vocabulary), then follow
[Your first policy](#your-first-policy) with a terminal open. The
[Reference](#reference) is for looking things up afterwards.

<details>
<summary><strong>New to Rego?</strong> Enough to read the code in this repo.</summary>

- Rego is the policy language of [OPA](https://www.openpolicyagent.org/). Files
  declare a `package`; everything in a package is merged, so two files can
  contribute rules to the same package (that's how custom operators work here).
- `x := ...` defines a rule. `f(a) if { ... }` defines a rule that only holds
  when every line in the body holds — lines are implicitly ANDed.
- A rule that doesn't hold is **undefined**, not false. `default f(_) := false`
  turns undefined back into `false`, which is what makes a check reportable.
- `input` is the document being evaluated. `data` is everything loaded from
  files — so a library in `package kosli.evidence` is reachable as
  `data.kosli.evidence`.
- `[x | some y in ys; ...]` is a comprehension: build an array of `x` for each
  `y` satisfying the body. `every`/`some` quantify over collections.
- `object.get(doc, ["a", "b"], default)` walks a path and falls back to
  `default` instead of going undefined.

</details>

---

## Vocabulary

| Term | What it means |
| --- | --- |
| **Subject** | A single thing being judged: one pull request, one artifact, one deployment. Subjects come from the input document. |
| **Requirement** | A group of subjects of the same kind, plus the checks that apply to them, plus how many must pass. This is the unit you declare; a policy declares one or more, each under its own name. |
| **Check** | One named thing asserted about a subject — `commits_signed`, `approved`, `protected_branch`. The definition is data: which field to read, which operator to apply, with what parameters. |
| **Operator** (`op`) | The comparison a check performs — `equals`, `range`, `all`, … The library ships a fixed vocabulary; anything beyond it is a custom op. |
| **Scope filter** (`applies_to`) | Checks that decide which raw subjects a requirement *applies to*. A PR that isn't merged isn't in breach of a code-review control — it's simply not a subject of it. |
| **`require`** | Whether `every` in-scope subject must pass all checks, or `some` single subject must pass all of them on its own. |
| **Result row** | One piece of evidence: this check, against this subject, read these inputs, and passed or didn't. |
| **Report** | The whole output: an overall `compliant` verdict, a per-requirement summary with the check definitions, and every result row. |
| **Violation** | A failing row that actually represents a **breach**. Not every failing row is one — see [Evidence vs. violations](#evidence-vs-violations). |
| **Fail-closed** | Missing, null, or wrong-typed input makes a check **fail**, never vanish and never accidentally pass. See [Fail-closed rules](#fail-closed-rules). |

The mental model: a report is a **table of evidence** — one row per (subject,
check) pair — alongside a **definition table** saying what each check means.
The `compliant` boolean is just the roll-up.

## Your first policy

Two files in a scratch directory. First an input document, `deployments.json` —
three deployments, one of them not in production, one of them with no approver:

```json
{
  "deployments": [
    {"id": "d-1", "environment": "prod", "approved_by": "bob"},
    {"id": "d-2", "environment": "prod"},
    {"id": "d-3", "environment": "staging"}
  ]
}
```

Then the policy, `prod_deploy.rego`. Read it as one sentence: *every production
deployment must have a named approver.*

```rego
package tutorial

import data.kosli.evidence
import rego.v1

requirements := {"prod_deploy": {          # the requirement's name; rows link back to it
	"subject_type": "deployment",          # what kind of thing a subject is
	"from": ["deployments"],               # where the subjects live in the input
	"id": ["id"],                          # how to identify one subject
	"applies_to": {"is_prod": {"op": "equals", "path": ["environment"], "value": "prod"}},
	"checks": {"approved": {
		"description": "A named approver signed off on the deployment",
		"op": "non_empty_string",
		"path": ["approved_by"],
	}},
}}

report := evidence.report(input, requirements)
```

Run it:

```sh
opa eval -d path/to/src/library.rego -d prod_deploy.rego \
  -i deployments.json --format=pretty 'data.tutorial.report'
```

Note what you did *not* write: no loop over deployments, no `allow` rule, no
violation strings, no handling of the missing `approved_by`.

Note also the two path keywords. **`from`** locates a collection in the *input
document*; a check's **`path`** locates a field within *one subject*.

### The report

The output has three parts:

```jsonc
{
  "compliant": false,      // the roll-up verdict
  "requirements": { ... }, // what each check means, and each requirement's own verdict
  "results": [ ... ]       // the evidence: one row per (subject, check) pair
}
```

**`requirements`** is the definition table. Each check appears here once,
however many subjects it ran against:

```json
{
  "prod_deploy": {
    "require": "every",
    "satisfied": false,
    "subjects": {"total": 3, "matching": 2},
    "checks": {
      "approved": {
        "description": "A named approver signed off on the deployment",
        "expression": "approved_by is a non-empty string",
        "op": "non_empty_string",
        "path": ["approved_by"]
      },
      "$applies": {"description": "...", "expression": "environment == prod"},
      "$min_subjects": {"description": "...", "expression": "count(matching(deployments)) >= 1"},
      "$well_formed": {"description": "...", "expression": "count(checks) >= 1 and require in {every, some}"}
    }
  }
}
```

`subjects: {total: 3, matching: 2}` — three deployments in the input, two in
scope after the filter — and `satisfied: false`, because one of those two has no
approver.

`expression` is rendered by the library from the check spec, so you get a
human-readable form of each check for free. You only write it yourself for
custom ops.

**`results`** is the evidence. Every row has the same five fields:

```json
{
  "requirement": "prod_deploy",
  "subject": {"type": "deployment", "id": "d-2"},
  "check": "approved",
  "inputs": [{"name": "approved_by", "value": null}],
  "passed": false
}
```

A passing row and a failing row carry exactly those same fields, so a consumer
never has to handle two shapes. There is no separate list of failures — you find
them by filtering `results` on `passed == false`.

### Reading the rows

This run produces seven rows. Here they all are, condensed to one line each —
the JSON row above is the last of them. Row order is deterministic and runs from
the most general question to the most specific.

| requirement | subject.id | check | inputs | passed |
| --- | --- | --- | --- | --- |
| prod_deploy | `null` *(requirement-level)* | `$well_formed` | `count(checks) = 1`, `require = "every"` | ✅ |
| prod_deploy | `null` *(requirement-level)* | `$min_subjects` | `count(matching(deployments)) = 2` | ✅ |
| prod_deploy | `"d-1"` | `$applies` | `environment = "prod"` | ✅ |
| prod_deploy | `"d-2"` | `$applies` | `environment = "prod"` | ✅ |
| prod_deploy | `"d-3"` | `$applies` | `environment = "staging"` | ❌ |
| prod_deploy | `"d-1"` | `approved` | `approved_by = "bob"` | ✅ |
| prod_deploy | `"d-2"` | `approved` | `approved_by = null` | ❌ |

Three things to take from that table:

1. **Every row carries the value it read.** The last row doesn't just say
   "failed" — it says `approved_by` was `null`, so the verdict can be
   recomputed from the row.
2. **The failure produced a row at all.** In plain Rego an undefined check
   leaves no trace. Here `d-2` is named.
3. **Three checks you didn't declare showed up**, prefixed with `$`. The library
   synthesises them, and `$` guarantees they can never collide with your own
   check names:
   - **`$well_formed`** — one row per requirement: does this requirement assert
     anything satisfiable at all. It passes for any sane policy; it exists so
     that a requirement which declares no checks, or an unrecognised `require`,
     is denied out loud instead of silently.
   - **`$min_subjects`** — one row per requirement: were there enough in-scope
     subjects. A typo in `from` finds nothing and fails here, rather than a
     requirement with zero subjects quietly passing.
   - **`$applies`** — one row per *raw* subject, for requirements with an
     `applies_to`: was this subject in scope. `d-3` is out of scope and named in
     the evidence saying so. It gets no check rows — it was never evaluated.

### Evidence vs. violations

The report is deliberately a **superset**. It records every check that ran —
passing and failing, in scope and out — because evidence that exonerates matters
as much as evidence that convicts. Not every failing row is a breach:

| Failing row | `subject.id` | What it means | A violation? |
| --- | --- | --- | --- |
| one of your own checks (`approved`) | the subject that failed | this subject breached this check | **yes** |
| `$applies` | the subject that didn't qualify | out of scope, never evaluated | **no** |
| `$min_subjects` | `null` — the row is about the requirement, not a subject | too few in-scope subjects existed | **yes** |
| `$well_formed` | `null` — likewise | the requirement itself is malformed | **yes** (a bug in the policy, not in the thing being judged) |

Narrowing the report to the actionable subset is `evidence.violations`:

```rego
violations := evidence.violations(report)
```

It is a pure function of the report and drops three kinds of row, each of which
stays in the report as evidence:

| dropped | because |
| --- | --- |
| passing rows | nothing to answer for |
| rows of a **satisfied** requirement | under `"require": "some"`, another subject met every check, so these are exculpatory |
| `$applies` rows | out of scope is not in breach |

`$min_subjects` rows are deliberately **kept** — "no production deployment at
all" is exactly the breach that guard exists to report.

Each entry is the row joined to its check definition, so a caller doesn't have
to do that lookup:

```json
{
  "requirement": "prod_deploy",
  "subject": {"type": "deployment", "id": "d-2"},
  "check": "approved",
  "description": "A named approver signed off on the deployment",
  "expression": "approved_by is a non-empty string",
  "inputs": [{"name": "approved_by", "value": null}]
}
```

**Selection is generic; wording is yours.** The library returns structured
entries and never a formatted string, because the message is the part that
really is policy-specific:

```rego
violations contains msg if {
	some v in evidence.violations(report)
	msg := sprintf("%s: %s — %s", [subject_label(v), v.check, v.description])
}

# $min_subjects and $well_formed are about the requirement rather than any one
# subject, so their subject.id is null.
subject_label(v) := sprintf("%s '%v'", [v.subject.type, v.subject.id]) if {
	v.subject.id != null
}

subject_label(v) := sprintf("%s (requirement-level)", [v.subject.type]) if {
	v.subject.id == null
}
```

→ `["deployment 'd-2': approved — A named approver signed off on the deployment"]`

That's what `examples/code_review.rego` does.

Gate on `compliant`, not on violations — `violations` is the explanation, not
the verdict. (An unsatisfied requirement always produces at least one failing
row, so violations is never empty while `compliant` is `false`.)

From outside Rego, the same projection over the report JSON:

```sh
opa eval -d path/to/src/library.rego -d prod_deploy.rego -i deployments.json \
  --format=pretty 'data.tutorial.report' \
  | jq -r '.results[] | select(.passed == false)
           | "\(.subject.type) \(.subject.id // "(requirement-level)"): \(.check) — inputs: \(.inputs | map("\(.name)=\(.value|tojson)") | join(", "))"'
```

```
deployment d-3: $applies — inputs: environment="staging"
deployment d-2: approved — inputs: approved_by=null
```

### Checking a list inside a subject

Real checks often reach into a collection *within* a subject: every commit in
the PR, every CI check on the deployment. That's the `all` operator (and `any`
for at-least-one), which applies a nested check across each element:

```rego
"checks_green": {
	"description": "Every CI check on the deployment passed",
	"op": "all",
	"path": ["checks"],
	"check": {"op": "equals", "path": ["conclusion"], "value": "success"},
}
```

Rendered expression: `every checks: conclusion == success`. The row echoes the
whole projection:

```json
{
  "requirement": "prod_deploy", "subject": {"type": "deployment", "id": "d-1"},
  "check": "checks_green",
  "inputs": [{"name": "checks[].conclusion", "value": ["success", "failure"]}],
  "passed": false
}
```

Against a deployment whose `checks` array is *empty*, it fails, with
`"value": []`. "Every check passed" over a subject with no recorded checks is
absence of evidence, not evidence of compliance.

### Requiring one subject to pass everything

`require` defaults to `every`: all in-scope subjects must pass all checks. Set
`"require": "some"` and the requirement is satisfied when **one** subject passes
**all** checks on its own.

That distinction is the point of the real code-review control. "One merged PR
was on the protected branch, and one merged PR had signed commits, and one
merged PR was peer-approved" must not add up to compliance if those were three
different PRs. `some` forbids splitting the checks across subjects — see
`examples/trail_split.json`, which is built to fail exactly that way.

With `some`, failed rows for the *other* subjects stay in the report. They're
evidence, not violations, and `evidence.violations` drops them.

### Next step

Read `examples/code_review.rego`. It's Kosli's SDLC-CTRL-0007 code review
control expressed as two requirements — an artifact and a merged PR — and it
uses every concept above plus one custom op, in roughly 100 lines.

---

## Reference

### Policy

A policy is an object mapping requirement names to requirements:

```rego
requirements := {
    "artifact":  { ... },
    "merged_pr": { ... },
}

report := evidence.report(input, requirements)
```

The name is the **object key**, not a field inside the requirement, which makes
names unique by construction: a row's `(requirement, check)` pair always
resolves to exactly one definition. A policy declaring **no requirements**
asserts nothing and is never compliant.

### Requirement

```rego
{
    "subject_type": "pull_request", # subject type label (default: "subject")
    "from": [...],                  # collection location in input (array or single object)
    "id": [...],                    # identity path within a subject
    "require": "every"|"some",      # every subject must pass / some subject must pass ALL checks
    "applies_to": {name: check},    # scope filter: only matching subjects are evaluated
    "min_subjects": 1,              # matching subjects required (default 1)
    "checks": {name: check},
}
```

- **`from`** resolves to an array (each element is a subject) or to a single
  object (one subject). Anything else — missing, a string, a number — yields
  zero subjects, which fails `$min_subjects`.
- **`id`** is a path *within* a subject. If it doesn't resolve, `subject.id` is
  `null`; the row still exists.
- **`applies_to`** entries use the same check vocabulary as `checks`,
  collection ops included. All of them must pass for a subject to be in scope.
- **`min_subjects`** defaults to 1, so a typo in `from` fails the requirement
  instead of vacuously satisfying it. Set it to `0` to opt back into a vacuous
  pass — "if there are any, the rule applies; if there are none, that's fine".
  It means the same under both `require` modes.
- A requirement that declares **no checks**, or an unrecognised `require`,
  asserts nothing satisfiable and is never satisfied. `$well_formed` reports it.

### Operators

A check names one operator and its parameters. Every `path` is relative to the
subject.

**Leaf operators** work on a single subject (or, inside `all`/`any`, on a
single element):

| `op` | Parameters | Passes when |
| --- | --- | --- |
| `equals` | `path`, `value` | field equals `value`. Absent ≠ `null`: only an explicitly-null field satisfies `"value": null` |
| `present` | `path` | field is present and not `null` |
| `non_empty_string` | `path` | field is a string and not `""` |
| `range` | `path`, `min`, `max` | field is a number, inclusive of both bounds |
| `includes` | `path`, `value` | field is an array containing `value` |
| `excludes` | `path`, `value` | field is an array not containing `value` |
| `compare` | `left`, `right`, `cmp` | both fields present, same type, and `left cmp right` holds |
| `compare_time` | `left`, `right`, `cmp` | both fields are RFC3339 timestamps and compare that way |

`cmp` is one of `eq`, `ne`, `gt`, `gte`, `lt`, `lte`.

`compare` compares **two fields of the same subject** — both `left` and `right`
are paths, not constants. To bound a field against a literal, use `range`.

**Collection operators** apply a nested check across a nested array, one nesting
level deep (Rego forbids recursion):

| `op` | Parameters | Passes when |
| --- | --- | --- |
| `all` | `path`, `check` | `path` is a non-empty array and *every* element passes the nested `check` |
| `any` | `path`, `check` | `path` is a non-empty array and *some* element passes the nested `check` |

**Custom ops** cover anything the vocabulary can't express. You contribute an
`op_passed(check, subject)` rule body into the `kosli.evidence` package from
your own file — see `examples/code_review_ops.rego` — and it flows through the
same report machinery. Two things the library can't derive, so declare them on
the check:

- **`expression`** — the human-readable form.
- **`inputs`** — every input the op reads, so a row can still carry everything
  needed to recompute its verdict. An entry is either a path (`["author"]`) or
  a projection across a collection (`{"path": ["commits"], "each":
  ["timestamp"]}` → `commits[].timestamp`).

A custom op is a normal Rego rule, so it's on you to keep it fail-closed. The
comments in `examples/code_review_ops.rego` walk through the three ways
`peer_approved` could have failed open.

### Fail-closed rules

Every operator fails on a missing, null or wrong-typed field rather than
vanishing or passing by accident. Three cases are worth spelling out, because
Rego's defaults point the other way:

- `compare`/`compare_time` require both sides to be present and of the same
  type. Rego's `<` is total across types — `null < 5` is *true* — so an
  unguarded `lt` against a missing field would report success.
- `all`/`any` require a non-empty array.
- `min_subjects` defaults to 1, so a typo in `from` fails the requirement
  instead of vacuously satisfying it. A policy with no requirements at all is
  never compliant, and neither is a requirement that declares no checks.

`equals` distinguishes a field that is absent from one explicitly set to `null`:
only the latter satisfies `"value": null`.

And a denial is never silent: an unsatisfied requirement always produces at
least one failing row.

### Report shape

`evidence.report(input, requirements)` returns `{compliant, requirements,
results}` — see [The report](#the-report) for a worked example.

Check **definitions** — raw spec, description, and rendered `expression` — live
once per `(requirement, check)` pair under `requirements[<name>].checks`. Rows
in `results` carry only what differs per subject:
`{requirement, subject, check, inputs, passed}`. A row's `(requirement, check)`
is a reference into `requirements[<requirement>].checks[<check>]`. Look a check
up by that pair, not by name alone — two requirements may reuse a name for
unrelated checks.

Row order is deterministic and independent of how the policy object was written.
Rows are grouped by kind of check, from the most general question to the most
specific — every requirement's `$well_formed` row, then every `$min_subjects`
row, then all `$applies` rows, then all check rows. Within a group, requirements
come in name order; within one requirement's rows, subjects come in the order
the input listed them, and a subject's check rows in check-name order. Two
consumers building the same policy with its keys in a different order produce
byte-identical reports, which is what makes the report safe to hash and attest.

This makes the report:

- **total** — every declared check produces a row, including on malformed or
  missing input, so "failed because temp_c was missing" is a row, not a gap;
- **not redundant per-row** — a check run against many subjects doesn't repeat
  its description and expression on every row;
- **self-contained** — a consumer can interpret every row without re-parsing the
  `.rego` source.

### Violations

`evidence.violations(report)` returns the report's actionable subset as an
array, each entry being a failing row joined to its check definition:

```rego
[
  {
    "requirement": "merged_pr",
    "subject": {"type": "pull_request", "id": "https://github.com/.../pull/42"},
    "check": "commits_signed",
    "description": "Every commit in the pull request is signed ...",
    "expression": "every commits: verified == true",
    "inputs": [{"name": "commits[].verified", "value": [true, false]}]
  }
]
```

- A **pure function of the report** — no input document, no policy.
- Drops passing rows, rows of a **satisfied** requirement, and `$applies` rows.
  Keeps `$min_subjects` and `$well_formed` failures. See
  [Evidence vs. violations](#evidence-vs-violations) for why each.
- `description` and `expression` fall back to `""` when the check didn't declare
  them; every other field comes from the row.
- An **array**, not a set: order follows `results`, and two distinct failures
  that would render to the same string are not collapsed.
- Returns **structured entries, never formatted strings**.

`allow := report.compliant` and `violations` are independent derivations — the
verdict never reads rows — so a bug in a violations projection can produce a
misleading message list but cannot let a non-compliant trail through. That is
also why the *report* is the hashable, attestable artifact and `violations`
isn't.

---

## Running it

```sh
opa eval -d src/library.rego -d examples/code_review.rego -d examples/code_review_ops.rego \
  -i examples/trail_compliant.json --format=pretty 'data.policy.output'

opa check --strict src examples
```

Swap `trail_compliant.json` for `trail_split.json` to see a failing case
(`allow: false`, populated `violations`).

## Tests

```sh
opa test src examples --ignore '*.json'
```

Changing the library itself? See [CONTRIBUTING.md](CONTRIBUTING.md) for what
each suite covers, the invariants they pin, and the test conventions.

## Repo layout

- **`src/`** — the library. `library.rego` (`package kosli.evidence`) is the
  generic engine; nothing in here is specific to any one policy.
  `library_test.rego` is its test suite.
- **`examples/`** — a worked example of consuming the library.
  `code_review.rego` expresses Kosli's SDLC-CTRL-0007 code review control as a
  `kosli.evidence` policy; `code_review_ops.rego` supplies the one custom op
  (`peer_approved`) that exceeds the operator vocabulary, contributed into the
  `kosli.evidence` package from the policy side; `trail_compliant.json` and
  `trail_split.json` are input documents to evaluate it against;
  `code_review_test.rego` tests the policy and its custom op.

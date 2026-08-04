# kosli.evidence

A Rego library that turns policy evaluation into a structured, hashable
**evidence report**, instead of a bare `allow`/`deny` plus hand-written
violation strings.

Writing a policy with this library means *declaring what to check, as data*.
You don't write evaluation logic or reporting logic — you describe the things
being checked and the checks that apply to them, and the library produces a
uniform report: which checks ran, against which things, what values they read,
and what each one concluded.

**New here?** Read [Why this exists](#why-this-exists) and
[Vocabulary](#vocabulary), then follow [Your first policy](#your-first-policy)
with a terminal open. The [Reference](#reference) is for looking things up
afterwards. If you've never touched Rego, the
[Rego in sixty seconds](#rego-in-sixty-seconds) box is enough to get through
the walkthrough.

---

## Why this exists

Kosli policies (e.g. SDLC-CTRL-0007, code review) are currently hand-written
Rego that computes `allow` and a `violations` set directly. That works, but
every policy re-invents its own evaluation and reporting logic, and Rego works
against you in two specific ways:

- **Booleans are undefined on failure, not `false`.** In Rego, a rule that
  doesn't hold doesn't evaluate to `false` — it simply vanishes from the
  output. So the natural way to write a check gives you evidence when it
  passes and *silence* when it fails, which is backwards for an audit trail.
  "This check ran and failed because X" has to be constructed deliberately.
- **Rego has no notion of "which inputs did this rule read."** If you want the
  read values in the evidence — and you do, or the verdict can't be
  recomputed or contested — you have to declare them by hand.

So the goal is one generic library that policies call into. The output is a
uniform report — the same shape regardless of which policy produced it — that
can be hashed and attested alongside the policy itself, and consumed by other
tooling without parsing Rego.

The practical difference: with a hand-written policy, a failure gives you a
string someone wrote. With this library, a failure gives you a row naming the
thing that failed, the named check that failed, and the input values it read.

### Rego in sixty seconds

Enough to read the code in this repo:

- Rego is the policy language of [OPA](https://www.openpolicyagent.org/).
  Files declare a `package`; everything in a package is merged, so two files
  can contribute rules to the same package (that's how custom operators work
  here).
- `x := ...` defines a rule. `f(a) if { ... }` defines a rule that only holds
  when every line in the body holds — lines are implicitly ANDed.
- A rule that doesn't hold is **undefined**, not false. `default f(_) := false`
  turns undefined back into `false`, which is what makes a check reportable.
- `input` is the document being evaluated (here, a Kosli trail). `data` is
  everything loaded from files — so a library in `package kosli.evidence` is
  reachable as `data.kosli.evidence`.
- `[x | some y in ys; ...]` is a comprehension: build an array of `x` for each
  `y` satisfying the body. `every`/`some` quantify over collections.
- `object.get(doc, ["a", "b"], default)` walks a path and falls back to
  `default` instead of going undefined. The library uses it everywhere; that
  is what keeps the report total.

## Vocabulary

These are the words used throughout the library, the report, and the rest of
this README. They are worth learning in this order.

| Term | What it means |
| --- | --- |
| **Subject** | A single thing being judged: one pull request, one artifact, one deployment. Subjects come from the input document. |
| **Subject set** | A group of subjects of the same kind, plus the checks that apply to them, plus how many must pass. This is the unit you declare. A policy is a list of subject sets. |
| **Predicate** | The *name* of one check: `commits_signed`, `approved`, `protected_branch`. It's what a row of evidence points at. |
| **Clause** | The *definition* of that check, as data: which field to read, which operator to apply, with what parameters. Predicate = name, clause = spec. `"clauses": {"approved": {...}}` declares the predicate `approved` with that clause. |
| **Operator** (`op`) | The comparison a clause performs — `equals`, `range`, `all`, … The library ships a fixed vocabulary; anything beyond it is a custom op. |
| **Filter** (`where`) | Clauses that decide which raw subjects are *in scope*. A PR that isn't merged isn't in breach of a code-review control — it's simply not a subject of it. |
| **Quantifier** | Whether `every` in-scope subject must pass all clauses, or `some` single subject must pass all of them on its own. |
| **Result row** | One piece of evidence: this predicate, against this subject, read these inputs, and passed or didn't. |
| **Report** | The whole output: an overall `compliant` verdict, a per-set summary with the clause definitions, and every result row. |
| **Fail-closed** | Missing, null, or wrong-typed input makes a check **fail**, never vanish and never accidentally pass. See [Fail-closed rules](#fail-closed-rules). |

The mental model: a report is a **table of evidence** — one row per (subject,
predicate) pair — alongside a **definition table** saying what each predicate
means. The `compliant` boolean is just the roll-up.

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

sets := [{
	"name": "prod_deploy",                 # names this set; rows link back to it
	"type": "deployment",                  # what kind of thing a subject is
	"path": ["deployments"],               # where the subjects live in the input
	"id": ["id"],                          # how to identify one subject
	"where": {"is_prod": {"op": "equals", "path": ["environment"], "value": "prod"}},
	"clauses": {"approved": {
		"description": "A named approver signed off on the deployment",
		"op": "non_empty_string",
		"path": ["approved_by"],
	}},
}]

report := evidence.report(input, sets)
```

Run it:

```sh
opa eval -d path/to/src/library.rego -d prod_deploy.rego \
  -i deployments.json --format=pretty 'data.tutorial.report'
```

Note what you did *not* write: no loop over deployments, no `allow` rule, no
violation strings, no handling of the missing `approved_by`. You declared one
set and one clause.

### Reading the report

The verdict:

```json
"compliant": false
```

The per-set summary — three deployments in the input, two of them in scope
after the filter, and the set is not satisfied because one of those two has no
approver:

```json
"sets": [
  {
    "name": "prod_deploy",
    "quantifier": "every",
    "satisfied": false,
    "subjects": {"total": 3, "matching": 2},
    "clauses": {
      "approved": {
        "description": "A named approver signed off on the deployment",
        "op": "non_empty_string",
        "path": ["approved_by"],
        "expression": "approved_by is a non-empty string"
      },
      "$min_count": {
        "description": "at least 1 matching deployment subject(s) required",
        "expression": "count(matching(deployments)) >= 1"
      },
      "$matches_filter": {
        "description": "subject qualifies as a deployment under this set's filter; non-matching subjects are recorded but not evaluated",
        "expression": "environment == prod"
      }
    }
  }
]
```

`expression` is rendered by the library from the clause spec — you get a
human-readable form of the check for free. You only write `expression` yourself
for custom ops, where the library can't derive it.

And the evidence itself, six rows for one clause and three deployments:

| set | subject | predicate | inputs | passed |
| --- | --- | --- | --- | --- |
| prod_deploy | *(set-level, `id: null`)* | `$min_count` | `count(matching(deployments)) = 2` | ✅ |
| prod_deploy | d-1 | `$matches_filter` | `environment = "prod"` | ✅ |
| prod_deploy | d-2 | `$matches_filter` | `environment = "prod"` | ✅ |
| prod_deploy | d-3 | `$matches_filter` | `environment = "staging"` | ❌ |
| prod_deploy | d-1 | `approved` | `approved_by = "bob"` | ✅ |
| prod_deploy | d-2 | `approved` | `approved_by = null` | ❌ |

Three things to take from that table:

1. **Every row carries the value it read.** Row 6 doesn't just say "failed" —
   it says `approved_by` was `null`. The verdict can be recomputed from the
   row.
2. **The failure produced a row at all.** This is the thing plain Rego makes
   hard: an undefined check leaves no trace. Here `d-2` is named.
3. **Two predicates you didn't declare showed up**, prefixed with `$`. The
   library synthesises those, and `$` guarantees they can never collide with
   your own clause names:
   - **`$min_count`** — one row per set: were there enough in-scope subjects.
     A typo in `path` finds nothing and fails here, rather than a set with zero
     subjects quietly passing.
   - **`$matches_filter`** — one row per *raw* subject, for sets with a
     `where`: did this subject qualify. `d-3` is out of scope, and it's named
     in the evidence saying so, instead of surviving only as the `total: 3` /
     `matching: 2` discrepancy. It gets no clause rows — it was never
     evaluated.

That last point matters when you project violations: **`$matches_filter`
failures are not violations.** Being out of scope isn't a breach. `$min_count`
failures *are* — "no production deployment at all" is exactly what that guard
exists to report. See `violations` in `examples/code_review.rego`.

### Checking a list inside a subject

Real checks often reach into a collection *within* a subject: every commit in
the PR, every CI check on the deployment. That's the `all` operator (and `any`
for at-least-one), which applies a nested leaf clause across each element:

```rego
"checks_green": {
	"description": "Every CI check on the deployment passed",
	"op": "all",
	"path": ["checks"],
	"clause": {"op": "equals", "path": ["conclusion"], "value": "success"},
}
```

Rendered expression: `every checks: conclusion == success`. Against a
deployment with a mixed pair of checks, the row echoes the whole projection —

```json
{
  "set": "prod_deploy", "subject": {"type": "deployment", "id": "d-1"},
  "predicate": "checks_green",
  "inputs": [{"name": "checks[].conclusion", "value": ["success", "failure"]}],
  "passed": false
}
```

— and against a deployment whose `checks` array is *empty*, it fails, with
`"value": []`. "Every check passed" over a subject with no recorded checks is
absence of evidence, not evidence of compliance. That is the fail-closed
principle showing up where it surprises people most.

### Requiring one subject to pass everything

The default quantifier is `every`: all in-scope subjects must pass all clauses.
Add `"quantifier": "some"` and the set is satisfied when **one** subject passes
**all** clauses on its own.

That distinction is the whole point of the real code-review control. "One
merged PR was on the protected branch, and one merged PR had signed commits,
and one merged PR was peer-approved" must not add up to compliance if those
were three different PRs. `some` forbids splitting the requirements across
subjects — see `examples/trail_split.json`, which is built to fail exactly that
way.

Note that with `some`, failed rows for the *other* subjects are still in the
report. They're evidence, not violations: another subject met every
requirement. `examples/code_review.rego` handles this by only projecting
violations from sets that aren't satisfied.

### Next step

Read `examples/code_review.rego`. It's Kosli's real SDLC-CTRL-0007 code review
control expressed as two subject sets — an artifact and a merged PR — and it
uses every concept above plus one custom op. It's roughly 100 lines, and a good
share of them are descriptions and comments.

---

## Reference

### Subject set

```rego
{
    "name": "merged_pr",          # row linkage + set verdict key (default: type)
    "type": "pull_request",       # subject type label
    "path": [...],                # collection location in input (array or single object)
    "id": [...],                  # identity path within a subject
    "quantifier": "every"|"some", # every subject must pass / some subject must pass ALL clauses
    "where": {name: clause},      # filter: only subjects passing these become subjects
    "min_count": 1,               # matching subjects required (default 1)
    "clauses": {name: clause},
}
```

- **`path`** resolves to an array (each element is a subject) or to a single
  object (one subject). Anything else — missing, a string, a number — yields
  zero subjects, which fails `$min_count`.
- **`id`** is a path *within* a subject. If it doesn't resolve, `subject.id` is
  `null`; the row still exists.
- **`where`** clauses use the same clause vocabulary as `clauses`, collection
  ops included. All of them must pass for a subject to be in scope.
- **`min_count`** defaults to 1, so a typo in `path` fails the set instead of
  vacuously satisfying it. Set it to `0` to opt back into a vacuous pass.
- A set that declares **no clauses** is never satisfied — it asserts nothing.
  Neither is a report with **no sets**.

### Operators

A clause names one operator and its parameters. Every `path` is relative to
the subject.

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

`compare` compares **two fields of the same subject** — both `left` and
`right` are paths, not constants. To bound a field against a literal, use
`range`.

**Collection operators** apply a leaf clause across a nested array, one
nesting level deep (Rego forbids recursion):

| `op` | Parameters | Passes when |
| --- | --- | --- |
| `all` | `path`, `clause` | `path` is a non-empty array and *every* element passes `clause` |
| `any` | `path`, `clause` | `path` is a non-empty array and *some* element passes `clause` |

**Custom ops** cover anything the vocabulary can't express. You contribute an
`op_passed(clause, subject)` rule body into the `kosli.evidence` package from
your own file — see `examples/code_review_ops.rego` — and it flows through the
same report machinery. Two things the library can't derive for you, so declare
them on the clause:

- **`expression`** — the human-readable form.
- **`echo`** — every input the op reads, so a row can still carry everything
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
- `all`/`any` require a non-empty array. "Every commit is signed" over a
  subject with no recorded commits is absence of evidence, not evidence of
  compliance.
- `min_count` defaults to 1, so a typo in `path` fails the set instead of
  vacuously satisfying it. Set it to `0` to opt back into a vacuous pass; a
  report with no sets at all is never compliant, and neither is a set that
  declares no clauses.

`equals` distinguishes a field that is absent from one explicitly set to
`null`: only the latter satisfies `"value": null`.

### Report shape

`evidence.report(input, sets)` returns:

```json
{
  "compliant": true,
  "sets": [
    {
      "name": "merged_pr",
      "quantifier": "some",
      "satisfied": true,
      "subjects": {"total": 2, "matching": 1},
      "clauses": {
        "commits_signed": {
          "op": "all", "path": ["commits"], "clause": {...},
          "description": "Every commit ... signed ...",
          "expression": "every commits: verified == true"
        },
        "$min_count": {
          "description": "at least 1 matching pull_request subject(s) required",
          "expression": "count(matching(trail...pull_requests)) >= 1"
        },
        "$matches_filter": {
          "description": "subject qualifies as a pull_request under this set's filter; ...",
          "expression": "state == MERGED"
        }
      }
    }
  ],
  "results": [
    {
      "set": "merged_pr",
      "subject": {"type": "pull_request", "id": "https://github.com/.../pull/42"},
      "predicate": "commits_signed",
      "inputs": [{"name": "commits[].verified", "value": [true, true]}],
      "passed": true
    },
    {
      "set": "merged_pr",
      "subject": {"type": "pull_request", "id": "https://github.com/.../pull/44"},
      "predicate": "$matches_filter",
      "inputs": [{"name": "state", "value": "CLOSED"}],
      "passed": false
    }
  ]
}
```

The clause **definition** — its raw spec, description, and rendered
`expression` string — is declared once per `(set, predicate)` pair, in
`sets[].clauses`. Rows in `results` carry only what's actually different per
subject: `{set, subject, predicate, inputs, passed}`. A row's
`(set, predicate)` is a reference into `sets[<set>].clauses[<predicate>]` — it
is not safe to look a clause up by predicate name alone, since two different
sets may reuse the same name for unrelated clauses. That lookup always
resolves to exactly one definition: two sets declaring the same `name` would
break it, so the second one is suffixed with its position (`merged_pr`,
`merged_pr#1`).

This makes the report:

- **total** — every declared predicate produces a row, including on malformed
  or missing input (`object.get` with defaults throughout), so "failed because
  temp_c was missing" is still a row, not a silent gap;
- **not redundant per-row** — a policy checking the same clause against many
  subjects (many commits, many PRs) doesn't repeat that clause's
  description/expression on every one of those rows;
- **self-contained** — a downstream consumer can interpret every row without
  re-parsing the `.rego` source, by looking up its `(set, predicate)` in
  `sets[].clauses`.

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
opa test src examples --ignore '*.json'   # everything
opa test src --verbose                    # library only
```

The `--ignore` is required: `examples/*.json` are `opa eval` fixtures and both
define `data.trail`, so loading them together is a merge error. The test files
build their fixtures inline instead.

- **`src/library_test.rego`** — the engine: subject resolution, `where`
  filters, every leaf and collection operator (including what each one does
  with missing, null, and wrong-typed input), echoed inputs, rendered
  expressions, row shape and totality, `min_count`, both quantifiers, and the
  report-level invariants (determinism, and every row resolving to exactly one
  clause definition).
- **`examples/code_review_test.rego`** — the consumer policy: both README
  scenarios, the violation projection, the `peer_approved` custom op, and
  `data.params` configurability.

Worth running the fail-closed claims under strict builtin errors too, since
`opa test` has no flag for it:

```sh
opa eval --strict-builtin-errors -d src/library.rego -d examples/code_review.rego \
  -d examples/code_review_ops.rego -i examples/trail_split.json 'data.policy.output'
```

A `todo_test_` prefix marks a known-open issue: `opa test` skips the rule, so
the suite stays green while the assertion states the behaviour we want, and
closing the issue is the change that renames it to `test_`. Nothing is skipped
at the moment.

The `regressions` section at the end of each file covers the fail-open and
evidence-integrity bugs the library shipped with — `compare` passing on a
missing field, `peer_approved` ignoring commits with no timestamp, a vacuous
pass over an empty collection, a `$min_count` row labelling a count it wasn't
reporting, `where`-excluded subjects leaving no trace, colliding set names and
predicate names. Those are the cases most worth not reintroducing.

One residual: `compare_time` screens its inputs with a shape regex before
parsing, so malformed timestamps produce a failing row even under
`--strict-builtin-errors`. A calendar-impossible date that is nonetheless
well-shaped (`2024-02-31T00:00:00Z`) still reaches `time.parse_rfc3339_ns`,
which means a builtin error — fatal under that flag, a failing row without it.

## Repo layout

- **`src/`** — the library itself. `library.rego` (`package kosli.evidence`)
  is the generic engine; nothing in here is specific to any one policy.
  `library_test.rego` is its test suite.
- **`examples/`** — a worked example of consuming the library:
  `code_review.rego` expresses Kosli's real SDLC-CTRL-0007 code review control
  as `kosli.evidence` subject sets; `code_review_ops.rego` supplies the one
  custom op (`peer_approved`) that exceeds the operator vocabulary, contributed
  into the `kosli.evidence` package from the policy side, the same way a real
  customer would; `trail_compliant.json` and `trail_split.json` are input
  documents to evaluate it against; `code_review_test.rego` tests the policy
  and its custom op.

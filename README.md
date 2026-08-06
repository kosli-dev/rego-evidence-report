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
| **Requirement** | A group of subjects of the same kind, plus the checks that apply to them, plus how many must pass. This is the unit you declare; a policy declares one or more, each under its own name. |
| **Check** | One named thing asserted about a subject — `commits_signed`, `approved`, `protected_branch`. The name is what a row of evidence points at; the definition is data: which field to read, which operator to apply, with what parameters. `"checks": {"approved": {...}}` declares a check named `approved`. |
| **Operator** (`op`) | The comparison a check performs — `equals`, `range`, `all`, … The library ships a fixed vocabulary; anything beyond it is a custom op. |
| **Scope filter** (`applies_to`) | Checks that decide which raw subjects a requirement *applies to*. A PR that isn't merged isn't in breach of a code-review control — it's simply not a subject of it. |
| **`require`** | Whether `every` in-scope subject must pass all checks, or `some` single subject must pass all of them on its own. |
| **Result row** | One piece of evidence: this check, against this subject, read these inputs, and passed or didn't. |
| **Report** | The whole output: an overall `compliant` verdict, a per-requirement summary with the check definitions, and every result row. |
| **Violation** | A failing row that actually represents a **breach**. Not every failing row is one — see [Evidence vs. violations](#evidence-vs-violations). The report holds evidence; violations are an *interpretation* of it. |
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
violation strings, no handling of the missing `approved_by`. You declared one
requirement and one check.

Note also the two different path keywords. **`from`** locates a collection in
the *input document*; a check's **`path`** locates a field within *one subject*.
Two different roots, so two different words.

### The report, in full

This is the entire output of that command, verbatim — nothing elided, so you
can read the shape without running anything. Key order is `opa eval`'s
(alphabetical). The only cosmetic difference: raw `opa` output writes the `>` of
`>=` as a unicode escape, shown here as a plain character.

```json
{
  "compliant": false,
  "requirements": {
    "prod_deploy": {
      "checks": {
        "$applies": {
          "description": "subject is in scope as a deployment under this requirement's applies_to filter; out-of-scope subjects are recorded but not evaluated",
          "expression": "environment == prod"
        },
        "$min_subjects": {
          "description": "at least 1 matching deployment subject(s) required",
          "expression": "count(matching(deployments)) >= 1"
        },
        "$well_formed": {
          "description": "the requirement declares at least one check and a recognised \"require\" value; lacking either, it asserts nothing that could ever be satisfied",
          "expression": "count(checks) >= 1 and require in {every, some}"
        },
        "approved": {
          "description": "A named approver signed off on the deployment",
          "expression": "approved_by is a non-empty string",
          "op": "non_empty_string",
          "path": [
            "approved_by"
          ]
        }
      },
      "require": "every",
      "satisfied": false,
      "subjects": {
        "matching": 2,
        "total": 3
      }
    }
  },
  "results": [
    {
      "check": "$well_formed",
      "inputs": [
        {
          "name": "count(checks)",
          "value": 1
        },
        {
          "name": "require",
          "value": "every"
        }
      ],
      "passed": true,
      "requirement": "prod_deploy",
      "subject": {
        "id": null,
        "type": "deployment"
      }
    },
    {
      "check": "$min_subjects",
      "inputs": [
        {
          "name": "count(matching(deployments))",
          "value": 2
        }
      ],
      "passed": true,
      "requirement": "prod_deploy",
      "subject": {
        "id": null,
        "type": "deployment"
      }
    },
    {
      "check": "$applies",
      "inputs": [
        {
          "name": "environment",
          "value": "prod"
        }
      ],
      "passed": true,
      "requirement": "prod_deploy",
      "subject": {
        "id": "d-1",
        "type": "deployment"
      }
    },
    {
      "check": "$applies",
      "inputs": [
        {
          "name": "environment",
          "value": "prod"
        }
      ],
      "passed": true,
      "requirement": "prod_deploy",
      "subject": {
        "id": "d-2",
        "type": "deployment"
      }
    },
    {
      "check": "$applies",
      "inputs": [
        {
          "name": "environment",
          "value": "staging"
        }
      ],
      "passed": false,
      "requirement": "prod_deploy",
      "subject": {
        "id": "d-3",
        "type": "deployment"
      }
    },
    {
      "check": "approved",
      "inputs": [
        {
          "name": "approved_by",
          "value": "bob"
        }
      ],
      "passed": true,
      "requirement": "prod_deploy",
      "subject": {
        "id": "d-1",
        "type": "deployment"
      }
    },
    {
      "check": "approved",
      "inputs": [
        {
          "name": "approved_by",
          "value": null
        }
      ],
      "passed": false,
      "requirement": "prod_deploy",
      "subject": {
        "id": "d-2",
        "type": "deployment"
      }
    }
  ]
}
```

Three parts: the `compliant` roll-up, the `results` rows (the evidence), and
the `requirements` summary (the definitions, plus each requirement's own
verdict). Note `subjects: {total: 3, matching: 2}` — three deployments in the
input, two in scope after the filter — and `satisfied: false`, because one of
those two has no approver.

`expression` is rendered by the library from the check spec — you get a
human-readable form of each check for free. You only write `expression`
yourself for custom ops, where the library can't derive it.

### Reading the rows

The same seven rows, condensed. Row order is deterministic, and runs from the
most general question to the most specific: `$well_formed`, then
`$min_subjects`, then `$applies`, then check rows.

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

1. **Every row carries the value it read.** Row 6 doesn't just say "failed" —
   it says `approved_by` was `null`. The verdict can be recomputed from the
   row.
2. **The failure produced a row at all.** This is the thing plain Rego makes
   hard: an undefined check leaves no trace. Here `d-2` is named.
3. **Three checks you didn't declare showed up**, prefixed with `$`. The library
   synthesises those, and `$` guarantees they can never collide with your own
   check names:
   - **`$well_formed`** — one row per requirement: does this requirement assert
     anything satisfiable at all. It is computed from the declaration alone, so
     it reads the same whatever the input contains. It passes for any sane
     policy; it exists so that a requirement which declares no checks, or an
     unrecognised `require`, is *denied out loud* instead of silently.
   - **`$min_subjects`** — one row per requirement: were there enough in-scope
     subjects. A typo in `from` finds nothing and fails here, rather than a
     requirement with zero subjects quietly passing.
   - **`$applies`** — one row per *raw* subject, for requirements with an
     `applies_to`: was this subject in scope. `d-3` is out of scope, and it's
     named in the evidence saying so, instead of surviving only as the
     `total: 3` / `matching: 2` discrepancy. It gets no check rows — it was
     never evaluated.

### Which subject failed?

Failing subjects are found by filtering `results` on `passed == false` and
reading `subject.id`. There is no separate list of failures in the report — the
rows *are* the list, and that's deliberate: a passing row and a failing row
carry exactly the same fields, so a consumer never has to handle two shapes.

The one thing to get right is that not every failing row means "this subject
breached the policy". Four kinds of row, four meanings:

| Failing row | `subject.id` | What it means | A violation? |
| --- | --- | --- | --- |
| one of your own checks (`approved`) | the subject that failed | this subject breached this check | **yes** |
| `$applies` | the subject that didn't qualify | out of scope, never evaluated | **no** |
| `$min_subjects` | `null` — the row is about the requirement, not a subject | too few in-scope subjects existed | **yes** |
| `$well_formed` | `null` — likewise | the requirement itself is malformed | **yes** (and it's a bug in the policy, not in the thing being judged) |

So `d-3` above is not a problem; `d-2` is. And `subject.id` is `null` on
`$min_subjects` rows because there is no single subject to blame — "no
production deployment at all" is a fact about the requirement.

In Rego, the ids with a failing row are one comprehension:

```rego
failing_subjects contains id if {
	some r in report.results
	r.passed == false
	r.check != "$applies"
	id := r.subject.id
}
```

→ `["d-2"]`

That answers *"which subjects have a failing row"*. For this policy it happens
to coincide with *"which subjects are in breach"* — but only because there's a
single `every` requirement here. The general answer needs one more guard, which
is the next section.

### Evidence vs. violations

The report is deliberately a **superset**. It records every check that ran —
passing and failing, in scope and out — because evidence that exonerates
matters as much as evidence that convicts. "PR #44 was CLOSED, so we never
evaluated it" and "this PR failed, but another one met every check" are both
facts an auditor may want, and neither is a breach.

Narrowing that superset to the actionable subset is `evidence.violations`:

```rego
violations := evidence.violations(report)
```

It is a pure function of the report — no input document, no policy — and
applies three filters, each dropping rows that remain in the report as
evidence:

| dropped | because |
| --- | --- |
| passing rows | nothing to answer for |
| rows of a **satisfied** requirement | under `"require": "some"`, another subject met every check, so these are exculpatory |
| `$applies` rows | out of scope is not in breach |

`$min_subjects` rows are deliberately **kept** — "no production deployment at
all" is exactly the breach that guard exists to report.

Each entry is the row joined to its check definition, so a caller doesn't have
to do that lookup itself:

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
entries and never a formatted string, because the message is the one part that
really is policy-specific:

```rego
violations contains msg if {
	some v in evidence.violations(report)
	msg := sprintf("%s: %s — %s", [subject_label(v), v.check, v.description])
}

# $min_subjects and $well_formed are about the requirement rather than any one
# subject, so their subject.id is null. Interpolate it blindly and you get
# "deployment 'null': $min_subjects — ...".
subject_label(v) := sprintf("%s '%v'", [v.subject.type, v.subject.id]) if {
	v.subject.id != null
}

subject_label(v) := sprintf("%s (requirement-level)", [v.subject.type]) if {
	v.subject.id == null
}
```

→ `["deployment 'd-2': approved — A named approver signed off on the deployment"]`

That's exactly what `examples/code_review.rego` does. The second filter in
particular is worth *not* hand-rolling: a policy that forgets it reports
violations while `allow` is `true`, which is two derivations of the same report
visibly disagreeing.

Note also that `allow` and `violations` are **independent** derivations —
`allow := report.compliant` comes from the library's verdict, which never reads
rows. So a bug in a violations projection can produce a misleading message list
but cannot let a non-compliant trail through. That's also why the *report* is
the hashable, attestable artifact and `violations` isn't: the report is a claim
about what was observed, violations are an interpretation of it, and
interpretations can be revised without invalidating the evidence.

**A denial is never silent.** An unsatisfied requirement always produces at
least one failing row, so `violations` is never empty while `compliant` is
`false`. That holds because every way a requirement can fail is reported by
something: too few subjects by `$min_subjects`, a subject failing its checks by
that check's own row, and a requirement that asserts nothing satisfiable by
`$well_formed`. `test_an_unsatisfied_report_always_explains_itself` sweeps all
180 combinations of `require` × `min_subjects` × checks-declared × filter ×
input shape to keep it that way.

Gate on `compliant` regardless — `violations` is the explanation, not the
verdict.

**Policy errors and subject breaches share one list.** A failing `$well_formed`
says *your policy* is broken, not the thing being judged — a different person
fixes it, and the other rows from that requirement may mean nothing until they
do. Both kinds land in the same array, with `$well_formed` sorted first. That's
a deliberate call rather than an oversight: it only arises from a malformed
policy, which that policy's own tests should catch long before production. If it
turns out to confuse people in practice, adding a `category` field to violation
entries is purely additive and would break nothing that reads them today.

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

Rendered expression: `every checks: conclusion == success`. Against a
deployment with a mixed pair of checks, the row echoes the whole projection —

```json
{
  "requirement": "prod_deploy", "subject": {"type": "deployment", "id": "d-1"},
  "check": "checks_green",
  "inputs": [{"name": "checks[].conclusion", "value": ["success", "failure"]}],
  "passed": false
}
```

— and against a deployment whose `checks` array is *empty*, it fails, with
`"value": []`. "Every check passed" over a subject with no recorded checks is
absence of evidence, not evidence of compliance. That is the fail-closed
principle showing up where it surprises people most.

### Requiring one subject to pass everything

`require` defaults to `every`: all in-scope subjects must pass all checks. Set
`"require": "some"` and the requirement is satisfied when **one** subject passes
**all** checks on its own.

That distinction is the whole point of the real code-review control. "One
merged PR was on the protected branch, and one merged PR had signed commits,
and one merged PR was peer-approved" must not add up to compliance if those
were three different PRs. `some` forbids splitting the checks across subjects —
see `examples/trail_split.json`, which is built to fail exactly that way.

Note that with `some`, failed rows for the *other* subjects are still in the
report. They're evidence, not violations: another subject met every check.
`examples/code_review.rego` handles this by only projecting violations from
requirements that aren't satisfied.

### Next step

Read `examples/code_review.rego`. It's Kosli's real SDLC-CTRL-0007 code review
control expressed as two requirements — an artifact and a merged PR — and it
uses every concept above plus one custom op. It's roughly 100 lines, and a good
share of them are descriptions and comments.

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

The name is the **object key**, not a field inside the requirement. That's what
makes names unique by construction, so a row's `(requirement, check)` pair
always resolves to exactly one definition. A policy declaring **no
requirements** asserts nothing and is never compliant.

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

`compare` compares **two fields of the same subject** — both `left` and
`right` are paths, not constants. To bound a field against a literal, use
`range`.

**Collection operators** apply a nested check across a nested array, one
nesting level deep (Rego forbids recursion):

| `op` | Parameters | Passes when |
| --- | --- | --- |
| `all` | `path`, `check` | `path` is a non-empty array and *every* element passes the nested `check` |
| `any` | `path`, `check` | `path` is a non-empty array and *some* element passes the nested `check` |

**Custom ops** cover anything the vocabulary can't express. You contribute an
`op_passed(check, subject)` rule body into the `kosli.evidence` package from
your own file — see `examples/code_review_ops.rego` — and it flows through the
same report machinery. Two things the library can't derive for you, so declare
them on the check:

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
- `all`/`any` require a non-empty array. "Every commit is signed" over a
  subject with no recorded commits is absence of evidence, not evidence of
  compliance.
- `min_subjects` defaults to 1, so a typo in `from` fails the requirement
  instead of vacuously satisfying it. Set it to `0` to opt back into a vacuous
  pass; a policy with no requirements at all is never compliant, and neither is
  a requirement that declares no checks.

And a denial always says why: an unsatisfied requirement is guaranteed to
produce at least one failing row, which is what `$well_formed` exists to
guarantee for the cases where nothing else would.

`equals` distinguishes a field that is absent from one explicitly set to
`null`: only the latter satisfies `"value": null`.

### Report shape

`evidence.report(input, requirements)` returns:

```json
{
  "compliant": true,
  "requirements": {
    "merged_pr": {
      "require": "some",
      "satisfied": true,
      "subjects": {"total": 2, "matching": 1},
      "checks": {
        "commits_signed": {
          "op": "all", "path": ["commits"], "check": {...},
          "description": "Every commit ... signed ...",
          "expression": "every commits: verified == true"
        },
        "$well_formed": {
          "description": "the requirement declares at least one check and a recognised \"require\" value; ...",
          "expression": "count(checks) >= 1 and require in {every, some}"
        },
        "$min_subjects": {
          "description": "at least 1 matching pull_request subject(s) required",
          "expression": "count(matching(trail...pull_requests)) >= 1"
        },
        "$applies": {
          "description": "subject is in scope as a pull_request under this requirement's applies_to filter; ...",
          "expression": "state == MERGED"
        }
      }
    }
  },
  "results": [
    {
      "requirement": "merged_pr",
      "subject": {"type": "pull_request", "id": "https://github.com/.../pull/42"},
      "check": "commits_signed",
      "inputs": [{"name": "commits[].verified", "value": [true, true]}],
      "passed": true
    },
    {
      "requirement": "merged_pr",
      "subject": {"type": "pull_request", "id": "https://github.com/.../pull/44"},
      "check": "$applies",
      "inputs": [{"name": "state", "value": "CLOSED"}],
      "passed": false
    }
  ]
}
```

Abbreviated: two representative rows, where a real `results` also holds this
requirement's `$well_formed` and `$min_subjects` rows and a row per remaining
(subject, check) pair. [The report, in full](#the-report-in-full) shows a
complete one, verbatim.

The check **definition** — its raw spec, description, and rendered `expression`
string — is declared once per `(requirement, check)` pair, in
`requirements[<name>].checks`. Rows in `results` carry only what's actually
different per subject: `{requirement, subject, check, inputs, passed}`. A row's
`(requirement, check)` is a reference into
`requirements[<requirement>].checks[<check>]` — it is not safe to look a check
up by name alone, since two different requirements may reuse the same name for
unrelated checks. That lookup always resolves to exactly one definition,
because a requirement's name is the policy object's own key: duplicates are
unrepresentable rather than something the library has to detect and
disambiguate.

Row order is deterministic and independent of how the policy object was written.
Rows are grouped by kind of check, running from the most general question to the
most specific — every requirement's `$well_formed` row, then every
`$min_subjects` row, then all `$applies` rows, then all check rows. Within a
group, requirements come in name order; within one requirement's `$applies` or
check rows, subjects come in the order the input listed them, and a subject's
check rows in check-name order. So with more than one requirement the groups
interleave: both requirements' `$well_formed` rows precede either one's
`$min_subjects` row. Two consumers building the same policy with its keys in a
different order produce byte-identical reports, which is what makes the report
safe to hash and attest.

This makes the report:

- **total** — every declared check produces a row, including on malformed or
  missing input (`object.get` with defaults throughout), so "failed because
  temp_c was missing" is still a row, not a silent gap;
- **not redundant per-row** — a policy running the same check against many
  subjects (many commits, many PRs) doesn't repeat that check's
  description/expression on every one of those rows;
- **self-contained** — a downstream consumer can interpret every row without
  re-parsing the `.rego` source, by looking up its `(requirement, check)` in
  `requirements[].checks`.

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

- A **pure function of the report** — it takes no input document and no policy,
  which is what makes the selection generic rather than per-consumer.
- Drops passing rows, rows of a **satisfied** requirement, and `$applies` rows.
  Keeps `$min_subjects` and `$well_formed` failures. See
  [Evidence vs. violations](#evidence-vs-violations) for why each.
- `description` and `expression` fall back to `""` when the check didn't declare
  them; every other field comes from the row.
- An **array**, not a set: order follows `results` (deterministic), and two
  distinct failures that would render to the same string are not collapsed.
- Returns **structured entries, never formatted strings** — wording is the
  policy's call.

Empty violations while `compliant` is `false` cannot happen — see
[Evidence vs. violations](#evidence-vs-violations). Gate on `compliant` anyway,
and treat violations as the explanation rather than the verdict.

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

- **`src/library_test.rego`** — the engine: subject resolution, `applies_to`
  filters, every leaf and collection operator (including what each one does
  with missing, null, and wrong-typed input), echoed inputs, rendered
  expressions, row shape and totality, `min_subjects`, `$well_formed`, both
  `require` modes, the `violations` projection, and the report-level invariants
  (determinism, order-independence of policy keys, every row resolving to
  exactly one check definition, and every unsatisfied report explaining itself).
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
pass over an empty collection, a `$min_subjects` row labelling a count it
wasn't reporting, out-of-scope subjects leaving no trace, colliding requirement
and check names, and an unsatisfied requirement denying with nothing to explain
itself. Those are the cases most worth not reintroducing.

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
  as a `kosli.evidence` policy; `code_review_ops.rego` supplies the one custom
  op (`peer_approved`) that exceeds the operator vocabulary, contributed into
  the `kosli.evidence` package from the policy side, the same way a real
  customer would; `trail_compliant.json` and `trail_split.json` are input
  documents to evaluate it against; `code_review_test.rego` tests the policy
  and its custom op.

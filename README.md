# kosli.evidence

A Rego library that turns policy evaluation into a structured, hashable
evidence report, instead of a bare `allow`/`deny` plus hand-written
violation strings.

## What we're trying to achieve

Kosli policies (e.g. SDLC-CTRL-0007, code review) are currently hand-written
Rego that computes `allow` and a `violations` set directly. That works, but
every policy re-invents its own evaluation and reporting logic, and Rego
works against you in two specific ways:

- **Booleans are undefined on failure, not `false`.** A rule that doesn't
  hold simply vanishes from the output rather than reporting `passed:
  false`. Anything meant to be audit evidence ("this predicate was checked
  and failed because X") has to work around that explicitly.
- **Rego has no notion of "which inputs did this rule read."** That has to
  be declared by hand if you want it in the evidence trail.

The goal is a single generic library that customers' policies call into,
so that authoring a policy means *declaring* what to check (as data) rather
than writing evaluation and reporting logic per policy. The output is a
uniform report — the same shape regardless of which policy produced it —
that can be hashed and attested alongside the policy itself, and consumed
by other tooling without parsing Rego.

## Design

A policy is a list of **subject sets**:

```rego
{
    "name": "merged_pr",          # row linkage + set verdict key (default: type)
    "type": "pull_request",       # subject type label
    "path": [...],                # collection location in input (array or single object)
    "id": [...],                  # identity path within a subject
    "quantifier": "every"|"some", # every subject must pass / some subject must pass ALL clauses
    "where": {name: clause},      # filter: only subjects passing these become subjects
    "min_count": 1,               # guard against a vacuous pass on an empty collection
    "clauses": {name: clause},
}
```

Each **clause** is a small spec: which field(s) to read (`path`), which
operator to apply (`op`), and that operator's parameters. Leaf operators:
`range`, `excludes`, `includes`, `equals`, `present`, `non_empty_string`,
`compare`, `compare_time`. Collection operators (`all`, `any`) apply a leaf
clause across every element of a nested array, one nesting level deep
(Rego forbids recursion). Anything beyond the vocabulary is a **custom
op** — contributed as an `op_passed(clause, subject)` rule body from a
separate file into the `kosli.evidence` package (see
`examples/code_review_ops.rego`), still flowing through the same report
machinery.

A policy calls `evidence.report(input, sets)` and gets back:

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
    }
  ]
}
```

The clause **definition** — its raw spec, description, and rendered
`expression` string — is declared once per `(set, predicate)` pair, in
`sets[].clauses`. Rows in `results` carry only what's actually different
per subject: `{set, subject, predicate, inputs, passed}`. A row's
`(set, predicate)` is a reference into `sets[<set>].clauses[<predicate>]`
— it is not safe to look a clause up by predicate name alone, since two
different sets may reuse the same name for unrelated clauses.

This makes the report:
- **total** — every declared predicate produces a row, including on
  malformed or missing input (`object.get` with defaults throughout), so
  "failed because temp_c was missing" is still a row, not a silent gap;
- **not redundant per-row** — a policy checking the same clause against
  many subjects (many commits, many PRs) doesn't repeat that clause's
  description/expression on every one of those rows;
- **self-contained** — a downstream consumer can interpret every row
  without re-parsing the `.rego` source, by looking up its `(set,
  predicate)` in `sets[].clauses`.

`min_count` and any `where`-filtered set produce their own synthetic rows
(predicate `"min_count"`) with a matching entry in `sets[].clauses`, so
they're consumable the same way as ordinary predicate rows.

## Running it

```sh
opa eval -d src/library.rego -d examples/code_review.rego -d examples/code_review_ops.rego \
  -i examples/trail_compliant.json --format=pretty 'data.policy.output'

opa check --strict src examples
```

Swap `trail_compliant.json` for `trail_split.json` to see a failing case
(`allow: false`, populated `violations`).

## Repo layout

- **`src/`** — the library itself. `library.rego` (`package
  kosli.evidence`) is the generic engine; nothing in here is specific to
  any one policy.
- **`examples/`** — a worked example of consuming the library:
  `code_review.rego` expresses Kosli's real SDLC-CTRL-0007 code review
  control as `kosli.evidence` subject sets; `code_review_ops.rego`
  supplies the one custom op (`peer_approved`) that exceeds the operator
  vocabulary, contributed into the `kosli.evidence` package from the
  policy side, the same way a real customer would; `trail_compliant.json`
  and `trail_split.json` are input documents to evaluate it against.

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
    "min_count": 1,               # matching subjects required (default 1)
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

Every operator is **fail-closed**: a missing, null or wrong-typed field
makes the clause fail rather than vanish or pass by accident. Three cases
are worth spelling out, because Rego's defaults point the other way:

- `compare`/`compare_time` require both sides to be present and of the
  same type. Rego's `<` is total across types — `null < 5` is *true* — so
  an unguarded `lt` against a missing field would report success.
- `all`/`any` require a non-empty array. "Every commit is signed" over a
  subject with no recorded commits is absence of evidence, not evidence of
  compliance.
- `min_count` defaults to 1, so a typo in `path` fails the set instead of
  vacuously satisfying it. Set it to `0` to opt back into a vacuous pass;
  a report with no sets at all is never compliant, and neither is a set
  that declares no clauses.

`equals` distinguishes a field that is absent from one explicitly set to
`null`: only the latter satisfies `"value": null`.

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
`sets[].clauses`. Rows in `results` carry only what's actually different
per subject: `{set, subject, predicate, inputs, passed}`. A row's
`(set, predicate)` is a reference into `sets[<set>].clauses[<predicate>]`
— it is not safe to look a clause up by predicate name alone, since two
different sets may reuse the same name for unrelated clauses. That lookup
always resolves to exactly one definition: two sets declaring the same
`name` would break it, so the second one is suffixed with its position
(`merged_pr`, `merged_pr#1`).

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

Predicates the library synthesises are `$`-prefixed, so they can never
collide with a policy's own clause names. Each has an entry in
`sets[].clauses` like any other, so they're consumable the same way:

- **`$min_count`** — one row per set: were there enough matching subjects.
- **`$matches_filter`** — one row per *raw* subject, for sets that declare
  a `where`: did this subject qualify. A subject that didn't is named in
  the evidence, with the field the filter read, rather than surviving only
  as a `total`/`matching` discrepancy. It gets no clause rows — it was
  never evaluated — and a consumer projecting violations should skip these
  rows, since being out of scope is not a breach (see `violations` in
  `examples/code_review.rego`).

A **custom op** should declare `echo` listing every input it reads, since
the library can't infer that. An entry is either a path (`["author"]`) or
a projection across a collection (`{"path": ["commits"], "each":
["timestamp"]}` → `commits[].timestamp`), so a row carries everything
needed to recompute its own verdict.

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

- **`src/`** — the library itself. `library.rego` (`package
  kosli.evidence`) is the generic engine; nothing in here is specific to
  any one policy. `library_test.rego` is its test suite.
- **`examples/`** — a worked example of consuming the library:
  `code_review.rego` expresses Kosli's real SDLC-CTRL-0007 code review
  control as `kosli.evidence` subject sets; `code_review_ops.rego`
  supplies the one custom op (`peer_approved`) that exceeds the operator
  vocabulary, contributed into the `kosli.evidence` package from the
  policy side, the same way a real customer would; `trail_compliant.json`
  and `trail_split.json` are input documents to evaluate it against;
  `code_review_test.rego` tests the policy and its custom op.

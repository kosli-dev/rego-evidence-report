# Working on this library

Notes for people changing `src/library.rego`. For what the library does and how
to use it, see the [README](README.md).

## Running the tests

```sh
opa test src examples --ignore '*.json'   # everything
opa test src --verbose                    # library only
opa check --strict src examples           # lint
```

The `--ignore` is required: `examples/*.json` are `opa eval` fixtures and both
define `data.trail`, so loading them together is a merge error. The test files
build their fixtures inline instead.

Rego packages have the same hazard, and it is not a name clash that shadows —
two modules of one package **merge**. `examples/code_review.rego` and the
vendored `examples/four-eyes.vendored.rego` are both ports of policies deployed
as `package policy`, and loading two `package policy` modules together makes
`allow` a conflicting complete rule and silently unions their `violations` sets,
failing tests in whichever file you were not editing. Hence the vendored copy is
renamed. If you add another policy that upstream deploys as `package policy`,
rename it the same way and say so in its header.

### Under strict builtin errors

`opa test` has no flag for strict builtin errors, so the fail-closed claims are
worth checking through `opa eval` as well:

```sh
opa eval --strict-builtin-errors -d src/library.rego -d examples/code_review.rego \
  -d examples/code_review_ops.rego -i examples/trail_split.json 'data.policy.output'
```

One known edge survives this: `compare_time` screens its inputs with a shape
regex before parsing, so malformed timestamps produce a failing row even under
the flag. A calendar-impossible but well-shaped date (`2024-02-31T00:00:00Z`)
still reaches `time.parse_rfc3339_ns`, which is a builtin error — fatal under
that flag, a failing row without it.

## What the suites cover

- **`src/library_test.rego`** — the engine: subject resolution, `applies_to`
  filters, every leaf and collection operator (including what each one does with
  missing, null, and wrong-typed input), the `each` projection and `any_of`
  element checks, substitutes, every `cause` value and their precedence, echoed
  inputs, rendered expressions, row shape and totality, `min_subjects`,
  `$well_formed`, both `require` modes, and the `violations` projection.
- **`examples/code_review_test.rego`** — the consumer policy: both README
  scenarios, the violation projection, the `peer_approved` custom op, and
  `data.params` configurability.

## Invariants worth not breaking

These are pinned by tests, and they're the reason the report is safe to hash and
attest. If a change makes one of them fail, the change is almost certainly wrong.

- **Determinism and key-order independence.** Two consumers building the same
  policy with its object keys in a different order produce byte-identical
  reports. Row order is grouped by kind of check — all `$well_formed`, then all
  `$min_subjects`, then all `$applies`, then all check rows — with requirements
  in name order within each group.
- **Every row resolves to exactly one check definition** via its
  `(requirement, check)` pair.
- **Every row carries a `cause`, and it is one of the seven documented values.**
  The field exists to tell absence, a null, an unmatched selector and an
  ambiguous one apart; a change that lets two of those collapse back into one
  value takes the field's reason for existing with it.
- **A denial is never silent.** `test_an_unsatisfied_report_always_explains_itself`
  sweeps all 180 combinations of `require` × `min_subjects` × checks-declared ×
  filter × input shape, asserting that no report is ever `compliant: false` with
  an empty `violations`.
- **A malformed requirement is never satisfied.** Every `requirement_satisfied`
  body opens with the same two conditions `$well_formed` tests, so a failing
  `$well_formed` row can't be swallowed by the satisfied-requirement guard in
  `violations()`. `test_a_malformed_requirement_is_never_satisfied` pins that
  against someone later relaxing one of those bodies.
- **Fail-closed everywhere.** Missing, null, or wrong-typed input makes a check
  fail; it never vanishes and never accidentally passes. Custom ops are ordinary
  Rego rules, so this one is on their author — the comments in
  `examples/code_review_ops.rego` walk through the three ways `peer_approved`
  could have failed open.

## Test conventions

- **`todo_test_` marks a known-open issue.** `opa test` skips the rule, so the
  suite stays green while the assertion states the behaviour we want; closing the
  issue is the change that renames it to `test_`. Nothing is skipped at the
  moment.
- **The `regressions` section at the end of each file** holds one rule per
  fail-open or evidence-integrity bug the library shipped with, each naming the
  trap it fell into: `compare` passing on a missing field, `peer_approved`
  ignoring commits with no timestamp, a vacuous pass over an empty collection, a
  `$min_subjects` row labelling a count it wasn't reporting, out-of-scope
  subjects leaving no trace, colliding requirement and check names, and an
  unsatisfied requirement denying with nothing to explain itself. These are the
  cases most worth not reintroducing — add to this section when you fix a bug of
  the same kind.

## The layer stack, and the one way to break someone else's build

Rego rejects recursion — not just `a` calling itself, but any cycle in the rule
graph, at any length, across any number of files. `a -> b -> a` and
`a -> b -> c -> a` are both `rego_recursion_error`, raised by the compiler
before anything evaluates.

That is the constraint the whole library is shaped around, because evaluating a
nested check *is* a recursive problem. The way it is spent is a ladder of
distinct rule names, each level calling only downwards:

```
check_passed        the named check, or the "substitute" it declares
  └─ op_passed      dispatch on check.op — where custom ops plug in
       └─ element_passed    inside all/any: a leaf, or an any_of over leaves
            └─ any_of_passed / leaf_passed
```

Every "one level, because Rego forbids recursion" comment in `library.rego` is
this same wall from a different side. `any_of` options hold leaves only because
an option containing an `any_of` would be `any_of_passed -> any_of_passed`.
`each` buys a second collection level and not a third because a third needs a
rung that calls itself. Depth is bought one rule name at a time, and the price
is paid at design time.

**So a custom op may call *down* the ladder and never up.** Down is
`leaf_passed`, `element_passed`, `value_at`, `field`, `comparable`, any builtin
— and `every`/`some` nested as deeply as you care to type inside your own rule
body, which is where unbounded depth actually lives and is why the escape hatch
is worth having. Up is `check_passed`, `op_passed`, `subject_passed`,
`requirement_satisfied`, `report`.

This is the one authoring mistake whose blast radius is not your own file.
Custom ops contribute `op_passed` bodies into `package kosli.evidence` from
outside, and the cycle check runs over the merged graph, so nine lines in a
policy's ops file stop the *library* compiling:

```rego
# examples/somebody_ops.rego — plausible, and fatal
op_passed(check, subj) if {
	check.op == "delegates"
	check_passed(check.inner, subj)          # calls back up
}
```

```
$ opa check --strict src/library.rego examples/somebody_ops.rego
3 errors occurred:
src/library.rego:478: rego_recursion_error: rule data.kosli.evidence.check_passed is recursive: data.kosli.evidence.check_passed -> data.kosli.evidence.op_passed -> data.kosli.evidence.check_passed
src/library.rego:480: rego_recursion_error: rule data.kosli.evidence.check_passed is recursive: data.kosli.evidence.check_passed -> data.kosli.evidence.op_passed -> data.kosli.evidence.check_passed
examples/somebody_ops.rego:5: rego_recursion_error: rule data.kosli.evidence.op_passed is recursive: data.kosli.evidence.op_passed -> data.kosli.evidence.check_passed -> data.kosli.evidence.op_passed
```

Errors are ordered by file, so the two naming `library.rego` come *first* and the
one naming the file you actually edited comes last. If `opa check` reports
recursion in a file you did not touch, look for a custom op that reached
upwards.

Delegation itself is fine as long as it goes down. The same op written against
`element_passed` compiles and works, because that rung evaluates a leaf or an
`any_of` and calls nothing above it:

```rego
op_passed(check, subj) if {
	check.op == "delegates"
	element_passed(check.inner, subj)        # a leaf or an any_of, downwards
}
```

What that cannot reach is a *named* check — one that might itself be an
`all`/`any`, another custom op, or carry a substitute of its own. Delegating to
one of those is what `substitute` is for, and it is why it lives one rung above
`op_passed` instead of being an operator like everything else.

## Design notes

Two decisions come up often enough to write down.

**The report is a superset; `violations` is an interpretation of it.** The report
records every check that ran — passing and failing, in scope and out — because
evidence that exonerates matters as much as evidence that convicts. That's why
the *report* is the hashable, attestable artifact and `violations` isn't: the
report is a claim about what was observed, violations are a reading of it, and a
reading can be revised without invalidating the evidence.

**`allow` and `violations` are independent derivations.**
`allow := report.compliant` comes from the library's verdict, which never reads
rows. So a bug in a violations projection can produce a misleading message list
but cannot let a non-compliant trail through.

**Policy errors and subject breaches share one list.** A failing `$well_formed`
says the *policy* is broken, not the thing being judged — a different person
fixes it, and the other rows from that requirement may mean nothing until they
do. Both kinds still land in the same array, with `$well_formed` sorted first,
because it only arises from a malformed policy that the policy's own tests
should catch long before production. If that turns out to confuse people, adding
a `category` field to violation entries is purely additive.

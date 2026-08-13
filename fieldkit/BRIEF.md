# Brief: validate kosli.evidence against real data

**You are Claude Code running on a restricted machine that has access to real
Deutsche Bank data. The person you are working with cannot easily move
information off this machine.** This document is your task. Read it fully before
acting, then work through the investigations in order.

## Situation

`kosli.evidence` (in `src/library.rego`) is a Rego library that turns policy
evaluation into a structured evidence report instead of a bare `allow`/`deny`.
Read `README.md` in this repo for the full model; the short version is that a
policy *declares as data* which subjects are being judged and which named checks
apply, and the library produces a uniform report of one row per (subject, check)
pair — each row carrying the values it read.

**It has never met real data.** Every fixture it passes was written by the same
person who designed the vocabulary, so the fixtures fit by construction. Your job
is to find out where real data breaks it.

This repo arrived here by `git clone`. You **cannot push** — the return channel is
a human retyping your findings. That constraint shapes everything below: your
output must be short, and it must contain no confidential values.

## Rules

1. **No real values leave this machine.** Report field *names*, *types*, *counts*,
   and *operator names* only. No usernames, emails, URLs, repo names, commit
   SHAs, fingerprints, artifact names, environment names, or timestamps. If a
   finding can't be stated without a value, describe the value's *shape*
   instead — "an 18-character opaque string", "an RFC3339 timestamp with a
   timezone offset rather than Z".
2. **Do not attempt to push, open a PR, or otherwise write to GitHub.** It will
   fail and may lock a credential. Your deliverable is terminal output.
3. **Verify, don't infer.** Every claim in your findings must come from a command
   you actually ran. If you couldn't run it, say so explicitly rather than
   reasoning about what would probably happen.
4. **Keep real input documents in `fieldkit/scratch/`**, which is gitignored, so
   confidential data can't be committed and `git reset --hard` (the refresh
   command here) can't destroy your work.

## Investigation 1 — environment recon

Do this first; everything else depends on it. Report what you find, including the
negatives.

```sh
opa version                 # required: the library is Rego, this evaluates it
python3 --version           # optional: fieldkit/kit.py uses it, stdlib only
node --version              # relevant to investigation 4
```

If `opa` is missing, that is the top-line finding — the library is text and
travels anywhere, but the evaluator is a binary. Check for an internal artifact
mirror before concluding it's unobtainable.

Then confirm the toolchain is sound before trusting any later result:

```sh
opa test src examples --ignore '*.json'   # expect PASS: 227/227
```

A failure here means the library is broken on this platform/OPA version, which
outranks every other finding.

## Investigation 2 — can you get a real input document?

The library evaluates a JSON document. Find one: a real Kosli trail, or whatever
the equivalent internal system produces. Put it at
`fieldkit/scratch/trail.json`.

If you cannot obtain one, stop and report that — it is the blocker, and
everything below is unreachable without it. Do not substitute a synthetic
document and report on that; fixtures are exactly what this exercise exists to
get past.

Then describe its structure. If `python3` is available:

```sh
python3 fieldkit/kit.py shape fieldkit/scratch/trail.json
python3 fieldkit/kit.py shape fieldkit/scratch/trail.json --rego   # paste-able paths
```

If not, do it yourself — you need paths, types, and **how many siblings actually
carry each field**, because a field present on 1 of 3 siblings is where a check
will fail closed. Never print values while doing this.

## Investigation 3 — which assumptions does real data falsify?

This is the heart of the trip. The library's vocabulary rests on the assumptions
below. Each is falsifiable. Write a policy against the real document
(`cp fieldkit/policy_template.rego fieldkit/scratch/policy.rego` — the template
carries the whole operator vocabulary in comments) and find out which hold.

```sh
python3 fieldkit/kit.py run fieldkit/scratch/policy.rego fieldkit/scratch/trail.json
# or, without python3:
opa eval -d src/library.rego -d fieldkit/scratch/policy.rego \
  -i fieldkit/scratch/trail.json --format=pretty 'data.scratch.report'
```

| # | Assumption | Falsified if |
| --- | --- | --- |
| A1 | Subjects live as an array, or a single object, at **one fixed path** in the input | subjects have to be gathered from several paths, or from a map keyed by data, or require a join |
| A2 | A subject has a **stable scalar id** at a fixed path | identity is composite, absent, or only unique within a parent |
| A3 | **One nesting level** of collection ops (`all`/`any`) is enough | a check needs to reach a collection inside a collection — Rego forbids recursion, so this would need a library change |
| A4 | Checks are **independent** — no check needs another's result | a check is only meaningful conditional on another passing |
| A5 | A check reads **only its own subject** | a check must compare against another subject, or against config/reference data outside the input |
| A6 | Timestamps are RFC3339 strings or numbers | some other format, or mixed formats across records |
| A7 | `min_subjects: 1` is the right default | a real control legitimately has zero subjects and should still pass |
| A8 | Scope filtering (`applies_to`) is a **per-subject predicate** | in-scope-ness depends on the set of subjects, not on one subject alone |

For each: state **held** or **broke**, and if it broke, the smallest description
of what real data did instead.

Then the two questions that matter most, because they decide library work versus
per-policy workarounds:

- **Which checks needed a custom op?** For each, what did it have to do that the
  vocabulary couldn't express?
- **Which operator was *nearly* right?** Name it and the missing parameter. This
  is the highest-value finding: it becomes a small library change rather than an
  escape hatch every policy has to re-implement.

Also watch for a specific failure mode: **a check that failed for the wrong
reason.** A wrong `path` produces a failing row that looks exactly like a breach.
Does the row's `inputs` column let you tell the two apart? If not, that's a
reportable weakness in the report design.

## Investigation 4 — the consumption path

Kosli's production controls are TypeScript. How would one of them actually
evaluate this library here? Find out which of these is true, by inspecting how
existing controls work rather than by reasoning:

1. shelling out to the `opa` binary,
2. calling a running OPA server over HTTP,
3. compiling the policy to WASM and calling it in-process
   (`@open-policy-agent/opa-wasm`).

This matters because a restricted environment may not permit an extra binary or a
sidecar process, which would force option 3.

**Two things about option 3 were already established before you got this brief, so
don't re-derive them:**

- You **cannot** compile the library on its own. Its API is *functions*
  (`report(input, requirements)`), and a WASM entrypoint must be a data document —
  `opa build -t wasm -e 'kosli/evidence' src/library.rego` fails with
  `function ... used as reference, not called`.
- You **can** compile a consuming policy that has a concrete rule, with the
  library bundled alongside it. This succeeds and produces a ~124KB bundle:

  ```sh
  opa build -t wasm -e 'policy/output' \
    src/library.rego examples/code_review.rego examples/code_review_ops.rego
  ```

  Both suspect builtins (`time.parse_rfc3339_ns` behind the `compare_time`
  operator, and `regex.match`) survive that build.

So the WASM path is viable in principle, and the open questions are the ones only
this environment can answer:

- Does the same build succeed **here**, on this machine's OPA version?
- Can a TS control actually *instantiate and evaluate* that bundle — not just
  build it? Building proves the builtins compile; it does not prove evaluation
  works. If `@open-policy-agent/opa-wasm` is reachable, try it and report the
  result of a real `evaluate()` call.
- Bundling the policy at build time means **the policy is fixed at build time**.
  Do the TS controls need to load or vary policies at runtime? If so, that rules
  out option 3 regardless of whether it works.

## Investigation 5 — scale

How many subjects and rows does a real document produce, and how long does
evaluation take? The report is one row per (subject, check) pair, so it grows
multiplicatively. If a real trail produces thousands of rows, that affects
whether the whole report can be hashed and attested as-is.

```sh
time opa eval -d src/library.rego -d fieldkit/scratch/policy.rego \
  -i fieldkit/scratch/trail.json --format=json 'data.scratch.report' | wc -c
```

## Deliverable

End with exactly this block, filled in, and nothing longer. It has to survive
being retyped by a human, so keep it under ~30 lines and use short phrases rather
than sentences. Field names and operator names are fine; values are not.

```
FINDINGS
env:        opa <version> | python3 <y/n> | node <version or n>
tests:      <PASS n/n | FAIL + what>
input:      <obtained y/n> | <n> subjects | <n> rows | <eval time>
assumptions: A1 <held/broke> A2 <> A3 <> A4 <> A5 <> A6 <> A7 <> A8 <>
broke:      <one line per broken assumption: what real data did instead>
custom ops: <name: what it had to do>  (one line each)
near miss:  <operator: missing parameter>  (the most valuable line here)
wrong-fail: <could a bad path be told apart from a real breach? y/n + why>
consumption: <binary | server | wasm> | wasm build <ok/failed: why> | wasm eval <ok/untried>
runtime-policy: <do TS controls need to vary the policy at runtime? y/n>
blocked:    <anything you could not run, and why>
```

If an investigation was impossible, write `blocked:` rather than guessing. A
short honest block beats a long speculative one — every line has to be retyped by
hand, and a wrong line sends work in the wrong direction back home.

# Start here

For the people joining the mob on control 43. You saw the demo; this is the
30 minutes that gets you from "I saw it" to "I can change it".

Everything below runs offline. No Kosli account, no network, no Node.

## What this is, in three facts

1. **It is one Rego file** — `src/library.rego`, `package kosli.evidence`. It
   takes an input document and a *requirements object* (plain data) and returns
   a **report**: one row per (subject, check), each row carrying what was
   checked, what the document said, whether it passed, and why.
2. **A policy using it is data, not code.** `examples/control_43.rego` is
   control 43 (four-eyes) written as that object, plus a four-line wrapper and
   two custom operators. No rule logic in Rego.
3. **The report is the point.** `{allow, violations}` — what `kosli evaluate`
   returns today — has no columns, so nothing downstream can report on it. The
   report has a fixed shape for every control, which is what makes one exporter
   possible instead of one per control.

## Setup

You need `opa` (one static binary) and `python3` (stdlib only).

```sh
git clone --branch integration https://github.com/kosli-dev/rego-evidence-report.git
cd rego-evidence-report
opa test src examples --ignore '*.json'      # expect PASS: 428/428
```

**The branch matters.** `main` is behind; all of this lives on `integration`.

## The 30 minutes

**1. See a report (5 min).** The failing case, so the rows are interesting:

```sh
opa eval --ignore '*.json' -d src/library.rego -d examples \
  -i demo/trail_self_approved.json --format=pretty 'data.control43.report'
```

Then the same input through the gate interface — one boolean and one string per
failing commit, which is all `kosli evaluate` will carry:

```sh
opa eval --ignore '*.json' -d src/library.rego -d examples \
  -i demo/trail_self_approved.json --format=pretty 'data.control43.output'
```

**2. Read the rows (10 min).** [README.md](README.md) → *Reading the rows* and
*Causes*. The one column to understand is **`cause`**: it separates *the evidence
says no* (`value`) from *the policy could not read its inputs* (`absent`,
`unmatched`, `ambiguous`). Most mistakes you will make are a wrong `path`, and
the cause is how you tell that apart from a real breach.

**3. Read control 43 as data (10 min).** `examples/control_43.rego`. Two
requirements, one subject type (a commit — `kosli evaluate trails` passes one
trail per commit and `trail.name` is the sha). The comments are the reasoning;
the object is the rule.

**4. Change one thing and watch a test fail (5 min).** Break a threshold or a
path in `examples/control_43.rego`, re-run `opa test src examples --ignore
'*.json'`, put it back.

## Where the library plugs in

Only one stage of the pipeline changes: the policy body.

```
collector ──▶ Kosli ──▶ kosli evaluate ──▶ POLICY ──▶ consumer
 (gathers)   (stores)   (builds input)     ▲ here     (schema/attest)
```

Two constraints that shape everything (details in
[INTEGRATION.md](INTEGRATION.md) → *Where `kosli.evidence` plugs in*):

- `kosli evaluate --policy` takes **one file**, parsed as a **single module**
  whose package must be `policy`. So the library cannot be imported — it is
  merged by `fieldkit/bundle.py`, which then proves the merge did not change the
  report. OPA's own `opa build` bundles do not get past this, because the CLI
  reads the file as Rego source rather than loading a bundle; see
  [SHADOW_MODE.md](SHADOW_MODE.md) → *OPA's own bundles*.
- `kosli evaluate` runs **exactly two queries**: `data.policy.allow` and, only
  on a denial, `data.policy.violations`. Everything else the policy computes is
  discarded. **The report does not come out of that door.** Three ways past it,
  all in INTEGRATION.md; one of them needs nothing from anybody and is what
  [SHADOW_MODE.md](SHADOW_MODE.md) calls V2.

## Vocabulary

| term | meaning |
| --- | --- |
| **requirement** | one rule over one kind of subject: `require` (every/some/none), `from`, `id`, `checks` |
| **subject** | the thing judged — for control 43, a commit |
| **check** | one named assertion, naming one operator and its parameters |
| **row** | one (subject, check) result: `passed`, `cause`, `expression`, `inputs` |
| **cause** | `satisfied` · `substituted` · `ambiguous` · `unmatched` · `absent` · `null` · `value` |
| **substitute** | alternative evidence that discharges a check (control 43: the repo's root commit has no PR, so a verified-committer attestation stands in) |
| **custom op** | the escape hatch: a Rego rule contributed into `package kosli.evidence`, dispatching on `check.op`. Control 43 needs two. |

13 operators total, listed in [README.md](README.md) → *Operators*. The same
list is in comments in `fieldkit/policy_template.rego`, which is a scaffold to
copy when starting a policy from scratch.

## Map of the repo

| path | what it is |
| --- | --- |
| `src/library.rego` | the library. Generic; knows no control. |
| `examples/control_43.rego` | control 43 as data. `_ops.rego` = its two custom operators, `_test.rego` = the original's 37 cases, case for case. |
| `examples/control_43_parity_test.rego` | 23 inputs fed to both the port and a vendored `four-eyes.rego`; fails the moment their verdicts part. |
| `examples/four-eyes.vendored.rego` | the deployed policy, body byte-for-byte, package renamed. Pinned by content hash — **it has no ref**, which is task 3 in SHADOW_MODE.md. |
| `examples/control_1068.rego` | a *different* control, to measure what a second one costs. Sketch, not a port. |
| `schema/evidence-report.schema.json` | the report's JSON Schema. What `kosli create attestation-type --schema` wants. |
| `fieldkit/` | three tools you will use on the day — see below. |
| `examples/control_43_spec/data.yaml` | the same control as YAML — no library change, byte-identical report. |
| `examples/control_43_md/policy.md` | the same control as prose. `authoring/` is the transpiler (TypeScript; needs Node, so skip it on a locked-down laptop). |

## Two documents, and what each is for

- **[README.md](README.md)** — the library reference. Vocabulary, all 13
  operators, report shape, fail-closed rules. Read *Your first policy* (~50
  lines) before writing anything.
- **[INTEGRATION.md](INTEGRATION.md)** — the pipeline, the constraints at the
  seam, four reproduced defects in the current `four-eyes.rego`, and a
  **status-of-claims list** at the end that says of every claim in this repo
  whether it was executed, read from source, or inferred. Read that list before
  repeating anything from here in a meeting.

`DEMO.md` is a presenter script. Ignore `fieldkit/README.md` and
`fieldkit/BRIEF_*.md` entirely — those are notes from an agent-to-agent round
trip with the locked-down laptop. They document a process that is over, not this
library.

## The three tools

In `fieldkit/`, stdlib Python, nothing to install. These are the ones worth
knowing; the rest of that directory is process residue.

```sh
# describe a real input document: paths, types, and how many siblings carry
# each field. Never prints a value.
python3 fieldkit/kit.py shape <input>.json

# evaluate a policy over a real document and tabulate the failing rows with
# their cause. This one DOES print real values.
python3 fieldkit/kit.py run examples/control_43.rego <input>.json \
    --ops examples/control_43_ops.rego

# merge the library and a policy into the single `package policy` file that
# `kosli evaluate --policy` accepts, proving as it goes that the merge did not
# change the report
python3 fieldkit/bundle.py --policy examples/control_43.rego \
    --ops examples/control_43_ops.rego --package control43 \
    --verify-with <input>.json -o evidence-bundle.rego
```

Read the third column of `kit.py shape` first: `3/3` means every sibling carries
the field, `1/3` means two don't — which is where a check will fail closed.

## What is proven, and what is not

Short version; the long version is INTEGRATION.md → *Status of these claims*.

| | |
| --- | --- |
| **Executed** | 428 tests. The port vs. vendored `four-eyes.rego`, 23 inputs, verdicts agree. The bundle run through `kosli evaluate` itself (stub API): gate works end to end. `violations` uncapped — 50,000 rows, 16.4 MB, intact. A real report validates against Kosli's own validator, both jq rules correct in both directions. |
| **Never executed** | Any HTTP request to a deployed Kosli. A live `kosli attest custom` of a report. A pull request with **two distinct authors** (the per-author rule has only ever met synthetic input). A real root-commit trail. |

Those last two are exactly what a real pipeline supplies, which is why shadow
mode is worth the morning.

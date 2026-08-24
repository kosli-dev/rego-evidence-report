# Where this library sits in a Kosli control

A policy library is only useful if it fits the pipeline that runs it. This
describes that pipeline as it actually works for control 43 (`RCTLDEF0000043`,
source code review / four-eyes), what each stage owns, and the three constraints
at the seam where `kosli.evidence` would plug in.

Control 43 is the worked example because it is, today, **the only Rego policy in
`sdlc-workflows`** — every other control is still workflow wiring. That fact
shapes the conclusion, so it's stated up front rather than buried.

## The pipeline

```
┌─ 1. COLLECTOR ──────────┐   ┌─ 2. KOSLI ─────┐   ┌─ 3. kosli evaluate ─┐   ┌─ 4. POLICY ──────┐   ┌─ 5. CONSUMER ────┐
│ TypeScript, in the repo │   │ SaaS, stores   │   │ builds input.trails │   │ four-eyes.rego   │   │ schema + optional │
│ walks commits,          │──▶│ trails +       │──▶│ [] and runs OPA     │──▶│ decides allow +  │──▶│ attest custom     │
│ attests PR data         │   │ attestations   │   │                     │   │ violations       │   │                   │
└─────────────────────────┘   └────────────────┘   └─────────────────────┘   └──────────────────┘   └───────────────────┘
   knows: git + GitHub          knows: history        knows: nothing            knows: the rule         knows: the format
   decides: nothing             decides: nothing      decides: nothing          decides: everything     decides: nothing
```

Four of the five stages are control-agnostic. **All per-control work lives in
stage 4.** That is the whole reason a policy library is worth considering, and the
whole reason its value can't be judged from one control.

### 1. Collector — gathers, never judges

```sh
CURRENT_TAG=v1.1.0 GITHUB_REPOSITORY=owner/repo GITHUB_TOKEN=… KOSLI_FLOW=my-flow \
node .github/actions-public/RCTLDEF0000043/dist/index.js --repo /path/to/repo
```

Walks `BASE_TAG..CURRENT_TAG` with `--first-parent` — only commits that landed on
the mainline, not every commit inside every branch — and for each one:

```sh
kosli begin trail <sha> --flow <flow> --commit <sha>
kosli attest pullrequest github --name source-code-review --commit <sha>
```

Two consequences worth internalising, because both contradict assumptions that
control 07 makes:

- **One trail per commit**, not per release and not per artifact. Four-eyes is
  inherently a per-commit question — *was this change seen by someone other than
  its author* — so every commit becomes independently evaluable. **`trail.name` is
  the commit sha.**
- **There is no artifact in control 43 at all.** No fingerprint, no
  `artifacts_statuses`. Those are control-07 concepts; artifact-to-evidence
  linkage is not a question this control asks.

`BASE_TAG` is optional: omitted, the collector asks Kosli for the most recent
commit already carrying a `source-code-review` attestation and resumes from there,
so the tool is incremental by default.

The defining property: **the collector does no evaluation.** That is the entire
difference between control 43's two generations — the legacy version judged in
TypeScript and emitted an xlsx report, while this one only gathers and pushes the
rule into Rego. Without that separation, no policy library is possible.

### 2. Kosli — the record

`kosli attest pullrequest github` pulls the PR from GitHub and stores it against
the trail: the PR's commits with `author_username`, the `approvers` with
`username`/`state`/`timestamp`, the `merge_commit` sha, plus `pr.author`, `pr.url`,
`pr.state`. **Timestamps are epoch numbers.**

Kosli is passive here. It computes compliance status against the flow template but
knows nothing about four-eyes.

### 3. `kosli evaluate` — the harness

```sh
kosli evaluate trails SHA1 SHA2 SHA3 --policy <path> --flow my-flow --output json
```

Assembles the input document — `input.trails[]`, one entry per commit — runs the
policy, and turns the result into an exit code (`0` comply, `1` violations).
`--show-input` dumps exactly what the policy will see.

The contract it imposes is narrow, and it is the crux of everything:

> **package `policy`, exposing `allow` (bool) and `violations` (a set of strings).**

### 4. The policy — where all judgement lives

`four-eyes.rego`, ~200 lines, standalone (imports only `rego.v1`; it does **not**
use this library today). Three rules, ordered so the first match settles a commit:

1. **Service account** — `git_commit_info.author` matches `svc_.*`, `.*\[bot\]`, or
   `noreply@github\.com` → pass, no PR required.
2. **No merged PR** for the commit → fail.
3. **Per-author independent approval** — for every author in
   `pr.commits[].author_username ∪ {pr.author}`, some approver who is *not that
   author*, with `state == "APPROVED"` and a timestamp after the latest commit.

Rule 3 is **per-author**, which is neither per-PR nor per-commit: mutual review
between two authors of the same PR passes, because each has an approver who isn't
themselves. Control 43's own README describes this rule incorrectly (as requiring
an approver who authored no commit in the PR); `SCENARIOS.md` and the policy agree
with each other against it.

It emits four mutually exclusive reasons — missing attestation, no PR, unverifiable
identity, no independent approval — with guards written so one commit yields one
reason.

**Its 37 tests are the real specification.** They pin five behaviours neither
document mentions: `DISMISSED`/`CHANGES_REQUESTED` rejected, a null approver
username rejected, a null `author_username` producing "identity unverifiable", an
`input.trails` fail-closed guard, and a web-flow merge fallback.

### 5. Consumption

`four-eyes-result-schema.json` fixes the output shape: `violations` is
`string[]`, one entry per failing commit. Then, optionally:

```sh
kosli attest custom --type four-eyes-result --attestation-data eval-result.json \
  --attachments <path-to-policy> --flow my-flow --trail release-v1.1.0
```

Note `--attachments <policy>`: the verdict is recorded together with the rule that
produced it. That is already an evidence-provenance instinct, and it is the natural
place a hashable evidence report would belong.

## Where `kosli.evidence` plugs in

Only stage 4. It replaces the *body* of the policy; stages 1, 2, 3 and 5 don't
change and never learn about it.

```rego
package policy                    # the package `kosli evaluate` queries

import data.kosli.evidence

requirements := {"commit_reviewed": { ... }}     # the rule, declared as data
report := evidence.report(input, requirements)
allow := report.compliant                        # same interface out
violations := ...                                # collapsed to one string per commit
```

Three constraints at that seam:

| constraint | cost |
| --- | --- |
| `violations` must stay **one string per failing commit** | this library emits a row per (subject, check), so the policy must collapse them by a declared precedence: missing attestation → no PR → unverifiable identity → no approval |
| `allow` must stay a **bool** | free — `report.compliant` already is one |
| the package must be **`policy`** | free |

The first is arguably an improvement rather than a tax: precedence becomes stated
data instead of an emergent consequence of how rule guards happen to be ordered.

## Two open questions that decide whether this is viable

Both are cheap to answer with a Kosli CLI to hand, and neither has been verified.

1. **Can `--policy` load more than one file?** This library is a separate file in
   its own package that a policy imports. If `--policy` accepts only a single
   file, the library must be concatenated or vendored into every policy — workable,
   but it undermines the "one library, many policies" premise that motivates it.
2. **Does the report survive evaluation?** `kosli evaluate` queries `allow` and
   `violations`. The library's actual product — the hashable, attestable evidence
   table — **has no slot in that contract**. If `--output json` surfaces only those
   two rules, the report is computed and discarded, and the whole exercise buys
   better violation strings and nothing else. If it surfaces the full policy
   document, the report rides along and can be attested through the
   `--attachments` step above. This difference is most of the value.

## What this means for the decision

Since all per-control work is stage 4, the library's bet is that stage 4 stops
being 200 lines of bespoke Rego and becomes a data declaration plus the occasional
custom op — so that the *next* control costs a day instead of a week.

**That bet cannot be tested with one control.** Porting control 43 alone would
swap a working policy for a different one with better evidence rows. The
measurement that matters is the marginal cost of control #2, which argues for
expressing a second, simpler control alongside 43 even roughly.

## Status of these claims

Sourced from control 43's `README.md` and `SCENARIOS.md`, and from a round of
investigation that read `four-eyes.rego`, its 37-test suite and the collector's
TypeScript on a machine with access to them.

- **Confirmed by reading source or running tests:** the per-author rule; the field
  names; epoch timestamps; identities being GitHub logins on both sides; the four
  mutually exclusive reasons; the five undocumented behaviours; 37 tests passing;
  the `allow` + `violations` interface and `policy` package; the schema's
  one-string-per-commit shape; `four-eyes.rego` being the only Rego policy in
  `sdlc-workflows`; control 43 having two generations.
- **Documented but not executed:** every command shown here. No `kosli` CLI was
  available, so `--show-input` was never run and the live wire shape of
  `attestations_statuses` is unconfirmed — though the policy iterates values and
  selects on `attestation_type`, which works for a map or an array, making the
  distinction moot for policy design.
- **Unverified:** the two open questions above.

> This file names internal control identifiers and repository names. It is fine on
> an internal branch; it is worth a deliberate look before anything here reaches a
> public `main`.

# Where this library sits in a Kosli control

A policy library is only useful if it fits the pipeline that runs it. This
describes that pipeline as it actually works for control 43 (`RCTLDEF0000043`,
source code review / four-eyes), what each stage owns, and the three constraints
at the seam where `kosli.evidence` would plug in.

Two identifiers appear throughout and they belong to different schemes.
**SDLC-CTRL-0007** is Kosli's [published control
catalogue](https://sdlc.kosli.com/controls/release/code_review/) — the
requirement: *all code changes reviewed by a peer who is not the author, before
merging to a protected branch, with evidence linked to the artefact*.
**RCTLDEF0000043** is a customer's own control register — an implementation of
that requirement. Control 43 is therefore not a different control from 0007; it is
0007 realised, which is why its subject is a code change and why every commit must
pass.

Control 43 is the worked example because it is, today, **the only Rego policy in
`sdlc-workflows`** — every other control is still workflow wiring. That fact
shapes the conclusion, so it's stated up front rather than buried.

One more status fact belongs up front, because earlier revisions of this file
called `four-eyes.rego` "the production policy" and that was wrong.
**`four-eyes.rego` is a bespoke Rego rewrite of control 43, and it is
itself running in shadow mode — it is not deciding anything yet.** Where this
file needs to distinguish it from `examples/control_43.rego`, it names the file
rather than claiming a deployment status. That also means an evidence pass run
alongside it is one shadow evaluation beside another, which is still worth doing
and is not the same claim as comparing against a live gate.

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

**And that separation is also what created the requirement this library answers.**
The legacy generation produced the spreadsheet directly. The Rego generation gave
that up and put nothing in its place: `{allow, violations}` has no columns, so
Excel reporting — which is how compliance is actually reported — has nothing to
read. A uniform report per control is how it comes back, once, instead of one
bespoke exporter per control. This is the founding requirement, and it
predates the library.

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
use this library today), bespoke and running in shadow mode rather than
gating. Three rules, ordered so the first match settles a commit:

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

Three constraints at that seam. An earlier version of this file called them
"specific to the `kosli evaluate` door" and treated them as avoidable. They are
not: control 43 goes through that door, so all three are **live**.

| constraint | cost |
| --- | --- |
| `violations` must stay **one string per failing commit** | this library emits a row per (subject, check), so the policy must collapse them by a declared precedence: missing attestation → no PR → unverifiable identity → no approval |
| `allow` must stay a **bool** | free — `report.compliant` already is one |
| the package must be **`policy`**, and it is parsed as a single module | *not* free, as it turns out — the library cannot be imported and must be merged in with its public API renamed |

The first is arguably an improvement rather than a tax: precedence becomes stated
data instead of an emergent consequence of how rule guards happen to be ordered.

## Both questions, answered

These two sat open for three rounds, routed through briefs to the restricted
machine. They never belonged there: `kosli evaluate` is Kosli's own CLI, it was
already installed locally, and the answers were in `--help`, the binary, and
`kosli-dev/cli` on GitHub. Worth remembering before the next brief — sort open
questions into "needs the restricted machine" and "needs a terminal" first.

### 1. `--policy` takes one file, and only one module is parsed

The flag is `string`, not `strings` (contrast `--attestations strings` beside it).
And `internal/evaluate/rego.go` parses that file as a **single module** whose
package must be exactly `data.policy`:

```go
rego.Query("data.policy.allow"),
rego.Module("policy.rego", policySource),
```

So `kosli.evidence` cannot be imported at all on this path. It has to be textually
merged into `package policy`, which fails on the first attempt:

```
rego_type_error: conflicting rules data.policy.report found
rego_type_error: conflicting rules data.policy.violations found
```

The `violations` collision is structural rather than unlucky: the CLI **reserves**
that rule name, and this library has a function of the same name. Same package,
same name, different arity — rejected.

Namespacing the library's public API on merge fixes it. Verified end to end: a
concatenated `library.rego + control_43_ops.rego + control_43.rego` with the
library's `report`/`violations` renamed compiles under `opa check --strict` and
evaluates to `allow: true`, `violations: []`, and a 10-row report. So it is a build
step, not a wall.

### 2. The report does **not** survive `kosli evaluate`

The CLI's result type is the whole story:

```go
type Result struct {
	Allow      bool
	Violations []string
}
```

It runs exactly two queries — `data.policy.allow`, which must be a bool or it is a
hard error, and then, **only when allow is false**, `data.policy.violations`.
Nothing else in the policy document is read. `report` is still computed; it is
simply never asked for.

One trap: `collectViolations` does `if s, ok := v.(string); ok` with **no else
branch**. A non-string element in `violations` is silently dropped, not rejected —
so a policy that puts an object or a number in that set gets back fewer entries
than it produced, with nothing said about it.

**Read that precisely, because the distinction is load-bearing.** It is
*non-strings* that vanish, not structured data as such. A JSON document encoded
*as a string* passes through untouched, which leaves `violations` usable as a
carrier for the whole report — see [The third path](#the-third-path-an-evidence-pass-that-abuses-violations).
An earlier version of this file said flatly that smuggling structured data through
`violations` fails quietly, which reads as a closed door and is wrong.

## One door, not two: control 43 goes through `kosli evaluate`

For three rounds this file said control 43 ran the `opa` binary itself, via
`execSync` in a prebuilt Docker image, and built a conclusion on it: that the
whole evidence report was already reachable on the path the team used, and that
the `kosli evaluate` constraints were someone else's problem. **That is wrong.**
Round 5 read the workflow. The evaluation step is:

```sh
kosli evaluate trails <SHAS…> \
  --attestations "<pr-name>,initial-commit-by-verified-committer" \
  --flow <flow> --no-assert --output json \
  --policy four-eyes.rego
```

`kosli evaluate` appears in **exactly one place** in `sdlc-workflows`, and there is
**no `opa`-binary invocation anywhere** — the only `execSync` hits are git test
helpers. The verdict is read with `jq -r '.allow'`, and `--no-assert` means the
exit code is not the gate, `.allow` is. The whole result JSON is then re-attested
as a generic user-data attestation.

Four consequences, in order of how much they change:

**1. The three constraints are live, and the bundler is the load-bearing
artefact.** `--policy` takes one file, parsed as a single module that must be
`package policy`, so `fieldkit/bundle.py` is not a curiosity for a path nobody
walks — it is how this library reaches production at all. Good thing it verifies
each bundle behaviour-identical, and good thing the bundle has been run through
`kosli evaluate` end to end.

**2. The report does not come out of this door**, and there is no `opa` binary in
the image to open another. `kosli evaluate` runs exactly two queries —
`data.policy.allow` and, on a denial, `data.policy.violations` — and that is still
true on `main` at v2.39.x, so it is not a version problem. Everything else the
policy computes is computed and discarded. **This is the single blocker on the
evidence report reaching production.** Three ways past it, and the third was
missing from this file for longer than it should have been:

1. **Get the CLI to surface more** of the policy document than two rules — a third
   field on `Result`, or `--output json` returning the document. This is the real
   fix, and it is smaller than it sounds: OPA is *already* in production, linked
   into the `kosli` binary as a Go library (`internal/evaluate/rego.go`). The ask
   is to expose one more query on a document the CLI already evaluates with an
   engine it already carries, not to ship a new dependency.
2. **Add `opa` to the image** (one static binary) and run the bundle over the
   captured input document a second time.
3. **Carry the report out through `violations`** as encoded strings, which needs
   neither of the above. It is a hack, it works, and it is written up below.

1 is the destination and 2 is the pragmatic middle, but both need somebody else to
change something — the CLI's release cycle, or the image. 3 needs nothing, which is
its entire merit.

**3. The pipeline is already shaped for the second evaluation.** The control's own
README says the input document is produced with `kosli evaluate trails …
--show-input`, so the document an evidence pass needs is *already captured by
the workflow*, and the result JSON is *already re-attested*. Nothing new has to be
plumbed: one more evaluation over bytes that already exist, and the attestation
that already happens carries the report instead of `{allow, violations}`.

**4. `--attestations` is passed with plain, comma-separated names** — the PR
attestation plus `initial-commit-by-verified-committer`. So enrichment is
deliberate, not incidental, and only those two attestations survive the filter.
A policy reading a third would find nothing and fail closed.

The CLI in the image is **at least 2.18.0**: `--no-assert` does not exist in
2.17.0 and appears in 2.18.0. That matters because `kosli evaluate input`
(evaluate a captured document locally, no API call) and `--params` (populate
`data.params`, which `examples/control_43.rego` already reads for its
web-flow patterns) both predate 2.18.0 — so both are available on that
image today, without a CLI upgrade. Neither is in 2.13.1, which is what is
installed here.

What survives of the old framing: a gate returning a boolean is still correct, and
pushing evidence through a gate is still the wrong *design*. What does not survive
is the idea that a wider door was already open — and, as the next section admits,
the difference between a wrong design and an unavailable one is worth a hack when
the alternative is no evidence at all.

### The third path: an evidence pass that abuses `violations`

**This is a hack. It is written down because it works and because it is the only
option that needs nothing from anybody else, not because it is good.**

The lever is the precise shape of the trap above: `violations` is `[]string`, and a
string survives the collector intact. So a JSON-encoded report row is a legal
element. The second query runs **only when `allow` is false**, so the evidence pass
has to fail on purpose.

Two calls over one bundle, the mode chosen by `--params` rather than by a second
policy file — `--params` populates `data.params`, is confirmed present on that
image, and the policy already reads it:

```rego
evidence_mode if data.params.mode == "evidence"

allow := report.compliant if not evidence_mode
allow := false if evidence_mode                 # forces the second query

violations := <the human messages> if not evidence_mode
violations := <report rows, one JSON string each> if evidence_mode
```

```sh
# A — the gate, byte for byte what the workflow runs today
kosli evaluate trails <shas> --policy bundle.rego --no-assert --output json …   | jq -r '.allow'

# B — the evidence pass, whose verdict is meaningless and ignored
kosli evaluate trails <shas> --policy bundle.rego --params @evidence.json   --no-assert --output json … | jq '.violations | map(fromjson)' > report.json

kosli attest custom --type evidence-report --attestation-data report.json …
```

Nothing is projected away: every row, passing and failing, with its `cause` and its
echoed inputs, comes back through the round-trip. `violations` is the pipe, not the
payload.

**One row per string, and that is forced rather than stylistic.** `violations` is a
Rego *set*, so what arrives is canonically sorted, not meaningfully ordered.
Chunking one large JSON document across elements would reassemble in the wrong
order. Rows survive because each already names its subject and check; the report's
top-level fields (`compliant`, `requirements[]`) need their own element.

What makes it a tolerable hack: the gate path is untouched when `mode` is absent,
both calls share one bundle so there is no second artefact to drift, and the abuse
is confined to a branch that only fires when asked for. What makes it a hack: it
forces a denial nobody means, on a field with a published contract, because the only
other channel out of the policy is a boolean.

**All of this has since been checked against the CLI source and by running it —
see [What the CLI and server sources settled](#what-the-cli-and-server-sources-settled).**
The short version:

- **`violations` is not capped.** 50,000 rows and 16.4 MB came back intact, and
  `collectViolations` has no bound in source. This was the question that could have
  killed the approach, and it does not.
- `--params` and `--no-assert` behave as written above. One correction: stdout
  carries the full JSON *with or without* `--no-assert`, because the printer runs
  before the deny error — the flag keeps a forced denial from failing the workflow
  step, which is still a reason to pass it, just not the reason given.
- **`--show-input` does not help here**, and it is worth saying so because it looks
  like it should. It adds the *input document* to the response; the report comes out
  through `violations`. The two calls above are the gate and the evidence pass —
  one must report the real verdict, the other must force a denial — so nothing
  merges them. Where `--show-input` earns its keep is the `opa`-in-the-image route,
  which needs exactly that captured document. Its only use to the hack is optional
  provenance: storing *what was judged* beside the report without a third call.
- Call B's output still must not land where call A's does.
  `four-eyes-result-schema.json` expects one human-readable string per failing
  commit, so the evidence pass needs its own attestation name.
- Two full evaluations per gate remains the real cost, the second pure overhead on
  the happy path.

## What the CLI and server sources settled

Both repositories were read locally — `kosli-dev/cli` at `a5ecf036` and
`kosli-dev/server` at `d09be5998`. Between them they close the pivotal unknown
above, the payload limit that had been open since the report first had a
destination, and two of investigation 3's three questions. Where a claim was
*executed* rather than read, it says so.

### The evidence pass is viable: `violations` is not capped

`collectViolations` appends every string it finds with no bound, no truncation and
no size check. Confirmed by running it too: **50,000 rows and 16.4 MB round-tripped
intact** through `--output json` on the installed 2.13.1, every element present,
growth linear. The only HTTP request in that path is the `GET
/api/v2/trails/{org}/{flow}/{trail}` that fetches the input — violations are
produced by a local OPA evaluation and marshalled locally, so no server limit
applies to them at all.

That resolves the question the previous section called pivotal. **The report can
leave through the existing door today**, with no image change and no CLI release.

Three assumptions underneath the hack also hold:

- **`--params`** takes a JSON object or `@file`, unmarshalled whole and mounted at
  `data.params` via `inmem.NewFromObject({"params": …})`. One flag, replace rather
  than merge — there is no merge semantics to design around.
- **`--no-assert`** resolves as `assertOnDeny() == !noAssert` and is mutually
  exclusive with `--assert`, exactly as assumed. Worth knowing that it is
  *narrower* than assumed: `PrintJson` runs **before** the "policy denied" error is
  returned, so stdout carries the complete JSON either way. `--no-assert` is
  exit-code hygiene so a forced denial does not fail the workflow step, not the
  thing that gets you the data.
- **`--output json`** emits `{allow, violations}` with violations in full, and
  `--show-input` adds `input` — and `params`, when both are set — to the **same
  document**. So one call can return the report *and* the input document it judged,
  which is better than the two the hack was written to need.

### The payload limit is 10 MB, and that is ~2,290 commits

`attest custom` sends **multipart/form-data**, with the payload in a `data_json`
field (`newAttestationForm`). That matters, because the server's `check_file_size`
middleware gates *only* multipart requests — so it does apply here.
`ApplicationSettings.MAX_CONTENT_LENGTH` is `10 * 1024 * 1024`; the middleware
checks the `content-length` header and then the actual body, returning 413 "File
size exceeds 10MB limit".

Measured against a real report from this library, control 43's five-check shape
costs about **4.6 KB per commit** once fixed overhead is amortised:

| commits | report | vs 10 MB |
| --- | --- | --- |
| 1 | 15 KB | 0% |
| 200 | 923 KB | 9% |
| 1,000 | 4.58 MB | 44% |
| 2,000 | 9.15 MB | 87% |
| 2,300 | 10.53 MB | **413** |

So the ceiling is around 2,290 commits per report — comfortable for an ordinary
release, reachable by a wide range. `--attachments` (the evidence vault) is the
documented way past it, and is why that fallback is worth keeping in mind rather
than dismissing.

### Investigation 3, answered by importing the server's own validator

Two of its three questions were *executed* — not by a live request, but by calling
the server's own code with the server's own libraries:

```
$ python -c "from bounded_schema_validation import schema_validation_errors; ..."
server module imported OK; deadline = 2s

--- report_ok      (compliant, 9 rows)   schema errors: NONE
    .compliant == true                                  -> True   status=True
    [.results[] | select(.check == "$well_formed" ...)]  -> True   status=True
    overall attestation status = all(parts) = True

--- report_fail    (failing, 14 rows)    schema errors: NONE
    .compliant == true                                  -> False  status=False
    [.results[] | select(.check == "$well_formed" ...)]  -> True   status=True
    overall attestation status = all(parts) = False
```

**The server would accept the shape, and the verdict is correct in both
directions.** Round 6 validated with a stdlib checker that enforced the `required`
lists and the `cause` enum but not the full draft; this is the real validator.

What that validator is: `jsonschema`, with `validator_for(schema,
default=Draft202012Validator)` — so `$schema` is honoured, and ours declares draft
2020-12. Two details that matter more for the next schema than for this one:

- Validation runs under a **single shared 2-second deadline**
  (`SCHEMA_VALIDATION_TIMEOUT_SECONDS`), applied to `pattern` and
  `patternProperties` only, deliberately shared rather than per-match so N
  catastrophic patterns cannot run N × the cap. `evidence-report.schema.json` uses
  neither keyword, so it is moot for us.
- `FormatChecker()` is **enabled**, so `format` is *enforced* rather than annotated,
  which is not jsonschema's default. Ours declares no `format`; a future schema
  adding `"format": "date-time"` would find it validated, which is worth wanting
  but not worth discovering by surprise.

A failure is not a generic reject: `validate_attestation_data` raises `BadRequest`
carrying a **per-path error map**, so a mismatch says which pointer failed and why.

### One sharp edge in the jq evaluation

The rules are evaluated as `jq.compile(rule).input(attestation_data).first()`, and
a part's verdict is:

```python
data["status"] = data["result"] is True
```

**Identity against boolean `true`.** A rule returning a *truthy* non-boolean — a
count, a non-empty string, an array — is `False`, silently. Both proposed rules
return real booleans and are safe, but anyone reaching for `.results | length` as a
rule will get a permanent failure with nothing to explain it. Overall status is
`all(part.status)`, so one such rule condemns the whole attestation.

Two more: `.first()` means **only the first output** of a rule is used, so a rule
producing a stream silently discards the rest; and unlike schema validation, jq
evaluation has **no timeout**. Rules are compile-checked at type-creation time, so
a syntactically invalid rule is a 400 then rather than a surprise at attest time.

`--summary` expressions are a separate path and carry none of this: they return a
display value of any type, and `evaluate` is written never to raise — a broken
expression logs a warning and yields `None`. So the proposed summary counting rows
whose `cause` is `ambiguous` or `absent` returns its number safely.

### What is still not executed

No HTTP request has been made to a deployed Kosli. Auth, routing, middleware
ordering and persistence remain unexercised; what is verified is the validation and
evaluation **logic**, by calling the server's own modules. The third question of
investigation 3 — does a real `kosli attest custom` of a report come back
compliant — is now the only part of it left, and it is a formality against a
writable flow rather than an open risk.

## Where the input document comes from — settled, by running it

This was the last "unverified, and now the most important gap" in the status list
below: every report so far had been computed from a constructed fixture.
`kosli evaluate` turns out to compose exactly the document the port needs, and it
does the composition itself — and round 5 then confirmed that control 43 uses
precisely this, its own README describing the input document as produced by
`kosli evaluate trails … --show-input`. So the mechanism below is not an
alternative on offer; it is the one in service.

The mechanism, from `cmd/kosli/evaluateHelpers.go` and `internal/evaluate/transform.go`
(**identical in v2.13.1 and on `main`**), per trail named on the command line:

1. `GET /api/v2/trails/{org}/{flow}/{trail}`.
2. `TransformTrail` — `compliance_status.attestations_statuses` arrives from the
   API as an **array** and is converted to a **map keyed by `attestation_name`**.
   Artifact-level attestations get the same treatment.
3. `FilterAttestations` — `--attestations` *limits* which entries survive (plain
   name for trail-level, `artifact.name` for artifact-level). It does not enable
   enrichment, and because it runs before the next step it also reduces the
   number of API calls.
4. `CollectAttestationIDs` then **one `GET /api/v2/attestations/{org}?attestation_id=<id>`
   per surviving `attestation_id`** (deduplicated; entries without one are
   skipped), and `RehydrateTrail` merges each attestation's own fields onto its
   status entry — *only where the key is not already there*, so status metadata
   wins a collision. A trail with n attestations therefore costs n+1 API calls.
5. The result is wrapped as `input.trails[]`, one whole trail object per name
   (`evaluate trail` wraps a single one as `input.trail`).

So the enriched entry is the union of the status metadata (`attestation_id`,
`attestation_name`, `attestation_type`, `is_compliant`, `status`) and the
attestation object (`pull_requests`, its own `git_commit_info`,
`schema_version`, `attestation_data`), and **`pull_requests` is reachable at
`compliance_status.attestations_statuses[<name>].pull_requests[]`**. The port's
`from: ["trails"]`, `id: ["name"]` and selector path are correct as written.

Two consequences the port was already built for, by luck or by instinct:

- The collection is a **map keyed by attestation name**, so a policy that reads
  it positionally breaks and one that keys on the name breaks the moment
  `KOSLI_ATTESTATION_NAME` changes. Selecting on `attestation_type` is the only
  stable address, and the library's requirement that a selector resolve over a
  map as readily as an array is load-bearing rather than a nicety.
- The map is keyed by name, so **two attestations of the same type coexist
  happily** — exactly the defect-3 shape. The selector fails closed on it and now
  says `cause: "ambiguous"` rather than being indistinguishable from a missing
  attestation.

Verified by running `kosli` 2.13.1 with `--host` pointed at a stub HTTP server on
localhost serving the two endpoints above, so the transformation is the installed
binary's own code path over synthetic values. The captured `--show-input` document
then went straight into the port:

```sh
kosli evaluate trails <sha> --policy allow-all.rego --flow f --show-input \
  --output json --host http://127.0.0.1:8777 --org o --api-token t | jq '.input' > input.json

opa eval -d src/library.rego -d examples/control_43.rego -d examples/control_43_ops.rego \
  -i input.json 'data.control43.output'
```

`allow: true`, no violations, ten rows. Deleting `author_username` from the PR
commit produces the identity message; adding a second `pull_request` attestation
under a different name produces the ambiguity message.

The whole chain then ran through the CLI as a gate, which is the one thing that
had only ever been `opa check`ed:

```sh
python3 fieldkit/bundle.py --policy examples/control_43.rego \
    --ops examples/control_43_ops.rego -o policy.rego

kosli evaluate trails <sha> --policy policy.rego --flow f \
  --host http://127.0.0.1:8777 --org o --api-token t
# RESULT:      DENIED
# VIOLATIONS:  Commit 1111111: a pull request commit has no linked GitHub account …
# exit 1
```

So the bundled library, merged into `package policy` with its API renamed, is
accepted by `kosli evaluate` and gates on the document that command composes
itself. `violations` comes back `null` rather than `[]` when `allow` is true —
the CLI only runs that second query on a denial.

**What this does not verify** is Kosli's response bodies — the stub served shapes reported from real
trails by the firewalled machine, not captured from the API here — nor which
document control 43's own workflow hands to `opa`, which is still a question for
its workflow YAML.

## What real data said about the fields

From the firewalled machine, against real trails and PR attestations. Field names
and types only, no values.

- A `pull_request` attestation carries `pull_requests[]` as a **sibling of
  `git_commit_info`**, each entry holding `url, state, author, title, created_at,
  merged_at, head_ref, merge_commit`, `approvers[] {username, state, timestamp}`
  and `commits[] {sha1, message, author, author_username?, branch, timestamp,
  url}`. `schema_version: 2` and `is_compliant` sit on the attestation.
- **`git_commit_info` is at both levels**, corrected in round 5: trail root *and*
  on the attestation. The first field report had it only on the attestation, which
  is what sent me looking at the port's exemption path — see the fail-open in
  [the port section](#the-port-and-what-parity-measured), which is real but
  narrower than "no `git_commit_info` at all". The attestation-level copy notably
  carries `author` but **no `author_username`**.
- **The attestation type of a custom type is `custom:<name>`.** Built-in types are
  bare — the server's own model has
  `Literal["generic", "junit", "snyk", "pull_request", "jira", "sonar"]` — while a
  custom type reference is constrained to `^custom:.*$`, and a type *name* may not
  contain a colon. Three forms were in circulation for the same field (`custom`
  plus a name, `custom:<name>`, and the bare name); this is the one Kosli emits,
  and the port had one of the other two. See the port section.
- **All timestamps are numeric epoch** (floats). `compare_time` accepting epoch
  numbers is therefore not a convenience; RFC3339 parsing would simply be wrong
  here.
- **`author_username` on a commit is optional and unstable.** Present on every
  commit of one real PR, absent on a `noreply`/web-flow commit of another — an
  n-of-N field, which is the fail-closed hazard the trip set out to find. Two
  causes are indistinguishable at the value level: never resolvable (bot,
  web-flow, Copilot — the intended exemption) and *was* resolvable and no longer
  is (a deleted GitHub account; hypothesised, not observed in sample).
- **The git `author` string is the discriminator**, not the null: it stays
  `Name <email>` either way, which is why the exemption matches on it. Confirmed
  by removing `author_username` from a real-author commit: `identities_resolved`
  fails and the trail is denied. Fail-closed, in the direction we want.
- A design note worth keeping: identity that depends on mutable external state
  (a GitHub account that can be deleted) is a **weak subject**. Where the data
  allows, an account-independent anchor — a verified committer, a signature — is
  the better thing to hold responsible.

Still untested on real data: a **pull request with two distinct authors**. Both
real PRs were single-author, so the per-author rule (`every author ∃ approver ≠
author`) has met only synthetic input; the port's suite covers it in
`test_multi_author_cross_approval_passes` and its negative twin. Generating a real
two-author PR needs write access to a real repository, so it stays open here.

## What the field report asked the library for, and what it got

Three asks came back from the port meeting real data. Two are now vocabulary; the
third turned out to be asking for the wrong thing.

**1. Substitute evidence — a check discharged by something other than its primary
evidence.** `four-eyes.rego` lets a compliant `custom:initial-commit-by-verified-committer`
attestation stand in for the pull request requirement on a repository's root
commit, which no pull request could ever have reviewed. The port had no equivalent
and false-failed the initial commit with "no PR found". Any named check may now
declare a **`substitute`**, and the four PR-dependent checks of `commit_reviewed`
declare the same one. The row says `cause: "substituted"` and echoes the evidence
that discharged it, which is why this is a substitute rather than an `applies_to`
exemption: out of scope produces no evidence at all, and here there is evidence,
just not the usual kind.

**2. A row-level cause discriminator.** Rows now carry
`cause ∈ {satisfied, substituted, ambiguous, unmatched, absent, null, value}`.
This was independently reinvented by `four-eyes.rego`, which emits four
distinct reasons and uses a separate `any_pr_fully_approved` rule to keep "no
approval" apart from "unresolvable author" — and it closes the port's own worst
message. `pr_attestation_present` used to render "missing **or ambiguous**",
because a selector that matched nothing and a selector that matched twice both
echoed `null`; they are now two messages, and they send someone to two different
places.

**3. A `resolved-or-exempt` identity operator.** Not added — the ask diagnosed the
wrong blocker. The disjunction it wanted (`author_username` is a non-empty string,
*or* the git author matches an exemption pattern) was already expressible as
`any_of`; what actually forced `identities_resolved` to be a custom op was
**nesting depth**: every commit of every pull request is two levels of collection
and the vocabulary stopped at one. So the library gained `each` — a one-level
projection on `all`/`any` — and let their element check be an `any_of`. Together
those express the check as data:

```rego
"identities_resolved": {
	"op": "all",
	"path": pull_requests,
	"each": ["commits"],
	"check": {"op": "any_of", "options": {
		"linked_account": [{"op": "non_empty_string", "path": ["author_username"]}],
		"web_flow": [{"op": "matches_any", "path": ["author"], "patterns": service_account_patterns}],
	}},
	"substitute": verified_initial_commit,
}
```

A narrower bespoke operator would have replaced one custom op with one operator
nobody else could use, and left the nesting limit where it was. This removes the
custom op outright, renders its own expression instead of a hard-coded string,
and puts the exemption's discriminator in the report where a reader can see it.
`control_43_ops.rego` is down to the four-eyes condition itself, which relates
approvers to commit authors across two collections and remains the escape hatch
working as intended.

> **Superseded on 2026-09-07, and the reasoning is worth keeping anyway.**
> `four-eyes.rego`'s branch made identity resolution a disjunction of two quantifiers —
> every commit of *this* pull request resolves, or every approver of it does — and
> `any_of` cannot say that: its option groups hold leaf checks, and both sides
> quantify over a collection. So `identities_resolved` went back to being a custom
> op, and `control_43_ops.rego` hosts two.
>
> The honest read is that the ask above diagnosed the blocker correctly for the
> policy as it stood and the vocabulary is one feature short of the policy as it
> is now: an `any_of` group that may hold a quantified check. Rego's ban on
> recursion means that cannot be done by widening `any_of_passed`, since it would
> reach `element_passed` and come back round — it needs a separate non-recursive
> path for a quantifier whose own element check is a leaf. That is a real feature
> and may well be the right one; it was not worth taking on inside a drift fix.
>
> Declaring it per pull request also fixed something the `all` form had wrong.
> Flattening `pull_requests` × `commits` demanded that every commit of *every*
> pull request resolve, where `four-eyes.rego` asks only that *some* pull request
> satisfy identities and approval together — which is the "one honest divergence"
> admitted further down this file, now closed.

One behaviour tightened in passing: the custom op treated a pull request with an
**empty** `commits` array as "every commit checks out". `each` requires every
collection on the way down to be non-empty, so that now fails closed.

## Where the report goes: a custom attestation type

Kosli has a purpose-built home for exactly this shape, and it inverts the problem
in the library's favour. **There is also already a precedent inside control 43**,
which round 5 found: `initial-commit-by-verified-committer` — the very attestation
the substitute reads — is itself a deployed custom attestation type, created with
`kosli create attestation-type … --schema … --jq …` and four `--jq` rules over
`.commit.*` (timestamp compliance, a committer-name prefix, signed, signature
accepted). So this pattern is not being invented for the report; it is being
reused, from the same repository, with the same CLI verb. The exact invocation is
in that repo's org-setup script.

```sh
kosli create attestation-type evidence-report \
  --schema schema/evidence-report.schema.json \
  --jq '.compliant == true' \
  --jq '[.results[] | select(.check == "$well_formed" and .passed == false)] | length == 0'

kosli attest custom --type evidence-report \
  --attestation-data report.json --name four-eyes-report \
  --flow <flow> --trail <trail>
```

With `kosli evaluate`, Rego computes a boolean, the CLI reads it, and the evidence
evaporates. Here Rego computes the **evidence**, Kosli stores and schema-validates
it, and compliance is *derived from the stored evidence* by jq rules. That is much
closer to what "hashable, attestable report" was supposed to mean than what this
document was previously aiming at.

The jq rules were checked against a real report rather than written from
imagination:

```
.compliant == true                                             => false
[.requirements[] | select(.satisfied == false)] | length == 0  => false
[.results[] | select(.check == "$well_formed" and .passed == false)] | length == 0  => true
```

That third rule earns its place: it separates *"the policy is broken"* from *"the
thing being judged is non-compliant"* at the attestation-type level — a distinction
this library already draws in `$well_formed` rows and previously had nowhere to
express.

Two smaller destinations exist for the same payload: `--user-data <file>` attaches
arbitrary JSON to any attestation with no schema and no evaluation, and
`--attachments` puts files in the evidence vault, which is the fallback if a report
outgrows a payload. The first is not hypothetical either — control 43 already
re-attests its whole `{allow, violations}` result as a generic user-data
attestation, so the slot the report would occupy is already in the pipeline,
carrying two fields where it could carry the evidence.

`kosli create attestation-type` also takes **`--summary "NAME=<jq>"`** (repeatable,
or `--summary-json`), which defines the entries shown for attestations of that type
in the Kosli UI; a type created without one falls back to the jq checklist. For
this report the useful ones fall straight out of the shape:

```sh
--summary "Compliant=.compliant" \
--summary "Failing=[.results[] | select(.passed == false)] | length" \
--summary "Unreadable=[.results[] | select(.cause == \"ambiguous\" or .cause == \"absent\")] | length"
```

The third is the one worth having: it separates *the evidence says no* from *the
policy could not read its inputs*, at a glance, in the UI — which is what `cause`
was added for.

`schema/evidence-report.schema.json` in this repo is the JSON Schema for the report
shape.

## What this means for the decision

Since all per-control work is stage 4, the library's bet is that stage 4 stops
being 200 lines of bespoke Rego and becomes a data declaration plus the occasional
custom op — so that the *next* control costs a day instead of a week.

**That bet cannot be tested with one control.** Porting control 43 alone would
swap a working policy for a different one with better evidence rows. The
measurement that matters is the marginal cost of control #2, which argues for
expressing a second, simpler control alongside 43 even roughly.

There is now a second, separable question, and round 5 sharpened it into
something answerable: **the evidence report cannot reach production through the
door control 43 uses.** `kosli evaluate` returns two rules and discards the rest,
so adopting the library as a *gate* is available today and buys better failure
messages, while adopting it as *evidence* means getting the report past a CLI that
reads two rules. Those are different decisions with different costs, and previously
they looked like one.

Three ways to do the second, set out in full [above](#2-the-report-does-not-survive-kosli-evaluate):
the CLI surfacing more of the document (the real fix, and a small ask since OPA is
already linked into the binary), `opa` added to the image, or the report carried
out through `violations` as encoded strings. The first two need somebody else to
change something; the third needs nothing and is a hack.

**The third is now known to work.** `violations` is uncapped, the payload limit is
10 MB (~2,290 commits), and a real report validates against the server's own
validator with the jq rules giving the right verdict both ways. So the sequencing
is no longer a question of feasibility: the hack is available immediately and buys
the evidence today, and the CLI ask is worth making anyway so that the hack can be
deleted rather than lived with. Nothing about adopting the library as a *gate*
changes either way.

## Four defects in the current policy

`four-eyes.rego` and its 37-test suite were obtained and run locally: **37/37
pass.** Four behaviours the suite does not cover were then probed directly. All
four are reproduced, not inferred. The policy files themselves are not committed
here — they belong to `sdlc-workflows` — so these are descriptions, not diffs.

**1. An approval whose timestamp is a string always counts as after the cutoff.**
`approved_approvers_after_cutoff` guards `is_string(a.username)` but never checks
`a.timestamp`, and Rego's `>` is total across types with numbers sorting below
strings. So `"1000005" > 1000010` is **true**. An approval that is semantically
*before* the latest commit satisfies the check, which is exactly scenario 8's
failure silently reversed. Probed with one commit at `1000010` and an approval at
`"1000005"`: `allow` is true, zero violations.

**2. A commit with no timestamp cannot raise the cutoff.**
`latest_commit_ts` is `max({c.timestamp | some c in pr.commits})`, and a
comprehension skips elements whose body is undefined — so a commit missing
`timestamp` is silently dropped from the maximum. Push an untimestamped commit
after an approval and the approval still counts. Probed: commits at `1000000` and
one with no timestamp, approval at `1000001` → `allow` true, zero violations. (If
*every* commit lacks a timestamp, `max` of an empty set is undefined and the trail
fails closed, so this is a partial-data hazard only.)

Both of these are the class of bug this library removes by construction:
`comparable()` requires both sides present and of the same type before comparing,
and `compare_time` accepts two RFC3339 strings or two epoch numbers but never a
mixed pair.

**3. Two `pull_request` attestations on one trail crash evaluation.**
`pr_attest(trail)` is a function whose body is `some attest in …` selecting on
`attestation_type == "pull_request"`. Two matching attestations mean two return
values, and OPA raises `eval_conflict_error: functions must not produce multiple
outputs for same inputs`. Not a bypass — a hard stop — but reachable in normal
operation: the collector's attestation name is configurable via
`KOSLI_ATTESTATION_NAME`, so changing it and re-running leaves a trail carrying two
attestations of the same type.

This also settles a design question for any port. A path selector that requires
**exactly one** match and otherwise fails closed is strictly better behaved than
the current existential lookup, which errors.

**4. One commit can already produce two violation strings.**
The "one violation per failing commit" property is the *intent*, not a guarantee.
An unresolved `author_username` makes `all_authors_resolved` fail, which also makes
`any_pr_fully_approved` false, so the identity rule and the missing-approval rule
both fire. Verified on a single-commit trail with `author_username: null`:

```
Commit abc1234: no independent approval after latest code commit
PR …/pull/42: commit s1abcde has no linked GitHub account — identity unverifiable
```

Two strings, one commit. So this library emitting a row per (subject, check) is not
the departure it appeared to be — the existing policy already emits more than one
entry per commit, and consumers of `four-eyes-result-schema.json` already receive
that.

These four are worth passing to whoever owns `sdlc-workflows` regardless of what
happens to this library.

## The port, and what parity measured

`examples/control_43.rego` expresses the control as a `kosli.evidence` policy,
with `examples/control_43_ops.rego` supplying the one remaining custom operator
and `examples/control_43_test.rego` mirroring all 37 of the original's cases.

Parity was measured rather than asserted: both policies were loaded together and
run over the same 27 input documents, comparing `allow` and violation counts.

**It is asserted now.** `examples/control_43_parity_test.rego` feeds one corpus
of 23 cases to both policies and fails the moment their verdicts part without
an entry on a declared-divergence list, which is empty. `four-eyes.rego`
is vendored as `examples/four-eyes.vendored.rego` — body byte-for-byte,
renamed to `package four_eyes_vendored` because upstream's `package policy`
would otherwise merge with `examples/code_review.rego` rather than sit beside
it. It asserts **verdicts** only, leaving cause-level differences to
`control_43_test.rego` where they belong.

It cannot notice that the vendored copy has drifted from the `four-eyes.rego`
branch it cannot see, and on 2026-09-07 that is exactly what had happened — see [The
refresh of 2026-09-07](#the-refresh-of-2026-09-07-what-drifted-and-what-the-harness-could-not-see).
The harness caught one of the five verdict-level differences that had opened up;
the corpus was blind to the other four. It also carried, until that refresh, the
claim that the port's extra strictness was cause-level rather than verdict-level,
which was false when it was written. Both are worth reading as the limits of a
differential harness rather than as its failure: it proves the axes it varies
against the version it holds, and no more.

The corpus also gives the still-missing two-author pull request a home: when one
is finally captured and sanitised it drops in as a ninth case and both policies
judge it at once. The synthetic `two_author_mutual` case — each author approving
the other — already passes in both, which is where the per-author reading and
the "approver who authored nothing" reading would have parted company.

**24 of 24 ordinary cases agree.** The three that differ are the three defects
above — in each, the original allows or crashes and the port denies:

| case | `four-eyes.rego` | port |
| --- | --- | --- |
| approver timestamp is a string | `allow: true` | denied |
| a commit carries no timestamp | `allow: true` | denied |
| two `pull_request` attestations | `eval_conflict_error` | denied, with a row naming the check |

One further difference is a shape improvement rather than a verdict change. On an
unresolved identity the original emits **two** violation strings for one commit;
the port emits **one**, because precedence between failure reasons is declared as
data and the rows are collapsed through it. The port is closer to what
`four-eyes-result-schema.json` describes than the policy the schema was written
for.

What the port needed that the vocabulary didn't have: a **path selector**
(`{"where": {"attestation_type": "pull_request"}}`), added to the library, which
resolves identically whether attestations arrive as an array or a map, and
`not_matches_any` for the service-account exemption. Then, after real data was
read: `each` and an `any_of` element check (which turned `identities_resolved`
from a custom op into data), a `substitute` for the initial commit, and a
per-row `cause` — all three above. What still needs a custom op is the four-eyes
condition itself — approvers compared against commit authors across two nested
collections — which no operator over a single path can express. That is the
escape hatch working as intended.

The exemption was expressed as **scope**, not as a passing check: a
service-account commit produced a `$applies` row and no check rows, because it is
not in breach of four-eyes, it is not a subject of it.

> **The exemption no longer exists.** `four-eyes.rego` deleted it on the 2026-09-07
> branch, so there is no `applies_to` on `commit_reviewed`, every commit is a
> subject, and no commit produces a bare `$applies` row. The rest of this section
> is the history of a fail-open that was found and closed while the feature was
> still there — and the ending is better than it looks, because the filter that
> made it possible is the thing that got deleted. Read on for the hazard that
> expressing an exemption as scope creates; it is still the right warning for the
> next policy that wants one.

**That framing had a fail-open edge, and the field report is what exposed it.** A
scope filter fails *permissively*: a commit whose `git_commit_info.author` cannot
be read matches no exemption pattern, so `not_matches_any` fails, so the commit
falls out of scope — and with `min_subjects: 0` (there deliberately, so a release
of nothing but bot commits is compliant) the requirement went with it. A trail
with no author and no attestations was **allowed, with an empty report of
breaches**. Reproduced, then closed: `commits_present`, which declares no filter,
now asserts the author too, so an unreadable author is denied by a requirement
nothing can filter it away from.

Round 5 narrowed the trigger without removing the hazard. `git_commit_info` *is*
at trail root on a real enriched trail, so the reachable case is an author that is
present and unreadable — null, empty, or not a string — rather than a missing
object. The fix is the same one and the row costs the same either way; what
changed is that the fixture that found it was more pessimistic than `four-eyes.rego`.

Worth being straight about the direction: the original's early-exit exemption
fails *closed* here — an unreadable author matches no pattern, rule 1 doesn't
fire, and the commit goes on to need a pull request. Expressing an exemption as
scope buys better evidence and costs this hazard, which is why the README's
`matches_any` entry says to assert the field as a check as well. This is that
warning being paid for the first time.

The same pass closed a second hole in the message projection. `violations` is
keyed by a precedence table, and a check missing from that table produced no
message — so `commit_identified` could deny a trail while `violations` came back
empty, which is a denial nobody can act on. Both `commits_present` checks are in
the table now, and a test sweeps every check for a message.

One honest divergence: `identities_resolved` was a gating check here, while in the
original an unresolved identity in one pull request cannot deny a commit that a
*different* pull request fully covers. The port was stricter in that corner, and no
test in either suite exercised it. **Closed on 2026-09-07**: rewriting the check as
a per-pull-request custom op made it `some pr`, which is `four-eyes.rego`'s quantifier,
so the corner is gone rather than merely still unexercised.

The port has since moved with `four-eyes.rego` rather than staying frozen at parity: the
initial-commit substitute (`four-eyes.rego` gained it; the port false-failed without it)
and two messages where there was one. Parity as measured above therefore describes
the 37 cases, not the whole of either policy.

**One defect the port shipped with, and the only one caused from this side.** The
substitute selected the initial-commit attestation on
`{"attestation_type": "custom", "attestation_name": …}`. Kosli emits
`attestation_type: "custom:<name>"` for a custom type, so that selector matched
nothing, the substitute was inert, and every initial commit went on being denied
for want of a pull request — the exact bug the substitute was added to fix. It
passed its own tests because the fixture asserting it was written from the same
guess, in a stub API on this machine, rather than read from Kosli.

Settled from the server's own type model rather than by another round trip:
`CustomAttestationTypeRef` is constrained to `^custom:.*$`, built-in types are the
bare literals `generic | junit | snyk | pull_request | jira | sonar`, and a custom
type *name* may not contain a colon — so the type reference is already unique and
the attestation's own name (a flow-template slot label) is not what identifies the
evidence. `four-eyes.rego` had it right all along. The port now
matches on the type reference alone, and three tests pin the two wrong forms as
non-matching so the guess cannot come back.

The general lesson is sharper than the fix: **a fail-closed library still gets a
policy wrong when a selector cannot match**, because "no evidence found" and "the
address is wrong" both deny, and denying is the safe direction that hides the
mistake.

`cause` does not rescue this one, which is worth being precise about since it was
added to rescue exactly this class. Run against a root commit whose substitute
attestation carries the wrong type string, the row reads:

```
check:  pr_attestation_present     cause: unmatched
inputs: …attestations_statuses.[attestation_type==pull_request]                        = null
        …attestations_statuses.[attestation_type==custom:initial-commit-…].is_compliant = null
```

`unmatched` is true and useless here: it describes the **primary** path — there
really is no pull request attestation — and would say the same whether or not the
substitute's address were right. A row's cause describes the check's own paths by
design, so the substitute's read state survives only as that second `null`, which
is the very ambiguity `cause` exists to remove, one level over. Two things do catch
it: a fixture carrying the real type string, which is what should have existed;
and the operational tell that a substitute never once reporting `substituted`
across a whole report is a substitute nobody is reaching.

## The refresh of 2026-09-07: what drifted, and what the harness could not see

A colleague mentioned that `four-eyes.rego` moves faster on a branch than on the
`main` this repo had been reading. The file was hand-carried over — policy and
test suite, no revision, an unmerged branch that is expected to be released and
is treated here as **authoritative** on the owner's word. The vendored copy is
refreshed from it, its header records a content hash and the date because there
was no ref to record, and the previous capture is kept beside it in
`fieldkit/scratch/c43/four-eyes.aug24.rego`.

The port had drifted, in **five** ways that change a verdict. Each row was
measured by loading both policies and evaluating one input, not read off the diff:

| case | 2026-08-24 | branch | port, before | |
| --- | --- | --- | --- | --- |
| service-account trail, no PR | allow | **deny** | allow | port too permissive |
| human named `ali[bot]ce`, no PR | allow | **deny** | allow | port too permissive |
| sole approver is `ghost` | allow | **deny** | allow | port too permissive |
| unresolvable author, approvers resolved | deny | **allow** | deny | port too strict |
| unreadable trail author, good PR | allow | allow | deny | **port never agreed** |

The first four are upstream changes; the port was a faithful mirror of what was
captured in August and simply went stale. The fifth is the interesting one and it
is ours.

### The four upstream changes

**1. The trail-level service-account exemption is deleted.** `is_service_account`
is gone, its patterns' comment now says outright that they "do not exempt a trail
from the PR-review requirement", and six new tests pin bot commits as in scope —
including `test_svc_prefix_pattern_passes_with_pr`, the same commit passing once
it has a review. This is the largest change in the branch: a bot commit now needs
a reviewed pull request like anyone else.

**2. The patterns are anchored, which closed a real fail-open.** `svc_.*` became
`^svc_[a-zA-Z0-9_-]+ <[^>]+>$`, `.*\[bot\]` became `^.*?\[bot\] <[^>]+>$`, and bare
`noreply@github.com` became `^GitHub <noreply@github.com>$`. Unanchored, `.*\[bot\]`
matches a human called `ali[bot]ce` and `noreply@github.com` matches any author
string merely containing it — so a person could be waved through as a bot.
`four-eyes.rego` pins that with three tests. **This port carried the same hole**, and it
was not the port's own mistake so much as a faithful copy of one.

**3. `ghost` resolves to nobody.** GitHub replaces a deleted account with the
login `ghost`, and it is now excluded from approvers, from author resolution, and
from `_is_unresolved_username`. Before this the policy's comment claimed to handle
ghost users while the code tested only null and empty string. Note the asymmetry,
which is deliberate on both sides now: a ghost approver cannot satisfy four-eyes,
but a ghost *author* still needs somebody else's approval rather than dropping out
of the set needing review.

**4. One loosening, and it is worth putting to the owners of
`sdlc-workflows`.** `authors_resolved_or_approvers_resolved` tolerates an
unresolvable commit author whenever *every* approver resolves. The reasoning is
sound as far as it goes — a review whose reviewers are all identifiable is still
attributable — but the effect is that an unattributable commit passes four-eyes on
the strength of who reviewed it, which is a weaker claim than the control
otherwise makes. It is mirrored here to hold verdict parity, and flagged rather
than quietly adopted. It joins the four defects above as something to raise.

### The fifth: `author_recorded`, and a claim that was never true

`commits_present` asserted `git_commit_info.author`, and the parity harness's
declared-divergence list carried the comment that "the port's extra strictness is
cause-level, not verdict-level". **That was false when it was written.** Upstream
reads the trail's git author for nothing at all — not in the August capture and
not in the branch — so a trail with an unreadable author and a properly approved
pull request was compliant upstream and denied here, against *both* versions.

The check has been removed rather than declared as a divergence, and the reason it
can go cleanly is the same reason it existed. It was added to plug a fail-open in
the port's own scope filter: an unreadable author matched no exemption pattern,
failed `not_matches_any`, fell out of scope, and with `min_subjects: 0` took the
whole requirement with it. Change 1 above deletes that filter. The hazard the
check guarded is structurally gone, so the guard goes with it.

### What the harness caught, and what it did not

`test_verdicts_agree_across_corpus` fired on the first real refresh, which is what
it was built for. It caught **one** of the five.

That is the more useful finding. The other four were invisible to a corpus whose
eight cases all had a readable trail author, a resolvable approver and no bot in
sight. A differential harness is only as good as the shapes it thinks to vary, and
"we assert parity" quietly became "we assert parity on the axes we happened to
pick". The corpus is 23 cases now, and the additions are chosen by which changes
they can see rather than by what looked like a plausible trail:

- bot and service-account authors, with and without a review;
- the anchoring, twice — at trail level, and again at commit level where the
  patterns are *still used*, since with the exemption gone the trail-level cases
  no longer discriminate on it at all;
- `ghost` as sole approver and as author;
- an unresolvable author with approvers resolved and unresolved;
- an unreadable trail author and an absent `git_commit_info`, the two that
  exposed `author_recorded`;
- the initial-commit substitute, compliant and not — its first parity coverage.

Each of those five changes was then mutation-tested: unanchor the patterns, drop
the ghost exclusion, drop the approvers fallback, reinstate the exemption, empty
the corpus. All five are caught, and the anchoring mutation is caught **only** by
the commit-level case, which is why it is there.

### Two unwitnessed claims, corroborated from the consuming side

The branch's `four-eyes.rego` now carries the initial-commit substitute itself:

```rego
trail_compliant(trail) if {
	attest := initial_commit_attest(trail)
	attest.is_compliant == true
}

initial_commit_attest(trail) := attest if {
	some attest in trail.compliance_status.attestations_statuses
	attest.attestation_type == "custom:initial-commit-by-verified-committer"
}
```

That is the exact type string this port selects on and the exact place it reads
`is_compliant` — the status entry. Both were settled from Kosli's server source and
listed as never observed; they are still not observed *on the wire*, but a second
policy written by someone else now depends on them the same way. It also means
`four-eyes.rego` trusts the attestation's mere presence as the root-commit
discriminator, so the port's "a hand-run `attest custom` would fool this" caveat is
shared with `four-eyes.rego` rather than unique to the port.

## Control 1068's output contract — no schema, and one fail-open

Round 7 read the control's TypeScript to answer a question the 1068 round never
reached: does the implementation validate the data it produces? **It does not.**

- **No schema file and no runtime validation on the way out.** `Evidence` is built
  as an object literal, serialised with `JSON.stringify`, written to disk and
  fingerprinted. There is no `zod`/`ajv`/`joi`/`io-ts` anywhere in the control and
  no `*schema*.json` at all. TypeScript types erase at runtime, so the output is
  typed but unchecked. Where control 43 has `four-eyes-result-schema.json` fixing
  `violations` as a `string[]`, 1068's analogue — `non_permitted_tickets:
  Ticket[]` — is richer *and* unvalidated.
- **The one guard that exists is on the Jira response, not the payload.**
  `getBuildTicketFrom` throws on any missing `issuetype`/`summary`/`status`/
  `project` field, so a ticket missing the field the predicate reads becomes a
  failure rather than an `undefined` comparison. Fail-closed, by accident of
  input validation rather than output contract.
- **Shapes.** `Evidence { overall_status, jira_api_url, from_tag?, to_tag?,
  permitted_tickets[], non_permitted_tickets[] }`; `Ticket { ticketKey, parentKey?,
  ticketType, ticketDescription, ticketState, projectId, projectKey,
  jiraFixVersionAssigned?, parent? }`; `EvidenceFile { name, fingerprint (sha256),
  path }`, alongside a factstore `EvidenceManifest` from an external library.
- **Pass and fail differ in exactly one field:** `overall_status`
  (`PASSED`/`FAILED`), mirrored by the fact attestation's `controlStatus`. The
  ticket arrays differ in content, not shape.
- **No verbatim consumer in the control's own repo** — evidence renders to a PDF
  and to the GitHub Actions summary, both human-facing. Any factstore consumer is
  out-of-repo and therefore unknown, which is where a message-format break would
  hide if one exists.

`apidown` is the good news. Unlike four-eyes, **1068 fails when its evidence
source is down**: a per-ticket rejection lands in `notFoundJiraTickets` and thence
in `nonPermitted`, and even a total outage leaves `permitted == 0`, which
`isControlPassed` (`permitted > 0 && nonPermitted == 0`) denies. A port may copy
that structure safely. It is also the one hazard case **no test pins**.

**The one real fail-open is the 404-drop.** A rejected ticket is pushed to
`notFound` only if its message is *not* `JIRA_TICKET_NOT_FOUND`, so a 404 lands in
neither list and vanishes from validation entirely. A referenced ticket that was
deleted, mistyped into a 404, or hidden by permissions is neither validated nor a
violation: the release passes as if it had never been referenced. Every *other*
error — 400/401/403/409/422/5xx/network — is fail-closed. The drop is deliberate
and pinned by a test named "filter out the 404 tickets", and it is 1068's exact
analogue of the "we only look at what is present" shape that produced two
fail-opens in four-eyes. A commit whose message references no ticket is likewise
skipped silently; the control fails only if the whole range yields zero permitted.

Two consequences for this library. A port **cannot lean on 1068 having validated
its own output**, because it hasn't — the report's own `$well_formed` rows and
`schema/evidence-report.schema.json` are doing work that has no counterpart
upstream. And if the port is ever fed 1068 evidence, it must treat a dropped or
absent ticket as a **breach**, not trust `permitted_tickets` and
`non_permitted_tickets` to be jointly complete. They are not.

## After the demo: four threads worth pulling

The demo was given on 2026-09-08 and landed well. Four ideas came out of the
room. They are recorded here rather than in a slide because three of them are
claims that can be checked, and one of them now has been.

### Requirements as data, in a format that is not Rego — **verified**

The idea was YAML or JSON instead of Rego, to lower the barrier for people who
write controls but not policy code. It turns out to need **no library change at
all**: `requirements` is a plain object, and nothing inside it is Rego-specific,
so OPA can load it from a data document and the library consumes it unchanged.

`examples/prod_deploy_spec/data.yaml` is `demo/prod_deploy.rego`'s rule written
as YAML. `examples/prod_deploy_as_data.rego` is the entire policy that runs it:

```rego
report := evidence.report(input, data.prod_deploy_spec.requirements)
```

Over `demo/deployments.json` that produces a report **byte-identical** to the
Rego spelling — same nine rows, same `absent`/`value` split on `d-2`, same
rendered `expression` strings, and `violations` projects the same two breaches:

```sh
opa eval --ignore '*.json' -d src/library.rego -d examples \
  -i demo/deployments.json --format=json 'data.prod_deploy_as_data.report'
```

JSON behaves identically; OPA loads `data.yaml` and `data.json` natively, so
neither needs a build step. `examples/prod_deploy_as_data_test.rego` pins the
YAML's meaning in five tests, so this stays a fact rather than becoming a claim
nobody re-checks.

**Custom ops work from a YAML spec too**, which was not obvious and is the part
that decides how far the idea reaches. A custom op is contributed into `package
kosli.evidence` from a file of its own and dispatches on `check.op` — it never
references the policy. So a spec loaded from a data document reaches it exactly
as a Rego spec does, and the op file is a reusable library extension rather than
part of any one policy.

`examples/control_43_spec/data.yaml` is the proof, because control 43 is the
hardest control here and needs two of them. With `examples/control_43_ops.rego`
unmodified, it produces a report byte-identical to `examples/control_43.rego`'s
over `demo/trail_self_approved.json`, and
`examples/control_43_as_data_test.rego` pins the two specs as the same object —
so a change to the Rego spelling breaks the build until the YAML follows. That is
the parity harness's arrangement one level up, which is what makes keeping a
second spelling of a policy safe.

**What a data document still cannot carry**, which is the honest limit:

1. **Computation that builds the spec.** `examples/control_1068.rego` reads its
   flavour tables from `data.params` with a literal fallback, and "read from
   params, else default" is Rego, not data. Its `permitted_options` comprehension
   is only sugar — YAML could write the three options out literally — but the
   parameterisation is not. Control 43's YAML has the same hole: it holds
   `web_flow_patterns`' literal defaults and loses the `--params` override.
2. **The entry point and any output projection.** The four-line wrapper above,
   control 43's `check_priority` and its collapse to one string per commit, and
   1068's `permitted_tickets`/`non_permitted_tickets` lists.

Neither is a barrier to a front end. **The surface a non-Rego front end has to
generate is exactly the requirements object** — a real control's rule, custom
operators included — and everything around it stays a small Rego shim written
once per policy. This is a front-end project, not a library project.

### Markdown as the authoring surface — **verified**

The stronger version of the same idea: controls written as prose. It works, and
control 43 is written that way in `examples/control_43_md/policy.md`.

The argument that this is feasible *for this library specifically* is that the
library already goes the other way — `leaf_describe` and its callers render
prose from a spec, which is what a row's `expression` is. A Markdown front end
is that correspondence run backwards over a vocabulary of **thirteen
operators**: small enough to parse, and already carrying a canonical rendering
to check a parse against.

What distinguishes it from Gherkin/Cucumber and from Varar is that there is **no
user-defined translation layer** — no steps. Steps exist because those tools
target arbitrary code, an open semantic space. Here the target is closed, so
prose does not have to mean anything; it only has to select an operator and fill
its slots.

Two conventions carry the whole notation, and `authoring/GRAMMAR.md` is the
contract:

- **bold** is a declared property. A sentence is read as a rule *only* if it
  references one, which is what lets rationale say "must" as often as it likes
  without being parsed.
- `code` is a path, a literal, or an identifier.

Declaring the subject is not an extra burden: `A **commit** is each of
\`trails\`, identified by its \`name\`.` yields `subject_type`, `from` and `id`,
which the requirement needs anyway. The property table is what makes a real
control's paths sayable — control 43 addresses
`compliance_status.attestations_statuses[attestation_type=pull_request].pull_requests`,
which no prose survives inline, and which is written once and then called
**pull requests**.

`examples/control_43_md_test.rego` pins the result:

```rego
data.control_43_md.requirements == data.control43.requirements
```

So prose produces control 43's object exactly — two requirements over one
subject, selector paths, a substitute shared by four checks, and both custom
operators — and the report over `demo/trail_self_approved.json` is identical to
the Rego spelling's. The same holds for the toy policy.

**What a custom operator costs.** It needs `expression` and `inputs` on the
check, and `inputs` is too technical for prose, so `authoring/custom_ops.json`
holds them, keyed by operator and maintained beside the Rego that defines it.
This is the one place a step-like translation layer returns — **one entry per
operator**, not one per sentence, and two entries cover this repo.

**The transpiler has to be the validator**, because the library is not and
cannot be: every rule defaults to `false`, so a misspelled `op`, or a `values`
where the operator wanted `value`, produces a well-formed report in which the
check merely never passes. `--lint` checks any requirements object against the
closed vocabulary, including the hand-written YAML ones, and is worth having
independently of Markdown.

**Drift is caught by diff, not by heuristics.** Varar's answer to prose that
stopped matching is an amber marker, remembered out of band. Here the Markdown
compiles to a committed object, so a check that used to compile and no longer
does is a diff — `--check` fails the build naming what was lost. Reworded a rule
into a paragraph by accident and it reads as prose? The object says so. Deleting
a rule on purpose means committing the deletion, which is visible in review.

**The design constraint, unchanged:** Markdown compiles to the requirements
object, and the object remains what gets hashed and attested. If prose became
the source of truth for a verdict, the hashable-artefact property this library
exists to provide would be gone.

**What it does not carry yet.** A *requirement's* rationale. The report projects
a requirement as exactly `{require, satisfied, subjects, checks}`, so prose
attached to a requirement lives in the Markdown and never reaches the report —
and this is the biggest thing the Markdown surfaces and then fails to deliver,
since 60 of the 122 lines inside `control_43.rego`'s requirements object are
exactly that kind of comment. Carrying `description` through the requirement
projection is a small additive library change, and is the next one to make.

Prior art: **Varar** (<https://varar.dev>, Aslak Hellesøy), the successor to
Gherkin, presenting itself as documentation-as-executable-tests where each
Markdown paragraph runs as its own example. Its drift detection is the part that
mattered here — *"instead of silently dropping to prose (losing that test),
Varar flags it as drift"* — and it is the same problem as the fourth row of the
open-questions slide. The difference is that a committed compile target gives us
the memory it has to keep separately.

### Porting an imperative Rego policy: what it actually costs

Asked in the room, and answered there with "not really straightforward". The
repo has better evidence than that, because `examples/control_43.rego` **is** this
migration, from `four-eyes.rego`:

- 182 lines became 237 — 151 declared plus an 86-line custom op.
- The port found **four defects** in the original, including `"1000005" > 1000010`.
- But [the refresh of 2026-09-07](#the-refresh-of-2026-09-07-what-drifted-and-what-the-harness-could-not-see)
  found the port had drifted in **five** verdict-changing ways, of which the
  harness caught **one**. The original eight-case corpus was blind to the other
  four; it is 23 cases now.

The useful formulation is therefore neither "hard" nor "easy with AI". **The
translation is cheap, and AI makes it cheaper. The proof that the translation is
faithful is the expensive part, and it is the actual deliverable** — a vendored
copy of the original beside the port, one shared corpus, and a build that breaks
when they disagree. Our own history shows an eight-case corpus silently was not
enough. AI helps write that corpus too, and that is precisely the place its word
cannot be taken.

Stated that way it is a better pitch than "it's easy", because it ships with a
method instead of a promise.

### Open-sourcing the library

Raised as a way to lower the barrier to entry for the industry. The library core
is in good shape for it: `src/library.rego` is coupled to Kosli only by the
package name `kosli.evidence` and the `"kosli.evidence/absent"` sentinel key, and
`README.md`, `CONTRIBUTING.md`, `schema/evidence-report.schema.json`, the test
suite and the worked examples all already exist.

Two concrete blockers, neither of them technical:

1. **There is no `LICENSE` file.** That is a decision, not a task.
2. **This file, `DEMO.md` and the `fieldkit/` briefs name internal control
   identifiers, repository names and a customer's implementation.** The warning
   at the end of this file already says so; open-sourcing turns it from a caution
   into a prerequisite. The split is natural, though — `src/`, `schema/` and the
   toy examples carry none of it.

## Status of these claims

Sourced from control 43's `README.md` and `SCENARIOS.md`, and from a round of
investigation that read `four-eyes.rego`, its 37-test suite and the collector's
TypeScript on a machine with access to them.

- **Confirmed by running the policy locally:** 37/37 tests pass, and all four
  defects above were reproduced with probe cases rather than reasoned about.
- **Confirmed by reading source or running tests:** the per-author rule; the field
  names; epoch timestamps; identities being GitHub logins on both sides; the four
  mutually exclusive reasons; the five undocumented behaviours; 37 tests passing;
  the `allow` + `violations` interface and `policy` package; the schema's
  one-string-per-commit shape; `four-eyes.rego` being the only Rego policy in
  `sdlc-workflows`; control 43 having two generations.
- **Confirmed by reading the CLI's own source** (`kosli-dev/cli`,
  `internal/evaluate/rego.go`, `cmd/kosli/createAttestationType.go`) and by running
  `kosli` 2.13.1 locally: the `Result{Allow bool, Violations []string}` type; the
  two queries and their order; `allow` having to be a bool; non-string violations
  being silently dropped; `--policy` taking one file; `validatePolicy` requiring
  `package policy` on a single module.
- **Confirmed by running it:** the merge collision on `report` and `violations`,
  and that namespacing the library's API resolves it — the concatenated bundle
  passes `opa check --strict` and evaluates to `allow`, `violations` and a 10-row
  report. The jq evaluation rules were run against a real report with `jq`. The
  bundle has since been run **through `kosli evaluate` itself**, against the stub
  API: `RESULT: DENIED`, one violation string, exit 1. The gate works end to end.
- **Confirmed by dry-run only:** the custom-attestation path. `kosli attest custom
  --dry-run` shows the whole report travelling as `attestation_data` to
  `/api/v2/attestations/{org}/{flow}/trail/{trail}/custom`, but no request was ever
  sent. **Server-side schema validation and jq evaluation are therefore untested.**
- **Confirmed by running `--show-input`:** the wire shape of
  `attestations_statuses` — a map keyed by `attestation_name`, with each
  attestation's own payload merged onto its status entry, `pull_requests`
  included. Run against a stub API on localhost via `--host`, so the composition
  is the installed 2.13.1 binary's, over shapes reported from real trails rather
  than captured from the API here. The port evaluates that captured document
  correctly. See [Where the input document comes from](#where-the-input-document-comes-from--settled-by-running-it).
- **Confirmed against real trails, by the firewalled machine:** the
  `pull_requests[]` field names and types; epoch floats throughout;
  `author_username` being optional and unstable, with the git `author` string as
  the discriminator; `schema_version: 2`; `is_compliant` on the attestation; and
  that removing a real commit's `author_username` denies the trail. Field names
  and types only — no values crossed.
- **Confirmed by round 5, reading the workflow and the two policy sources:** that
  control 43 runs `kosli evaluate trails --policy` and **not** the `opa` binary
  (one call site in `sdlc-workflows`, zero `opa` invocations anywhere), with
  `--attestations` as plain comma-separated names, `--no-assert`, and the verdict
  read by `jq -r '.allow'`; that the result JSON is re-attested as generic
  user-data; that `git_commit_info` is at both trail root and on the attestation,
  the attestation copy carrying no `author_username`; that
  `initial-commit-by-verified-committer` is itself a deployed custom attestation
  type with a schema and four jq rules; and that control 1068's flavour-table
  membership is not in its source at all, being read from a fact store at runtime.
  The commit-to-ticket backref really is destroyed, so the limit test stands.
- **Confirmed by reading Kosli's server source** (`kosli-dev/server`,
  `src/model/types/types.py`): a custom attestation type is referenced as
  `custom:<name>` (`^custom:.*$`), built-in types are bare literals, and a type
  name cannot contain a colon. This settled the port's substitute defect without
  another round trip.
- **Inferred, and worth stating as an inference:** the CLI in control 43's image
  is at least 2.18.0, because `--no-assert` appears there and not in 2.17.0. That
  puts `kosli evaluate input` and `--params` in that image already.
- **Confirmed by round 6, reading the collector's source:** that the
  `initial-commit-by-verified-committer` substitute **cannot land on a non-root
  commit**. `getInitialCommitInfo` runs `git log --max-parents=0 --first-parent`,
  which by construction yields only the repository's true root commit; the
  attestation is written to a separate trail named after that root sha; the range
  loop skips the root sha, so the type is emitted exactly once; and the payload
  self-labels with `is_initial_commit`. This was the one open item that could have
  made the port **too permissive**, and it resolves in the port's favour. The
  caveat is that this is a property of the *collector*, not the policy — a
  hand-run `kosli attest custom --type initial-commit-by-verified-committer` on
  any trail would still fool a discriminator that trusts mere presence. Closing
  that would mean the port reading the payload's `commit.is_initial_commit`
  instead of trusting the type's presence.
- **Confirmed by round 6, locally rather than on the wire:** the report validates
  against `schema/evidence-report.schema.json` (draft 2020-12) in both directions
  — a compliant report (11 rows, every `cause` `satisfied`) and a failing one
  (7 rows, causes `absent` + `satisfied`), with every required key present and
  every `cause` inside the enum. Both proposed `--jq` rules evaluate correctly
  under the real `jq` binary, and the `$well_formed` rule is **not vacuous**: the
  library emits one real `$well_formed` row per requirement, so the rule found
  zero malformed rows rather than matching nothing. A report is ~16 KB at 11 rows
  for a single subject. The validator was stdlib rather than `jsonschema`, so it
  enforced the `required` lists and the `cause` enum rather than the full draft —
  a live server is still the real test of shape.
- **Confirmed by reading `four-eyes.rego`'s own 2026-09-07 branch**, hand-carried from a
  colleague's machine: that the trail-level service-account exemption is deleted;
  that the pattern set is anchored and matched only against a pull-request commit's
  git author; that `ghost` is excluded from every identity test; that an
  unresolvable commit author is tolerated when every approver resolves; and that
  the branch's own `four-eyes.rego` selects the initial-commit substitute on
  `attestation_type == "custom:initial-commit-by-verified-committer"` and reads
  `is_compliant` off the status entry. The capture is an unmerged branch treated as
  authoritative, pinned by content hash because it carried no revision.
- **Measured, not reasoned about, in the same refresh:** the five verdict-level
  differences that had opened up between the port and that branch, each by
  evaluating both policies over one input; that four were upstream drift and one
  (`author_recorded`) had never been in parity with *either* version; and that the
  eight-case corpus could see only one of the five. All five changes are
  mutation-tested, and the anchoring fix is caught only by the commit-level case.
- **Still open, needing live Kosli or GitHub access rather than either machine:**
  a real pull request with **two distinct authors** (both captured PRs resolve to
  one author or none, so the per-author rule has met only synthetic input); and a
  real root-commit trail, to *witness* on the wire what round 6 settled from
  source — that `attestation_type` reads `custom:initial-commit-by-verified-committer`
  and that `is_compliant` sits on the status entry as a boolean. Neither is a
  guess any more; both are unobserved — though as of the 2026-09-07 branch
  `four-eyes.rego` reads them the same way, which is corroboration from a
  second independent reader rather than observation on the wire. Round 6 confirmed the restricted machine
  cannot close them: no `kosli` binary and no mirror, and GitHub unreachable
  behind a proxy returning `407 CONNECT tunnel failed`. A live `kosli attest
  custom` of a report — **server-side** schema validation and jq evaluation —
  remains the one claim about the report's destination that has never been
  executed.
- **Settled from the CLI and server sources, and by running what could be run**
  (`cli@a5ecf036`, `server@d09be5998`): `violations` is **not capped** — 50,000
  rows and 16.4 MB round-tripped intact — so the evidence pass is viable and the
  report can leave through the existing door with no image change and no CLI
  release. The attestation payload limit is **10 MB**, from the multipart
  `check_file_size` middleware, which is about **2,290 commits** at control 43's
  measured 4.6 KB per commit. `--params`, `--no-assert` and `--output json` all
  behave as the evidence pass assumes, and `--show-input` folds the input document
  into the same response. Schema validation is `jsonschema` on draft 2020-12 with
  `FormatChecker` enabled and a shared 2-second deadline on `pattern` keywords;
  **a real report validates with zero errors and the jq rules give the right
  verdict in both directions**, executed against the server's own validator module.
  The jq status test is `result is True`, so a truthy non-boolean rule fails
  silently. See [What the CLI and server sources settled](#what-the-cli-and-server-sources-settled).
- **Also unverified:** `--summary`, which would render key report numbers in the
  Kosli UI, exists in the CLI source on `main` but not in 2.13.1.
- **Confirmed by running it, after the demo:** that a requirements object loaded
  from a YAML or JSON data document produces a report byte-identical to the Rego
  spelling of the same rule, with no library change — for the toy policy
  (`examples/prod_deploy_spec/`) and for **control 43 with both its custom ops**
  (`examples/control_43_spec/`), since an op file is contributed to `package
  kosli.evidence` and dispatches on `check.op` rather than belonging to a policy.
  Pinned by eight tests, one of which asserts the YAML and Rego spellings of
  control 43 are the same object. What stays Rego: computed specs, the
  `--params` fallback, the entry point and output projections.
  See [After the demo](#after-the-demo-four-threads-worth-pulling).
- **Confirmed by running it:** that **Markdown prose compiles to that same
  object**, with no user-defined translation layer. `examples/control_43_md/policy.md`
  is control 43 written as prose, and
  `data.control_43_md.requirements == data.control43.requirements` — selector
  paths, a shared substitute and both custom operators included. Six tests pin
  it. The transpiler (`authoring/`, TypeScript, a pure core plus a CLI shell)
  also validates the closed vocabulary, which the library cannot do for itself,
  and `--check` catches a rule that silently stopped compiling by diffing
  against the committed object. Not carried: requirement-level rationale, which
  the report has no field for.
  See [Markdown as the authoring surface](#markdown-as-the-authoring-surface--verified).

> This file names internal control identifiers and repository names. It is fine on
> an internal branch; it is worth a deliberate look before anything here reaches a
> public `main`.

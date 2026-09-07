# Demo script — `kosli.evidence`

**Audience:** engineers. **Budget:** 15 minutes. **Format:** slides for the
framing, terminal for everything else.

Every command below has been run in this repo; every output pasted is the real
output, not a reconstruction. Beats are timed, and
[If you're running long](#if-youre-running-long) lists what to drop first.

**Deck:** `demo/deck.html` in this repo, or
https://claude.ai/code/artifact/1cce815c-1250-445a-b9a1-af85a1a2a45e

`demo/deck.html` is the same deck as a **self-contained file** — no libraries,
no CDN scripts, nothing Claude-specific. Serve it locally and it is entirely
yours:

> **`demo/deck.html` is the source of truth for the slides.** The artifact URL
> is published *from* it (with the standalone `<head>` stripped, since the
> Artifact runtime supplies its own). Edit the file, not the URL.
>
> **This file and the deck are maintained separately — neither is generated
> from the other.** `DEMO.md` owns the script; `deck.html` owns the slides and
> their presenter notes. Four things appear in both and have to be changed in
> both: the 9-row report table, the 3-row defect table, the cost table, and the
> pasted command output. Everything else is independent.


```sh
python3 -m http.server 8000 --directory demo
# then open http://localhost:8000/deck.html
```

Serve it rather than double-clicking it. Browsers give a `file://` page an
opaque origin, which breaks the two-window sync below; over `localhost` both
windows share an origin and it works. A single window is fine from `file://`.

The only network fetch is Google Fonts (IBM Plex Serif / Sans / Mono). Offline,
every family falls back to Georgia / system-ui / a system mono, so the deck
still reads — it just looks plainer.

**Two-display setup.** Open the deck in **two** browser windows. On the laptop
one, press **`p`** — it becomes a presenter view: small slide preview, the
notes, the command to run, and what's next. Put the other window fullscreen on
the projector. Arrows in either window move both, over `BroadcastChannel` (a
browser API for messaging between same-origin tabs) with a `localStorage`
fallback. `p` is deliberately local, so the projector window never shows notes.

19 presented slides plus two appendix slides — a headline and at most one artefact each, so
the room listens instead of reads. `←` `→` to move; `n` toggles a presenter bar
carrying that slide's talking point and the command to run; the rail under the
stage jumps anywhere. **The prose lives here, not on the slides** — the
mapping from beats to slide numbers is in each beat's heading below.

The spine of the talk is one input document evaluated twice — once by
hand-written `four-eyes.rego`, once by this library — so the room sees the *same verdict*
with two different amounts of evidence behind it.

---

## Before you start

```sh
cd /Users/jbpros/Projects/rego-evidence-report
opa version && jq --version               # opa 1.19.0, jq-1.6+
opa test src examples --ignore '*.json'   # PASS: 410/410
```

The deck: `python3 -m http.server 8000 --directory demo`, then
http://localhost:8000/deck.html in two windows (`p` on the laptop one).

Two terminal tabs, large font:

- **tab A** — the toy policy: `demo/prod_deploy.rego`
- **tab B** — the real one: `examples/`, `demo/trail_self_approved.json`

Run each beat's command once before the room arrives. `opa` is fast, but the
first parse of `library.rego` is the slowest thing you'll do on stage.

---

## Beat 0 — What this is  ·  slide 1  ·  30s

> A Rego library for writing **control policies** that return a structured,
> hashable **evidence report**, instead of a bare `allow`/`deny` plus
> hand-written violation strings.

The unit is a **control policy**: one policy expresses one control, and the
library gives every one of them the same output shape. The library is 549 code
lines in `package kosli.evidence`, and the engine is OPA itself — nothing is
reimplemented.

---

## Beat 1 — Same output  ·  slides 2–3  ·  1.5 min, tab B

Control 43 (`RCTLDEF0000043`, four-eyes) is **the only Rego policy in `sdlc-workflows`** — every other control
is workflow wiring. 182 code lines, hand-written by colleagues working with the
customer, and **itself running in shadow mode rather than deciding anything
yet**. `examples/four-eyes.vendored.rego` is its body byte-for-byte with
the package renamed, so this runs the real thing.

The input is one commit, one merged PR — and **alice approved her own commit**:

```sh
cat demo/trail_self_approved.json
```

Run `four-eyes.rego` on it:

```sh
opa eval -d examples/four-eyes.vendored.rego -i demo/trail_self_approved.json \
  --format=json 'data.four_eyes_vendored' \
  | jq '.result[0].expressions[0].value | {allow, violations}'
```

```json
{
  "allow": false,
  "violations": [
    "Commit a1b2c3d: no independent approval after latest code commit"
  ]
}
```

**That is the right verdict, and a serviceable string.** Now the same input
through `examples/control_43.rego`, which expresses the same control with this
library, modelled per commit — same query:

```sh
opa eval -d src/library.rego -d examples/control_43.rego -d examples/control_43_ops.rego \
  -i demo/trail_self_approved.json --format=json 'data.control43' \
  | jq '.result[0].expressions[0].value | {allow, violations}'
```

```json
{
  "allow": false,
  "violations": [
    "Commit a1b2c3d: no independent approval after latest code commit"
  ]
}
```

**Identical** — same verdict, same string, byte for byte. Slide 3 stacks the two
outputs rather than setting them side by side, so the lines align and the
sameness is visible instead of asserted. The interface out is unchanged, so
stages 1, 2, 3 and 5 are untouched.

---

## Beat 2 — What the string can't say, and what the report says  ·  slides 4–5  ·  2 min, tab B

The room has just seen two runs agree to the byte. Slide 4 names what that
agreement doesn't buy you — what the string on its own can't carry:

- **Which** values it read is unknown. You can't recompute that verdict from the
  output — you can only re-run it. That's the difference between auditable and
  merely logged. The values themselves are not gone: `--show-input` dumps the
  input document, and control 43's workflow already captures it. The
  Q&A section below has the full distinction.
- The string is one someone wrote. To learn *why* it failed you re-read 182
  lines of Rego.
- **There's no record of what passed.** Nothing says the PR attestation was
  present, the PR was found, and the author's identity resolved cleanly — so you
  can't tell "reviewed by the wrong person" from "the collector never ran", and
  those go to different teams. Run it on a *compliant* trail and you get
  `{"allow": true, "violations": []}` — zero information, indistinguishable from
  a policy that read nothing and passed vacuously.
- Every control invents its own output shape, so nothing downstream is generic.

The interesting artefact was never the boolean — it's the table of evidence
behind it. Slide 5 is that table, from the same input, no new vocabulary:

```sh
opa eval -d src/library.rego -d examples/control_43.rego -d examples/control_43_ops.rego \
  -i demo/trail_self_approved.json --format=json 'data.control43.report' \
  | jq -r '.result[0].expressions[0].value.results[]
           | "\(.check)\t\(.subject.id // "—")\t\(if .passed then "PASS" else "FAIL" end)\t\(.cause)"' \
  | column -t -s$'\t'
```

```
$well_formed            —        PASS  satisfied
$well_formed            —        PASS  satisfied
$min_subjects           —        PASS  satisfied
$min_subjects           —        PASS  satisfied
identities_resolved     a1b2c3d  PASS  satisfied
independently_approved  a1b2c3d  FAIL  value
pr_attestation_present  a1b2c3d  PASS  satisfied
pull_request_found      a1b2c3d  PASS  satisfied
commit_identified       a1b2c3d  PASS  satisfied
```

One failure; the other five say what *was* verified — the attestation was there,
the PR was found, the identity resolved. Every bullet on slide 4 is answered by
the column beside it.

**This is the beat the whole talk rests on, and it needs no vocabulary** — the
room can just see it. Don't stop to explain the `$`-prefixed rows: they're the
library asserting on the *policy* rather than on the commit, and beat 4 covers
them. If asked, one line — two of each because this policy declares two
requirements, `commit_reviewed` and `commits_present` — then move on. Every
other check name reads as English.


---

## Beat 3 — Declare a policy instead  ·  slide 6  ·  3 min, tab A

The rule is declared as data: the things being checked, and the checks that
apply to them. `demo/deployments.json` — three deployments, one not in
production, one with no approver, one with a red CI check:

```sh
cat demo/deployments.json
```

```json
{
  "deployments": [
    {"name": "d-1", "environment": "prod", "approved_by": "bob",
     "ci_checks": [{"conclusion": "success"}]},
    {"name": "d-2", "environment": "prod",
     "ci_checks": [{"conclusion": "success"}, {"conclusion": "failure"}]},
    {"name": "d-3", "environment": "staging", "approved_by": "eve", "ci_checks": []}
  ]
}
```

The policy, which reads as one sentence: *every production deployment must have
a named approver and green CI.*

```sh
cat demo/prod_deploy.rego
```

Five things in that file:

1. **`subject_type` labels what a row judges.** It's the first field, and the
   easiest to skim past. Unlike the check definitions, it does *not* live once in
   the report's `requirements` block — it rides on **every row**, including the
   requirement-level `$well_formed` and `$min_subjects` rows, which carry
   `{"id": null, "type": "deployment"}`. That's what lets a consumer interpret
   rows without the policy, and it's why beat 5's message reads `deployment d-2`
   rather than bare `d-2`. Omit it and rows say `subject d-2` — a tell that
   nobody named the thing being judged.
2. **`requirements` is data.** An object. No rules, no loops, no `allow`.
3. **`from` vs `path` vs `id`.** `from` locates the collection in the *input
   document*; a check's `path` locates a field within *one subject*; and **`id`
   is the identity path within a subject** — where to look, inside one
   deployment, for the value that identifies it. It resolves to `subject.id` on
   every row, which is how a row points back at what it judged. The keyword is
   `id`; the path is whatever the data happens to call that field. Here it's
   `["name"]`, and `control_43.rego` also uses `["name"]` because a trail's
   identifying field is its `name` — which *is* the commit sha. That's why slide
   12's first input path reads `name`. If the path doesn't resolve, `subject.id`
   is `null` and the row still exists.
4. **`applies_to` is scope, not a check.** `d-3` is on staging, so it isn't in
   breach of a production control — it is simply not a subject of it.
5. **`ci_green` reaches into a nested array** with `all`. That's the shape
   of most real checks: every commit, every CI run, every approver.

Then run it:

```sh
opa eval -d src/library.rego -d demo/prod_deploy.rego -i demo/deployments.json \
  --format=pretty 'data.demo.report.compliant'
```

```
false
```

> **What you did not write:** no loop over deployments, no `allow` rule, no
> violation strings, no handling of the missing `approved_by`.

---

## Beat 4 — Read the report  ·  slides 7–10  ·  4 min, tab A

`d-1`, `d-2`, `d-3` are the three deployments' `name` fields — the path the
requirement's `"id": ["name"]` names. One subject is one deployment, and
`subject.id` is how a row points back at what it judged.

Two things worth knowing here. `d-2` has **no `approved_by` key at all**, which
is what `cause: absent` reports two beats from now. And "checks" means two
things: the policy's `checks` are the named assertions (`approved`, `ci_green`),
which is what `$well_formed`'s `count(checks)=2` counts, while `ci_checks` is
the deployment's CI runs. The fixture field is deliberately not called `checks`;
the README's own tutorial does call it that.

The rows as a table:

```sh
opa eval -d src/library.rego -d demo/prod_deploy.rego -i demo/deployments.json \
  --format=json 'data.demo.report' \
  | jq -r '.result[0].expressions[0].value.results[]
           | "\(.check)\t\(.subject.id // "—")\t\(if .passed then "PASS" else "FAIL" end)\t\(.cause)\t\(.inputs | map("\(.name)=\(.value|tojson)") | join(", "))"' \
  | column -t -s$'\t'
```

```
$well_formed   —    PASS  satisfied  count(checks)=2, require="every"
$min_subjects  —    PASS  satisfied  count(matching(deployments))=2
$applies       d-1  PASS  satisfied  environment="prod"
$applies       d-2  PASS  satisfied  environment="prod"
$applies       d-3  FAIL  value      environment="staging"
approved       d-1  PASS  satisfied  approved_by="bob"
ci_green   d-1  PASS  satisfied  ci_checks[].conclusion=["success"]
approved       d-2  FAIL  absent     approved_by=null
ci_green   d-2  FAIL  value      ci_checks[].conclusion=["success","failure"]
```

Nine rows from twelve lines of declaration:

- **Every row carries the value it read.** Row 8 doesn't say "failed", it says
  `approved_by` was `null`. **The verdict is recomputable from the row** — the
  property that makes this auditable rather than merely logged.
- **`cause` says what the value *means*.** Row 8 is `absent`; row 9 is `value`.
  Both failed; one means *no evidence was recorded*, the other means *the
  evidence is bad*. Different team, different fix. `passed: false` plus an
  echoed `null` cannot tell those apart — nor `null` from a selector that
  matched nothing (`unmatched`) from one that matched twice (`ambiguous`). Four
  problems that all echo as `null`, four different fixes.
- **The `$`-checks are the library asserting on your policy.** `$well_formed`
  catches a requirement that asserts nothing; `$min_subjects` catches a typo in
  `from` that would otherwise pass vacuously. Fail-closed by construction, not
  by remembering to be.
- **Passing rows are kept on purpose.** `d-1` passed both checks and there are
  rows saying so. "It was checked and it was fine" is evidence too — and it's
  the only thing that distinguishes a real pass from a policy that didn't look.
- **Row order is deterministic** and independent of how you wrote the policy
  object — most general question first, then subjects in input order. Two people
  writing the same policy with the keys in a different order get byte-identical
  reports. *That* is what makes it safe to hash and attest.

Rows 8 and 9 are the `absent`/`value` pair — the single most useful thing in
the report.

### The other half of the report — slide 8

The report has two halves, and everything above is one of them. Check
**definitions** live once per `(requirement, check)` pair under
`requirements[<name>].checks`; rows carry only what differs per subject:

```sh
opa eval -d src/library.rego -d demo/prod_deploy.rego -i demo/deployments.json \
  --format=json 'data.demo.report' \
  | jq '.result[0].expressions[0].value.requirements.prod_deploy.checks.ci_green'
```

```json
{
  "op": "all",  "path": ["ci_checks"],
  "check": {"op": "equals", "path": ["conclusion"], "value": "success"},
  "description": "Every CI check on the deployment passed",
  "expression":  "every ci_checks: conclusion == success"
}
```

Three things:

- **`expression` is rendered by the library** from the check spec. You didn't
  write it, and it's what makes a row interpretable without reading the `.rego`.
  You only write it yourself for a custom op, where the library can't derive it.
- **Definitions don't repeat per row.** A check run against 2,000 commits
  carries its description and expression once, not 2,000 times.
- **Look a check up by the pair, not the name.** Two requirements may reuse a
  name for unrelated checks.

Worth knowing what is **not** in there, if someone asks: `from`, `id` and
`min_subjects` appear nowhere in the report. So a consumer can recompute a
check's verdict, but can't tell where in the input the subjects came from or how
their identity was derived. Identity is in the report; provenance isn't. (There
is no subject definition block — subjects are described only by `subject.type`
on each row and the `subjects: {total, matching}` counts.)

---

## Beat 5 — Two functions  ·  slide 11  ·  1.5 min, tab A

The library has exactly two entry points, and the second takes the **report**,
not the input:

```rego
report  := evidence.report(input, requirements)   # 9 rows, 3 of them failing
breaches := evidence.violations(report)           # 2 breaches
```

Nine rows, three failing, **two** breaches. The row that gets dropped is the
interesting one:

| failing row | subject | a breach? | |
| --- | --- | --- | --- |
| `$applies` | d-3 | **no** | out of scope — never evaluated |
| `approved` | d-2 | **yes** | this subject breached this check |
| `ci_green` | d-2 | **yes** | this subject breached this check |

**A failing `$applies` is not a violation.** `d-3` is on staging: it isn't in
breach of a production control, it is simply not a subject of it. The row stays
in the report because "we looked at d-3 and it was out of scope" is evidence.

The full drop list, and why each:

| dropped | because |
| --- | --- |
| passing rows | nothing to answer for |
| `$applies` rows | out of scope is not in breach |
| rows of a **satisfied** requirement | under `require: "some"`, another subject met every check, so these clear it rather than convict it |

`$min_subjects` and `$well_formed` failures are **kept** — too few in-scope
subjects, or a requirement that asserts nothing, are real breaches. ("No
production deployment at all" is exactly what `$min_subjects` exists to report.)

```sh
opa eval -d src/library.rego -d demo/prod_deploy.rego -i demo/deployments.json \
  --format=json 'data.demo.breaches' \
  | jq -r '.result[0].expressions[0].value[]
           | "\(.subject.type) \(.subject.id // "(requirement-level)"): \(.check) — \(.description) [\(.cause)]"'
```

```
deployment d-2: approved — A named approver signed off on the deployment [absent]
deployment d-2: ci_green — Every CI check on the deployment passed [value]
```

Three properties worth naming:

- `evidence.violations(report)` is a **pure function of the report** — no input
  document, no policy — so it runs anywhere the report travels.
- **Selection is generic; wording is yours.** It returns structured entries and
  never a formatted string, because the message is the genuinely
  policy-specific part. The `deployment` in each line above is
  `subject.type` — declared once as `subject_type` back in beat 3, carried on
  every row, and read straight out of the row here.
- `allow := report.compliant` and `violations` are **independent derivations**.
  The verdict never reads rows, so a bug in a message projection can mislead but
  **cannot let a bad trail through**. That's also why the *report* is the
  hashable, attestable artefact and `violations` isn't.

---

## Beat 6 — Inside the failing row, and what parity found  ·  slides 12–15  ·  3 min, tab B

The failing row's `inputs`:

```sh
opa eval -d src/library.rego -d examples/control_43.rego -d examples/control_43_ops.rego \
  -i demo/trail_self_approved.json --format=json 'data.control43.report' \
  | jq '.result[0].expressions[0].value.results[]
        | select(.check=="independently_approved") | .inputs'
```

```json
[
  {"name": "name", "value": "a1b2c3d"},
  {"name": "…attestations_statuses.[attestation_type==pull_request].pull_requests[].approvers",
   "value": [[{"state": "APPROVED", "timestamp": 1000050, "username": "alice"}]]},
  {"name": "…attestations_statuses.[attestation_type==pull_request].pull_requests[].commits",
   "value": [[{"author_username": "alice", "sha1": "c0ffee1", "timestamp": 1000000}]]},
  {"name": "…attestations_statuses.[attestation_type==custom:initial-commit-…].is_compliant",
   "value": null}
]
```

The row carries the approvers, the commits, and — as that fourth entry — the
substitute it looked for and didn't find.

**Expect a question about the double brackets.** The check declares that input
as `{"path": pull_requests, "each": ["approvers"]}` — a projection, which the row
renders as `pull_requests[].approvers`. The **outer** array is one entry per
pull request (that's the `[]` in the name); the **inner** array is that pull
request's own `approvers`. This fixture has one PR with one approver, which is
why it collapses to `[[{…}]]`; with two PRs the outer array has two entries.

The nesting is load-bearing, not incidental. The rule is *some pull_request:
every author: some approver ≠ author*, so flattening the arrays would lose which
approver belonged to which pull request — and "some PR was fully approved" would
become unanswerable. A root commit has no parent to open a
PR against, so an initial-commit attestation can discharge the check instead.
Operational tell: a substitute that never reports `cause: substituted` anywhere
in a report is one nobody is reaching.

### Parity is a test, not a claim

```sh
opa test src examples --ignore '*.json' --run 'parity' -v
```

```
data.control43_parity_test.test_corpus_is_populated: PASS (11.803959ms)
data.control43_parity_test.test_verdicts_agree_across_corpus: PASS (416.495416ms)
PASS: 2/2
```

`four-eyes.rego` is vendored byte-for-byte next to the port, both are fed
one 23-case corpus, and the test **fails the moment their verdicts part**
without an entry on a declared-divergence list — which is empty.

### What that found

Over 27 input documents, **24 of 24 ordinary cases agree**. Three differ, and in
all three the original **allows or crashes**:

| case | `four-eyes.rego` | the port |
| --- | --- | --- |
| approver timestamp is a string | `allow: true` | denied |
| a commit carries no timestamp | `allow: true` | denied |
| two `pull_request` attestations | `eval_conflict_error` | denied, with a row naming the check |

Three of **four defects found and reproduced** — not inferred — in a policy
whose own 37 tests all pass. The fourth is one commit producing two violation
strings, which isn't a verdict difference, so it isn't in the table.

Each has its own mechanism:

1. Rego's `>` is total across types and numbers sort below strings, so
   `"1000005" > 1000010` is **true** and an approval semantically *before* the
   last commit counts. The library removes this class by construction —
   `compare_time` takes two RFC3339 strings or two epoch numbers, never a mixed
   pair.
2. `latest_commit_ts` is `max()` over a comprehension, and a comprehension skips
   elements whose body is undefined — so a commit with no `timestamp` is dropped
   from the maximum and cannot raise the cutoff.
3. `pr_attest(trail)` is a *function* selecting on
   `attestation_type == "pull_request"`. Two matching attestations mean two
   return values, and OPA raises `eval_conflict_error` rather than a verdict —
   reachable in normal operation, since the collector's attestation name is
   configurable via `KOSLI_ATTESTATION_NAME`.

### The cost

The port is **not shorter**:

| | hand-written | declared | custom op | total |
| --- | --- | --- | --- | --- |
| `four-eyes.rego` | 182 | — | — | 182 |
| `control_43.rego` | — | 151 | 86 | **237** |
| `control_1068.rego` | — | 61 | **none** | 61 |

Two reasons control 43 cannot measure the bet:

1. **It's the hardest control.** The four-eyes condition — approvers compared
   against commit authors across two nested collections — is the one thing no
   operator over a single path can express, so it needs the 86-line custom op.
   Most controls won't. That op is a one-time cost, not a per-control one.
2. **It already works.** Porting it swaps a working policy for a different one
   with better evidence rows. Real gain, but not a cost saving — and the numbers
   say so out loud.

> The bet is that per-control work stops being 200 lines of bespoke Rego and
> becomes a declaration plus the occasional custom op — so the *next* control
> costs a day instead of a week. **That bet cannot be tested with one control.**
> The measurement that matters is the marginal cost of control #2.

`examples/control_1068.rego` is the third row, and the early evidence for the
bet: 61 lines, **no custom op** — `any_of` covered it. Two caveats:

- It is a **design sketch, not a port.** Control 1068 has no Rego to port; its
  rule lives in TypeScript. So what's needed is a *second control*, not a second
  port — a greenfield one counts.
- It expresses **half the control.** The ticket half works; the commit-to-ticket
  half doesn't, because the collector flattens commit messages to a set of
  ticket ids and destroys the link before any evidence exists. **No policy
  language recovers a relation thrown away upstream.** That's a finding about the
  pipeline, not a gap in the library.

---

## Beat 7 — Where it plugs in, and the one blocker  ·  slides 16–17  ·  1.5 min

Five stages; four of them are control-agnostic:

```
COLLECTOR ──▶ KOSLI ──▶ kosli evaluate ──▶ POLICY ──▶ CONSUMER
gathers       records    builds input       decides    attests
```

**All per-control work is stage 4, and this library only ever touches stage 4.**
Stages 1, 2, 3 and 5 never learn about it — which beat 1 just showed, since the
interface out was byte-identical.

Where it stands:

> **As a *gate*, it works today.** Verified end to end: the bundle runs through
> `kosli evaluate` itself — `RESULT: DENIED`, one violation string, exit 1.
>
> **As *evidence*, it's blocked.** `kosli evaluate` runs exactly two queries —
> `data.policy.allow` and, on a denial, `data.policy.violations` — and discards
> everything else the policy computed. The report does not come out of that
> door, and there's no `opa` binary in the image to open another.

Three ways past it:

1. **The CLI surfaces more of the document.** The real fix, and a smaller ask
   than it sounds — OPA is *already* linked into the `kosli` binary as a Go
   library. One more query on a document the CLI already evaluates.
2. **Add `opa` to the image** (one static binary) and evaluate the captured
   input a second time. The pipeline is already shaped for it: the input
   document is *already* captured with `--show-input`, and the result JSON is
   *already* re-attested.
3. **Carry the report out through `violations`** as JSON-encoded strings. A
   hack. It works — `violations` is uncapped, the payload limit is 10 MB
   (~2,290 commits), and a real report validates against the server's own
   validator. Its entire merit is that it needs nothing from anybody else.

1 is the destination, 2 is the pragmatic middle, 3 is available this afternoon.

---

## Beat 8 — What we have not run  ·  slide 18  ·  1 min

Put this before the close, not after — end on the plan, not the caveats. Every
item is tracked in the repo, not remembered:

| open question | state | where |
| --- | --- | --- |
| the per-author rule on a real two-author PR | synthetic input only | `BRIEF_OPEN_QUESTIONS.md` inv. 1 |
| a real initial-commit trail on the wire | never observed | inv. 2 |
| server-side schema validation + jq of the report | dry-run only | inv. 3 |
| drift between the vendored copy and the branch | invisible to the harness | `INTEGRATION.md` |

Detail worth having, in the order someone will ask:

1. **The per-author rule is the core four-eyes behaviour and it has met only
   synthetic input** — both captured pull requests resolve to one author or
   none. The synthetic `two_author_mutual` case passes in both policies, which
   is exactly where the per-author reading and the "approver who authored
   nothing" reading would have parted company. So the corpus cannot settle it.
2. **The substitute has never met data nobody here wrote.** No real trail
   carrying `initial-commit-by-verified-committer` has been seen through
   `--show-input`. It already shipped one defect — matching `attestation_type`
   `custom` instead of `custom:<name>` — caught by reading the server's type
   model rather than by any test.
3. **The report's destination is dry-run only.** No HTTP request has reached a
   deployed Kosli, so auth, routing and persistence are unexercised. What is
   verified is the validation and evaluation *logic*, by calling the server's own
   modules.
4. **The harness compares against a vendored copy**, so drift in the
   `four-eyes.rego` branch is invisible to it. On 2026-09-07 it caught one of
   five verdict-level differences. That's the limit of differential testing, not
   a defect in it — and it's the argument for shadow mode.

If asked which of these would change the decision: **3 failing** would kill the
evidence path as designed, and **1 disagreeing** would mean the port isn't the
control. The other two are cost, not direction.

---

## Appendix — both reports, live  ·  slides 20–21  ·  on demand

**Not in the linear path.** They sit after the close, so you only reach them
deliberately: press `End` for A2, or click either of the last two ticks on the
rail. Then press `Home` (or the first tick) to come back.

Two slides, because the deck uses two policies and a question is usually about
one of them:

| | report | for questions about |
| --- | --- | --- |
| **A1** | `prod_deploy` on `demo/deployments.json` — 2.8 KB, 205 lines | the vocabulary, slides 6–11 |
| **A2** | `control_43` on `demo/trail_self_approved.json` — 14.8 KB, 506 lines | the spine, slides 2–5 and 12 |

**A2 is where `pr_attestation_present` and the rest of slide 5's check names
live.** They appear nowhere in A1, because A1 is a different policy — the toy
declares `approved` and `ci_green` and nothing else.

Both are embedded as collapsible trees, so a question about the structure gets
answered by opening it rather than described. Every collapsed node previews its first few
scalar fields, so a row reads as `4: {6} cause: value check: $applies passed:
false` without expanding it.

`Expand all` / `Collapse` are there for when someone asks to see everything;
fully expanded it's 3,500px of tree in a well that scrolls on its own.

Worth opening if asked:

| slide | open | to show |
| --- | --- | --- |
| A1 | `requirements.prod_deploy.checks` | definitions live once, with the rendered `expression` |
| A1 | `results` | nine rows carrying only what differs per subject |
| A1 | any row's `inputs` | the values echoed back, which is what makes the row recomputable |
| A2 | `results[5]` | the failing `independently_approved` row — the one slide 12 dissects |
| A2 | `requirements` | two of them, `commit_reviewed` and `commits_present`, which is why the `$`-checks appear twice |

A2 opens showing all nine rows without expanding anything, so
`independently_approved` / `cause: value` / `passed: false` is on screen the
moment you arrive.

Clicks and `space` inside a tree belong to the tree, not the deck — expanding
a node won't advance the slide. Each slide's `Expand all` / `Collapse` acts only
on its own tree.

The same documents from the terminal, if you'd rather:

```sh
# A1
opa eval -d src/library.rego -d demo/prod_deploy.rego -i demo/deployments.json \
  --format=json 'data.demo.report' | jq .

# A2
opa eval -d src/library.rego -d examples/control_43.rego -d examples/control_43_ops.rego \
  -i demo/trail_self_approved.json --format=json 'data.control43.report' | jq .
```

---

## Close  ·  slide 19  ·  1 min

Two decisions, previously mistaken for one:

- **Gate.** Available now. Buys fail-closed operators and better failure
  messages. Costs a port.
- **Evidence.** Needs one of the three doors above. Buys the hashable,
  attestable report — the thing an auditor can recompute.

Two next steps:

**1. Control 1068 — what a second control costs.** Correctness is already
settled; that was the parity harness. Cost isn't, and control 43 is the wrong
control to measure it on. 1068 is the candidate because the sketch already
exists: **61 lines, no custom op**, which is the shape the bet predicts. Two
things to have ready, since slide 15's third row invites both:

- It's a **sketch against synthetic input, not a port** — 1068 has no Rego to
  port, its rule is TypeScript.
- It's the **ticket half only**. The commit-to-ticket half needs the collector to
  stop flattening commit messages to a set of ticket ids. That's a collector
  change, not a library one, and it doesn't block the cost measurement.

**2. Shadow mode in the real workflow.** Run the port alongside
`four-eyes.rego` on real trails, comparing verdicts and gating nothing. Two ways,
both available on that image today (it's at least 2.18.0):

- a second `kosli evaluate trails … --policy bundle.rego --no-assert` call whose
  `.allow` is compared and logged but never gates the step; or
- `kosli evaluate input` over the document already captured with
  `--show-input`, which needs no API call at all.

This is the one gap the parity harness cannot close by itself: it compares 23
synthetic cases against a **vendored copy**, and cannot see that copy drifting
from the policy actually deployed. On 2026-09-07 it had drifted, and the harness
caught one of five differences. Shadow mode compares against real trails,
continuously, at no risk — because it decides nothing. Worth being precise in
the room: `four-eyes.rego` is itself in shadow mode rather than deciding
anything, so this is one shadow evaluation beside another.

Point at `README.md` for the vocabulary and operator reference,
`INTEGRATION.md` for the pipeline and the full status-of-claims list, and
`CONTRIBUTING.md` for anyone who wants to touch the library itself.

---

## If you're running long

Cut in this order. Beats 1 and 4 are the load-bearing ones.

1. **Beat 8 (open questions)** — the material is in `INTEGRATION.md` and
   `BRIEF_OPEN_QUESTIONS.md`, and the Q&A section below covers it if asked
   (saves ~60s). Keep it if anyone in the room owns the decision.
2. **Beat 6's `inputs` block** — the row table above it already makes the
   point (saves ~45s).
3. **Beat 7's three doors** — say "it's blocked, three ways past it, ask me"
   (saves ~50s).
4. **Beat 6's two control-1068 caveats** — keep the row on slide 15, since it
   carries the argument; just say "it's half a control, ask me why" (saves ~35s).
5. **Beat 1's `cat`** — describe the input instead of showing it (saves ~20s).

Beat 4 carries the most weight; spare time goes there.

---

## Q&A ammunition

**"Why a toy policy in the middle? Why not use control 43 throughout?"**
Because control 43 on this trail structurally can't teach the vocabulary. It has
**one subject** (the trail carries one commit), and that removes five things the
middle slides need:

| what the slide needs | `control_43` here | `prod_deploy` |
| --- | --- | --- |
| repetition to avoid — slide 8, "definitions live once" | 1 subject, nothing repeats | 3 subjects |
| `applies_to` and scope — slides 6–7 | **zero** `$applies` rows | 3 |
| `absent` ≠ `value` — slide 9 | only `satisfied` and `value`; **`absent` never occurs** | all three |
| rows for `violations` to filter — slide 11 | 1 failing row | 3 |
| a requirements block that fits a slide — slide 6 | **124 lines** | 19 |

That last one decides it on its own: slide 6 holds 17 lines. And it doesn't run
the other way either — prod_deploy can't be the spine, because nobody is
impressed that a toy ports. There's no parity, no defects and no cost story
without the real control.

So: **control 43 carries the claim (slides 2–5, 12–15), prod_deploy carries the
vocabulary (6–11).** Both reports are in the appendix, one slide each.

**"Isn't this just OPA with extra steps?"**
The engine *is* OPA. What's added is that the rule is data and the output is a
uniform report — the same shape regardless of which policy produced it, so it
can be hashed, attested and consumed without parsing Rego.

**"What happens on garbage input?"**
Every operator fails on missing, null or wrong-typed input — never vanishes,
never accidentally passes. The report is **total**: every declared check
produces a row even on malformed input, so "failed because the field was
missing" is a row, not a gap. And a denial is never silent — an unsatisfied
requirement always produces at least one failing row.

**"What can't it express?"**
The four-eyes condition itself — approvers compared against commit authors
across two nested collections. That's the 86-line custom op, and it's the escape
hatch working as intended. Custom ops contribute into the library's package from
the policy side. The rule: reach *downwards* into the library's primitives,
never sideways or up — calling `report` or `check_passed` from a custom op stops
the *library* compiling. `CONTRIBUTING.md` has the layer stack.

**"How do you know the library is right?"**
410 tests across `src` and `examples`. But the differential harness in beat 6 is
the stronger evidence: the hand-written policy sits next to the port and the
build breaks when they disagree.

**"Why is `require: some` interesting?"**
"One merged PR was on the protected branch, and one had signed commits, and one
was peer-approved" must not add up to compliance if those were three different
PRs. `some` means one subject has to pass **all** checks on its own.
`examples/trail_split.json` is built to fail exactly that way.

**"Where do the report's guarantees actually bite?"**
Determinism. Byte-identical reports for the same policy and input regardless of
key order, which is what lets you hash it and attest the hash.

**"Doesn't `--show-input` already give us the values?"**
It gives the **input document** — the haystack, not the needle — and yes, it's
already captured by control 43's workflow; INTEGRATION.md leans on exactly
that for the `opa`-in-the-image route. Four things it still doesn't do:

- **It never says which fields a check consulted.** Getting from ~10 MB of input
  plus `allow: false` to "alice approved her own commit" means reading the policy
  and re-executing it in your head. The row does that projection for you.
- **It lets you re-run, not recompute.** Re-running needs OPA, the exact policy
  version that ran, the library version, and the same `--params`. Recomputing
  needs only the row.
- **`cause` isn't in the input at all** — it's a property of the *evaluation*.
  No input dump distinguishes a selector that matched nothing (`unmatched`) from
  one that matched twice (`ambiguous`), because that depends on what the check's
  selector was. In the original policy, two `pull_request` attestations don't
  even fail — they crash (`eval_conflict_error`, slide 14).
- **Nothing binds the dump to the verdict.** Two artifacts, two flags, neither
  referencing the other, and neither recording which policy version ran. The
  report is one deterministic hashable document binding subject + check + values
  + verdict + cause — which is why the *report* is the attestable artefact and
  `violations` isn't.

The narrow version holds: if all you want is to re-run the gate later,
`--show-input` plus the policy is enough. The report is for the case where
somebody has to answer *why* without re-running anything.

### Known weak spots, all documented in the repo

- **A fail-closed library still gets a policy wrong when a selector can't
  match.** It shipped with exactly that: a substitute selected on
  `attestation_type: "custom"` when Kosli emits `custom:<name>`, so it matched
  nothing, sat inert, and every initial commit went on being denied — the exact
  bug the substitute was added to fix. It passed its own tests because the
  fixture was written from the same guess. "No evidence found" and "the address
  is wrong" both deny, and denying is the safe direction that **hides** the
  mistake. The operational tell: a substitute that never once reports
  `substituted` across a whole report is a substitute nobody is reaching.
- **The parity harness proves the axes it varies, and no more.** It can't notice
  that the vendored copy has drifted from the `four-eyes.rego` branch it cannot see —
  and on 2026-09-07 that had happened. It caught **one** of five verdict-level
  differences; the corpus was blind to the other four, because all eight
  original cases had a readable trail author, a resolvable approver and no bot.
  A corpus is only as good as the shapes it thinks to vary.
- **Expressing an exemption as scope has a fail-open edge.** A failing
  `applies_to` check puts a subject *out of scope*, which is permissive. A
  commit whose author couldn't be read matched no service-account pattern, fell
  out of scope, and took the requirement with it — allowed, with an empty report
  of breaches. Found, reproduced, closed by asserting the author as a check too.
  That's the README's own advice being paid for the first time.
- **The custom-attestation path is dry-run only.** Server-side schema validation
  and jq evaluation are untested. Don't claim that leg works.

---

## Claims that don't hold

- That the evidence report reaches production today. It does not — beat 7.
- That the port is smaller than the policy it replaces. It isn't.
- That control 43 alone justifies adoption. It doesn't, and saying so out loud
  is what makes the rest credible.

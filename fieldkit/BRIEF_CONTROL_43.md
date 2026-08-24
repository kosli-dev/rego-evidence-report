# Brief 2: control 43 (four-eyes) against kosli.evidence

**You are Claude Code on the restricted machine with access to real Deutsche Bank
systems and the control 43 source. This is the second round.** Round 1
(`BRIEF.md`) established the shape of a `kosli get trail` response; read that
file's rules, then this one. Work the investigations in order.

First, get the current code — this work lives on a branch:

```sh
git fetch --depth 1 origin integration && git reset --hard FETCH_HEAD
```

## What this is about

Control 43 (`RCTLDEF0000043`, "Source Code Review Verification Tool") enforces the
four-eyes principle per commit. Its collector creates one Kosli trail per commit
and attests GitHub PR data as `source-code-review`; `kosli evaluate` then runs a
Rego policy, owned in the **`sdlc-workflows`** repository, over `input.trails[]`.

We want to know whether `kosli.evidence` (this repo) can express control 43,
producing a structured evidence report instead of `allow` plus hand-written
violation strings. Round 1 proved the library survives real data; this round is
about a real *control*.

## Hard rules

1. **Nothing leaves this machine unredacted.** For any document you bring back,
   run it through the sanitizer in this repo:
   ```sh
   python3 fieldkit/sanitize.py real.json > safe.json
   python3 fieldkit/sanitize.py real.json --audit    # inspect what it replaced
   ```
   It is fail-closed: a string survives only if it is recognisable policy
   vocabulary, and anything else is replaced. It preserves structure, and it
   preserves **identity relationships** — each person becomes a distinct stable
   pseudonym, so approver-vs-author comparisons still evaluate correctly on the
   redacted copy. **Verify with `--audit` before the file travels**, and if the
   audit shows a value you don't recognise as safe, treat that as a finding.
   Round 1's file was moved across whole and carried a real employee's email, an
   internal Artifactory hostname and live tenant ids. Don't repeat that.

   Because it is fail-closed, it will also replace **vocabulary it hasn't been
   taught** — and an enum value carries meaning, so a fixture whose `"MERGED"`
   became `"redacted-3f21"` has the right shape and the wrong semantics: a policy
   asserting `state == "MERGED"` would silently stop matching. Read the `--audit`
   output for exactly this. Known GitHub/Kosli enums are already in the `KEEP` set
   in `fieldkit/sanitize.py`; if the audit shows another one being replaced, add
   it to `KEEP`, re-run, and **list what you added** in your findings. Never keep a
   value that identifies a person, host, repository or tenant.
2. **Never paste raw values into prose.** Field names, types and counts only.
3. **Do not push, open a PR, or write to GitHub.**
4. **Verify, don't infer.** Every claim must come from a file you read or a
   command you ran. If you couldn't, write `blocked:` and say why.
5. **Real inputs live in `fieldkit/scratch/`** — gitignored, so they can't be
   committed and `git reset --hard` won't destroy them.
6. **Never invent field names.** Round 1's whole lesson: the previous example
   policy was built on plausible-sounding invented fields and was inert against
   real data. If you cannot read a field name from source or from real output,
   report it as unknown.

## Already established — do not re-derive

- A `kosli get trail` response has `compliance_status.attestations_statuses` as an
  **array** of `{attestation_name, status, is_compliant, ...}`; the per-artifact
  list is **empty**; timestamps are **epoch numbers**; commit id is **sha1** only;
  `trail.name` is the commit sha; `user_data` is a **JSON-encoded string** (empty
  in the sample).
- `status: "COMPLETE"` means *reported*, not *passed*. `is_compliant` is the
  verdict. Asserting only `status` is a fail-open, and real data contains
  `COMPLETE` with `is_compliant: false`.
- The library is control-agnostic; `compare_time` now accepts epoch numbers;
  `matches_any`/`not_matches_any` now exist for exemption lists.
- Selecting one element out of an attestation array needs no new vocabulary:
  `applies_to` filters an array down to the named element.
- Consumption is the `opa` binary via `execSync` in a prebuilt Docker image, one
  fixed policy per control, nothing varies policy at runtime.

## Investigation 1 — the authoritative rule (highest value)

**The two control-43 documents contradict each other, and no policy can be written
until this is settled.**

- `README.md` states rule 3 as: at least one approval from someone who **did not
  author any PR commit**.
- `SCENARIOS.md` scenario 13 has two developers both authoring commits in one PR
  and approving each other, and calls it **PASS**, reasoning that each commit has
  an approval from someone other than **its own** author. Scenario 14 repeats that
  per-commit reasoning explicitly.

Under the README's rule, scenario 13 must FAIL. The two readings diverge on the
most common real case — a shared branch with mutual review.

**Resolve it from the code, not the prose.** The policy in `sdlc-workflows` is the
source of truth. Find it, read the rule, and report which of these it implements:

- **per-PR**: the approver must have authored *no* commit in the PR
- **per-commit**: the approver must merely differ from *this* commit's author
- **something else** — state it precisely

Then say whether `SCENARIOS.md` scenario 13 passes or fails under the real policy,
and whether the docs or the policy is wrong. Also note: `SCENARIOS.md` skips
scenarios 9, 10 and 12 — check whether those were deleted, renumbered, or are
where this ambiguity was once resolved.

## Investigation 2 — the real policy input (the key artifact)

`kosli get trail` is **not** what feeds a policy. Control 43's README documents
policy input as `input.trails[i].compliance_status.attestations_statuses["source-code-review"]`
— a **map keyed by attestation name**, and `trails[]` plural, one per commit. That
is a different shape from what round 1 captured, so round 1's fixture may be the
wrong shape to design against.

Capture the real thing (flag documented in control 43's README):

```sh
kosli evaluate trails SHA1 SHA2 --policy <path> --show-input --flow <flow> --output json
```

Then:

```sh
python3 fieldkit/sanitize.py showinput.json --audit     # check before it travels
python3 fieldkit/sanitize.py showinput.json > fieldkit/scratch/show_input.safe.json
python3 fieldkit/kit.py shape fieldkit/scratch/show_input.safe.json
```

**Bring back `show_input.safe.json`.** It is the single most valuable artifact of
this round: with it, the policy can be written here against real paths instead of
guessed ones. Pick a range that includes at least one **failing** commit and one
**passing** one, ideally one service-account commit — a fixture that only contains
passes cannot demonstrate a violation.

Report specifically:

- is `attestations_statuses` a **map** or an **array** in this shape?
- the exact field names of the PR attestation payload — how are the **approvers**,
  the **PR commits and their authors**, the **timestamps**, and the **merge commit
  sha** spelled? These are the names round 1 could only invent.
- are approver identities the same *kind* of string as commit authors
  (`Name <email>` vs a GitHub login)? If they differ, an identity comparison needs
  normalising, which is a library-level concern.
- what timestamp format appears here — epoch numbers, RFC3339, or both?

## Investigation 3 — the integration contract

This decides whether the library can plug in at all.

- `kosli evaluate --policy <path>`: is that a **single file** or a **directory /
  bundle**? Can it load several `.rego` files? `kosli.evidence` is a library in
  its own package that a policy imports, so if only one file is accepted, the
  library would have to be vendored or concatenated — a real constraint worth
  knowing now.
- What exactly does `kosli evaluate` **query**? Which package and rule names must
  the policy expose — `allow`, `violations`, something else — and what types does
  it accept for them? Our report is a different shape; the policy would wrap it.
- Does anything consume the *violation strings* verbatim (dashboards, tickets,
  the `four-eyes-result` attestation schema)? If so, changing the message format
  is a breaking change, and the schema file
  `four-eyes-result-schema.json` is worth reading.

## Investigation 4 — the existing test suite

Control 43's README says policy tests live in `sdlc-workflows`. Those tests are the
control's real specification. Report:

- how many there are, and whether they cover every `SCENARIOS.md` case
- **the input fixtures they use** — a Rego test fixture is usually synthetic
  already, so it may be safe to bring back (run it past the sanitizer and use
  judgement; if it contains real names, redact it)
- any behaviour the tests pin that neither document mentions

## Investigation 5 — draft the requirements (stretch)

Only if 1–4 are done. Sketch control 43 as a `kosli.evidence` policy: a
requirement whose subjects are `trails[]`, `applies_to` exempting service accounts
via `not_matches_any`, and checks for "a merged PR exists" and "an independent
approval after the last code commit". Use `fieldkit/policy_template.rego`, which
carries the whole operator vocabulary in comments, and run it:

```sh
python3 fieldkit/kit.py run fieldkit/scratch/c43.rego fieldkit/scratch/show_input.safe.json
```

Report which parts the vocabulary couldn't express. Expect the independent-approval
rule to need a custom op — that's the escape hatch working as designed, not a
failure. One thing it definitely cannot express is control 43's **first-match-wins
ordering**: this library runs every check, so a commit with no PR fails both "has
a PR" and "has an approval" — two rows where the current tool reports one reason.
Confirm whether that would be a problem for anyone consuming the output.

## Deliverables

1. **`show_input.safe.json`** — sanitized, `--audit` checked. The priority.
2. Optionally the policy test fixtures, same treatment.
3. This block, filled in, kept short enough to retype and free of values:

```
FINDINGS 43
rule3:        <per-PR | per-commit | other: ...> (from sdlc-workflows policy)
scenario13:   <passes | fails> under the real policy | docs wrong: <which one>
scen 9/10/12: <deleted | renumbered | unknown>
input shape:  attestations_statuses is <map|array> | trails[] <n> | timestamps <epoch|rfc3339>
pr fields:    approvers=<name> commits=<name> authors=<name> ts=<name> merge=<name>
identities:   approver <same|different> kind of string as commit author
evaluate:     --policy takes <file|dir> | multi-file <y/n> | queries <pkg.rule names>
consumers:    <anything parsing violation strings verbatim: y/n + what>
tests:        <n> in sdlc-workflows | cover all SCENARIOS <y/n> | fixtures brought <y/n>
KEEP added:   <vocabulary you had to add to sanitize.py, or none>
vocabulary:   <what couldn't be expressed, one line each>
ordering:     <is two-rows-instead-of-one a problem for consumers: y/n + why>
blocked:      <what you could not run or read, and why>
```

Investigations 1 and 2 are the reason for this round. If you only get those two,
it was worth it.

---

## Round 2 outcome, and the one thing round 3 needs

Round 2 came back answered. What it established, so nobody re-derives it:

- **Rule 3 is per-author**, not per-PR and not per-commit: for every author in
  `pr.commits[].author_username ∪ {pr.author}` there must exist some approver
  (`state == "APPROVED"`, `timestamp` after the latest commit) who is not *that*
  author. Mutual review therefore passes, `SCENARIOS.md` is right, and the
  control-43 `README.md` prose is the wrong document.
- **Map-vs-array is moot.** The policy iterates values (`some attest in …`) and
  selects on `attestation_type == "pull_request"`, which works for both shapes.
  Two rounds of worry about this was wasted effort.
- **Identities need no normalisation** — `approver.username` and
  `commit.author_username` are both GitHub logins. `"Name <email>"` appears only in
  `git_commit_info.author`, used solely for service-account and web-flow regexes.
- **The output contract is fixed** by `four-eyes-result-schema.json`:
  `violations` is `string[]`, one entry per failing commit. A format change is a
  schema break.
- **The production policy already distinguishes "identity unverifiable" from "no
  independent approval"** — independently arriving at the same distinction as this
  library's proposed row-level cause discriminator.
- **Control 43 has two generations**, and the Rego one is new: the legacy
  TypeScript did its own evaluation and emitted an xlsx report, while
  `…-source-code-review-kosli` is a thin collector with the rule pushed into Rego.
- **`four-eyes.rego` is the only `.rego` policy in all of `sdlc-workflows`.** Every
  other control (136, 1033, 1063, 1068, 1691, 2230, and legacy 43) is still
  workflow wiring. So this is not standardising an existing family of policies —
  there is exactly **one** policy to generalise from, which means nothing yet
  distinguishes "this abstraction is general" from "this abstraction restates the
  single case we looked at". Only a second control can tell those apart.

### The ask

**Hand over `four-eyes.rego` and `four-eyes_test.rego`** (from
`sdlc-workflows/.github/actions/Kosli_RCTLDEF0000043/`), plus the collector's
TypeScript types if they're cheap to include.

These are **safe by construction**: the tests use `alice`/`bob`/`sami`/`faye` and
`example.com`, and policy logic is field names and rules, not values. Real
identities, hostnames, tenant ids and SHAs stay behind — those are values, and none
are needed.

With those two files the `kosli.evidence` version can be designed against real
paths and checked for behaviour parity against 37 known-good cases **entirely
offline, with no real data involved** — which is what rounds 1 and 2 were groping
toward and couldn't reach. Two rounds asked for data; the missing thing was
architecture.

A live `kosli evaluate --show-input` capture is no longer needed for design. It
would only confirm the wire shape, which the policy and its tests already settle.

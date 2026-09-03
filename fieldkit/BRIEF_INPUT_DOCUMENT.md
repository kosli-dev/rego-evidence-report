# Brief 5: the input document, and one pull request with two authors

**You are Claude Code on the restricted machine with access to real Deutsche Bank
systems, the control 43 source, and the `sdlc-workflows` repository. This is the
fifth round**, and it is the shortest, because your last hand-over
(`HANDOVER_CONTROL_43_FIELD.md`) answered most of what was open and this side
acted on it.

```sh
git fetch --depth 1 origin integration && git reset --hard FETCH_HEAD
opa test src examples --ignore '*.json'   # expect PASS: 389/389
```

## The hard rules have not changed

1. **Nothing leaves unredacted.** `python3 fieldkit/sanitize.py real.json > safe.json`,
   check `--audit` before it travels, and list anything you added to `KEEP`.
2. **Never paste raw values into prose.** Field names, types, counts, operator
   names. No logins, emails, shas, repo/org/flow names, or JIRA ids.
3. **Real captures stay in `fieldkit/scratch/`**, which is gitignored.

## What changed here because of your hand-over — do not re-derive any of it

**Your point 3 is answered, and the answer is yes.** `kosli evaluate` enriches the
trail itself: it fetches the trail, converts `compliance_status.attestations_statuses`
from an array to a **map keyed by `attestation_name`**, then fetches each
attestation by id and merges its own fields onto the status entry wherever the key
isn't already there. `pull_requests` therefore *is* reachable at
`compliance_status.attestations_statuses[<name>].pull_requests[]`, and the port's
`from`/`id`/selector paths are correct as written. Enrichment is not gated on
`--attestations`; that flag only *limits* which attestations survive, and because
it runs first it also reduces the per-attestation fetches.

This was settled without real data and without your help: `internal/evaluate/transform.go`
and `cmd/kosli/evaluateHelpers.go` in `kosli-dev/cli` say it (identically in
v2.13.1 and on `main`), and running 2.13.1 with `--host` pointed at a stub server
on localhost produced the document and fed it straight into the port. Ten rows,
`allow: true`. **The lesson from round 4 repeated itself** — the question looked
like it needed the restricted machine and actually needed a terminal and the CLI's
own source. Sort your open questions that way first.

**Three library changes, all from your section 4.** Read `README.md` for the
detail; in one line each:

- **`substitute`** — any named check can declare alternative evidence that
  satisfies it. `examples/control_43.rego` now accepts your
  `custom:initial-commit-by-verified-committer` attestation in place of the pull
  request requirement, so the initial commit no longer false-fails. The row says
  `cause: "substituted"` and echoes the evidence that discharged it.
- **`cause` on every row** — one of `satisfied`, `substituted`, `ambiguous`,
  `unmatched`, `absent`, `null`, `value`. Your section 4.2, and it closed the
  port's worst message: "attestation is missing **or ambiguous**" is now two
  messages.
- **`each` + `any_of` as an element check** — your section 4.3 asked for a
  `resolved-or-exempt` operator, and it isn't there, because the ask diagnosed the
  wrong blocker. The disjunction was already `any_of`; what forced
  `identities_resolved` to be a custom op was **nesting depth** — every commit of
  every pull request is two collections and the vocabulary stopped at one. `each`
  supplies the level, and `identities_resolved` is now data. `control_43_ops.rego`
  is down to one operator, the four-eyes condition itself.

**And your point 1 found a fail-open in the port**, indirectly. You reported
`git_commit_info` as a sibling of `pull_requests` **on the attestation object**;
the port reads it at trail level for the service-account exemption. Because an
exemption is expressed as *scope*, an author it cannot read puts the commit **out
of scope** rather than in breach — so a trail with no author and no attestations
was allowed, silently. Closed by asserting the author in the requirement that
declares no filter. If your real documents disagree about where
`git_commit_info` lives, that is the first thing to say.

Still open from your hand-over, and only from here: your point 5, a **real pull
request with two distinct authors**. Investigation 2.

## Investigation 1 — which document does the workflow hand `opa`?

The load-bearing claim from round 4 is that control 43 runs the `opa` binary
itself via `execSync` in a prebuilt image, rather than going through
`kosli evaluate`. If that is right, then something has to compose the input
document, and **`kosli get trail` is not a candidate**: it returns the status
metadata only, exactly as you found — no `pull_requests`, so every identity and
approval check would fail closed against it.

In the `sdlc-workflows` repository, find the workflow (or action) for
`RCTLDEF0000043` and read the step that runs `opa`. Answer:

1. Where does the `-i` / `--input` document come from? Name the command that
   produces it — `kosli evaluate ... --show-input | jq '.input'`,
   `kosli get trail`, the collector writing a file, or something else.
2. If it is `kosli evaluate --show-input`: is `--attestations` passed, and with a
   plain name or a dot-qualified one?
3. If it is anything else: how does `pull_requests` get into that document? This
   is the one that matters. If the answer is "it doesn't", then production's
   identity and approval rules are reading fields that aren't there, and the
   policy's verdicts deserve a second look rather than the library's.
4. Which `opa` query does it evaluate — `data.policy.allow`, `data.policy`, or
   the whole document — and does anything downstream read more than `allow` and
   `violations`?
5. Is the policy file passed to `opa` alone, or with other `-d` files?

Command pipeline and flag names only. No org, flow or repo names.

## Investigation 2 — one real pull request with two distinct authors

The per-author rule (*for every author, some approver who is not that author*) is
the heart of control 43 and the one behaviour real data has never exercised: both
pull requests you looked at were single-author. It is also the rule most likely to
be wrong in an interesting way, because it is the one control 43's own README
describes incorrectly.

**Find an existing merged pull request whose `commits[]` carry two or more
distinct `author_username` values.** Do not create one; look. A dependabot or
web-flow commit alongside a human one counts as one distinct author for this
purpose, so prefer a genuine two-person branch.

Run both policies over it — production `four-eyes.rego` and, from this repo,
`python3 fieldkit/kit.py run examples/control_43.rego <trail>.json --ops examples/control_43_ops.rego`
— and report, as counts and verdicts only:

1. Distinct commit authors (n), approvers (k), and how many approvers are also
   commit authors.
2. Whether each policy allows, and whether they agree.
3. If they disagree, which check failed in the port and what its `cause` was.
4. Whether the pull request is a **mutual review** (each author approved the
   other): that case must pass, and it is the difference between the per-author
   reading and the "approver who authored nothing" reading.

If no such pull request exists anywhere you can reach, say so plainly — that is a
finding too, and it means the rule's hardest case is unreachable in this
customer's data.

## Investigation 3 — the new machinery against your two real attestations

You still have the matched pair from last round in `fieldkit/scratch/` (one
exemption-path, one intended-path). Re-run the port with the current library and
report only what differs:

1. Does `identities_resolved`, now expressed as data rather than the custom op,
   reach the **same verdict** on both? It should, with one deliberate exception: a
   pull request whose `commits` array is **empty** now fails closed, where the
   custom op treated it as "every commit checks out".
2. For every failing row, its `cause`. Is it the cause you would have named? A
   row whose cause says `value` when the real problem was a wrong path, or
   `absent` when the field is there, is a library bug and the most valuable thing
   this round can find.
3. Does any row report `ambiguous`? On real data that means two attestations of
   the same type on one trail, which we believe is reachable through
   `KOSLI_ATTESTATION_NAME` but have never seen.

`kit.py run` now prints `cause` as the third column of the failing-rows table, so
this is mostly reading its output.

## Investigation 4 — the substitute, against the real initial commit

You reported that production accepts a compliant
`custom:initial-commit-by-verified-committer` attestation in place of the pull
request requirement. The port now declares that as a substitute, selected by
`attestation_type == "custom"` **and** `attestation_name ==
"initial-commit-by-verified-committer"`.

1. Are those two field values exactly right, on a real trail carrying that
   attestation? A name that differs by a hyphen makes the substitute inert.
2. Is `is_compliant` the field production reads, and is `true` a boolean there
   rather than a string?
3. Does the substitute belong on all four pull-request checks, or does production
   accept it for fewer of them? The port applies it to all four, which means a
   root commit passes with four `substituted` rows.
4. Is that attestation ever present on a trail that is **not** a root commit? The
   port treats its presence as the discriminator, so if it can appear elsewhere,
   the substitute is wider than intended.

## What to carry back

Five short answers, in this order: the input-document pipeline (1), the
two-author verdicts (2), any cause you disagree with (3), the four substitute
field facts (4), and anything above that is simply wrong.

The fixture-pair suggestion from your point 6 still stands and is still worth
doing whenever the sanitizer's output looks right to you: one exemption-path and
one intended-path attestation, sanitised, make the first committed fixture in this
repo that came from a real pull request.

# Brief 5: everything still open that only you can answer

**You are Claude Code on the restricted machine, with access to real Deutsche
Bank systems, the control 43 and 1068 sources, and the `sdlc-workflows`
repository.** This brief replaces the round-4 integration brief, which you never
got a chance to answer: most of what it asked has since been settled from a
laptop with the CLI installed, and what was left is folded in below. Nothing here
is answerable from this side.

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

## Settled here — do not spend a minute re-deriving any of it

- **`kosli evaluate`'s contract.** `Result{Allow bool, Violations []string}`; it
  queries `data.policy.allow`, then `data.policy.violations` only on a denial;
  a non-string element of `violations` is silently dropped. Read in
  `internal/evaluate/rego.go` and confirmed by running it.
- **`--policy` takes one file**, parsed as a single module whose package must be
  `data.policy`. So the library is merged rather than imported on that path, and
  `fieldkit/bundle.py` does it, proving each bundle behaviour-identical. The
  bundled port has since been run **through `kosli evaluate` itself** as a real
  gate: `RESULT: DENIED`, one violation string, exit 1.
- **What `--show-input` produces**, which was your point 3. `kosli evaluate`
  enriches the trail itself: it converts `compliance_status.attestations_statuses`
  from an array to a **map keyed by `attestation_name`**, then fetches each
  attestation by id and merges its own fields onto the status entry where the key
  is absent. `pull_requests` is therefore reachable where the port looks, and
  `--attestations` only *limits* which attestations survive. Verified by running
  2.13.1 against a stub API on localhost and feeding the captured document to the
  port.
- **The three library changes your section 4 asked for**: `substitute`
  (alternative evidence on any named check), `cause` on every row
  (`satisfied | substituted | ambiguous | unmatched | absent | null | value`), and
  `each` + an `any_of` element check — which together turned
  `identities_resolved` into data, so `control_43_ops.rego` is down to the
  four-eyes condition alone. Your 4.3 ask for a `resolved-or-exempt` operator is
  **not** there: the blocker was nesting depth, not the disjunction. `README.md`
  has all three.
- **`any_of` needs no design review.** It has now survived contact with a second
  control, which is the review that counts.

## Investigation 1 — the workflow: how `opa` runs, and what it eats

This is the round. Everything below it is worth less.

Round 2 recorded that control 43 runs the `opa` binary via `execSync` in a
prebuilt Docker image rather than going through `kosli evaluate`. **That single
line is load-bearing** — it is why the whole evidence report is available on the
path the team actually uses, and it has never been checked. In `sdlc-workflows`,
find the workflow or action for `RCTLDEF0000043` and read the step that runs the
policy.

1. **The exact invocation.** Which files are passed with `-d`, which query is
   asked for (`data.policy.allow`, `data.policy`, something else), and how the
   output is parsed. If it turns out to call `kosli evaluate` after all, say so
   first and loudly — several conclusions on this side then need rewriting.
2. **Where the input document comes from.** Name the command that produces it:
   `kosli evaluate … --show-input | jq '.input'`, `kosli get trail`, the collector
   composing it from its own API calls, or something else.
3. If it is `--show-input`: is `--attestations` passed, and with a plain name or a
   dot-qualified one?
4. If it is **`kosli get trail`**: then `pull_requests` is not in that document —
   you established that yourself — and production's identity and approval rules
   are reading fields that aren't there. That would make the policy's verdicts,
   not the library, the thing to look at.
5. **Does anything in `sdlc-workflows` use `kosli evaluate` at all?** A count, or
   none.

Command pipeline and flag names only. No org, flow or repo names.

## Investigation 2 — where does `git_commit_info` actually live?

Your point 1 reported it as a **sibling of `pull_requests` on the attestation
object**. The port reads it at *trail* level, for the service-account exemption.
Both can be true; which are true of a real document matters, because an exemption
expressed as scope fails **permissively** — an author the policy cannot read
matches no exemption pattern, so the commit leaves scope entirely. A trail with
no readable author and no attestations was **allowed** here, silently, until this
week.

1. On a real enriched document, is `git_commit_info` present at trail level, on
   the attestation, or both?
2. If only on the attestation: does production's rule 1 read it from there? Its
   own tests build trail-level `git_commit_info`, so the tests and the wire may
   disagree.
3. Is `author` on it always the git `Name <email>` form, or can it be empty or
   absent on a real trail?

## Investigation 3 — one real pull request with two distinct authors

The per-author rule (*for every author, some approver who is not that author*) is
the heart of the control and has met only synthetic input: both pull requests you
looked at were single-author. It is also the rule control 43's own README
describes incorrectly.

**Find an existing merged pull request whose `commits[]` carry two or more
distinct `author_username` values.** Do not create one; look. Bot and web-flow
commits count as one author for this purpose, so prefer a genuine two-person
branch. Then run both policies over it — production `four-eyes.rego`, and
`python3 fieldkit/kit.py run examples/control_43.rego <trail>.json --ops examples/control_43_ops.rego`
— and report as counts and verdicts only:

1. Distinct commit authors (n), approvers (k), and how many approvers also wrote
   commits.
2. Whether each policy allows, and whether they agree.
3. If they disagree: which check failed in the port, and its `cause`.
4. Whether it is a **mutual review** (each author approved the other). That must
   pass, and it is exactly where the per-author reading and the
   "approver who authored nothing" reading part company.

If no such pull request is reachable, say so plainly. That is a finding: the
rule's hardest case does not occur in this customer's data.

## Investigation 4 — the new machinery against your two real attestations

You still have the matched pair in `fieldkit/scratch/`. Re-run the port with the
current library and report only what differs.

1. Does `identities_resolved`, now data rather than a custom op, reach the **same
   verdict** on both? It should, with one deliberate exception: a pull request
   whose `commits` array is **empty** now fails closed, where the custom op
   treated it as "every commit checks out".
2. For every failing row, its `cause`. **Is it the cause you would have named?**
   A row saying `value` when the real problem was a wrong path, or `absent` when
   the field is there, is a library bug and the most valuable thing this round can
   find. `kit.py run` prints `cause` as the third column.
3. Does any row report `ambiguous`? On real data that means two attestations of
   the same type on one trail — reachable through `KOSLI_ATTESTATION_NAME`, but
   never seen.

## Investigation 5 — the substitute, against the real initial commit

The port accepts a compliant `initial-commit-by-verified-committer` attestation in
place of the pull request requirement, selected on `attestation_type == "custom"`
**and** that `attestation_name`.

1. Are both field values exactly right on a real trail? A name differing by a
   hyphen makes the substitute inert.
2. Is `is_compliant` the field production reads, and is it a boolean there?
3. Does production accept the substitute for **all four** pull-request checks, or
   fewer? The port applies it to all four, so a root commit passes with four
   `substituted` rows.
4. Can that attestation ever appear on a trail that is **not** a root commit? The
   port treats its presence as the discriminator, so if it can, the substitute is
   wider than intended.

## Investigation 6 — the report's home

The report's destination is a custom attestation type with a JSON schema and jq
evaluation rules (`schema/evidence-report.schema.json`, and the `kosli create
attestation-type` invocation in `INTEGRATION.md`). It has only ever been
**dry-run** from here: no request was sent, so server-side schema validation and
jq evaluation are untested.

1. **Is there a precedent?** Does any control already use
   `kosli attest custom --type` with a schema and `--jq` rules? Name the control
   and type; that is a working pattern worth copying rather than inventing.
2. **If you have a writable flow**: attest a report for real and say whether the
   schema validated and the jq rules evaluated. Highest-value item here.
3. **Payload size limit** on an attestation — docs or a real attempt. A report is
   O(subjects × checks), every row echoes the inputs it read, and rows have since
   grown a `cause` field, with substituted rows echoing both sides. A wide trail
   could get big.
4. **Which CLI version is in the image?** `--summary`, which renders report
   numbers in the Kosli UI, is in the CLI source on `main` but absent from 2.13.1.
   `kosli evaluate input` and `--params` are in the same position.
5. **Is DB on `app.kosli.com` or a separate instance?** It decides whether any of
   this transfers.

## Investigation 7 — control 1068's source

Two claims in `examples/control_1068.rego` rest on one fact each, and both need
the source.

1. The three **flavour tables** (Standard | Cloud | Safe) are *illustrative*,
   consistent only with the one fact that reached us: no single table holds both
   `Story` and `DONE`. If you can read the real membership, replace them — and if
   the real tables make that cross-product example wrong, say so.
2. `control_1068_test.rego` asserts the control's real subject **cannot be
   named**, on the grounds that `getJiraIdsFrom` flattens commits to a set of
   ticket ids with no backref. Check that against the source. **If a backref
   exists anywhere, that test is wrong** and the library is less limited than we
   have been telling people.

## What to carry back

Investigation 1 is the round; if you get only that, it was worth it. Then this
block, short enough to retype and free of values:

```
FINDINGS ROUND 5
opa invocation:       <exact -d files + query, or REFUTED: uses kosli evaluate>
input source:         <--show-input|kosli get trail|collector-composed|other>
evaluate users:       <n places in sdlc-workflows, or none>
git_commit_info:      <trail|attestation|both> | author always Name <email> <y/n>
two-author PR:        <found: n authors k approvers|none reachable>
  verdicts:           <both allow|both deny|disagree: ...> | mutual review <y/n>
causes disagreed:     <check + cause you would have named, or none>
empty-commits case:   <occurs in real data y/n>
ambiguous seen:       <y/n>
substitute fields:    <type+name exact y/n> | is_compliant bool <y/n> | all four <y/n>
  non-root:           <can appear on a non-root commit y/n>
custom-type precedent:<control + type name, or none>
live attest:          <schema validated + jq evaluated|failed: ...|blocked: no org>
payload limit:        <bytes, or unknown>
cli version:          <x.y.z> | --summary <y/n> | evaluate input <y/n>
kosli instance:       <app.kosli.com|other>
1068 tables:          <real membership readable y/n> | example still valid <y/n>
1068 backref:         <none, test stands|EXISTS at <file>, test is wrong>
KEEP added:           <vocabulary added to sanitize.py, or none>
blocked:              <what you could not read or run, and why>
```

The fixture pair from your point 6 still stands whenever the sanitizer's output
looks right to you: one exemption-path and one intended-path attestation,
sanitised, would be the first committed fixture here that came from a real pull
request.

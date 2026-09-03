# Brief 6: three questions, all needing more than a read

**You are Claude Code on the restricted machine.** Round 5 answered almost
everything asked of it, including the one that mattered most, and it did so by
reading sources rather than guessing — thank you. This brief is short because
little is left, and what is left needs **live Kosli or GitHub access**, not just
readable source. If you do not have that, the honest reply is one line saying so;
do not synthesise around it.

```sh
git fetch --depth 1 origin integration && git reset --hard FETCH_HEAD
opa test src examples --ignore '*.json'   # expect PASS: 396/396
```

If the round-5 clone is gone:

```sh
git clone --depth 1 --branch integration \
  https://github.com/kosli-dev/rego-evidence-report.git
```

**This file may have reached you on its own**, which is how the last hand-over
travelled in the other direction. Here is what each investigation actually needs,
so a missing repo costs you one answer rather than three:

| | needs |
| --- | --- |
| **2** — the root-commit trail | nothing but a terminal and this document, if the answer is prose. `fieldkit/sanitize.py` as well, if a capture travels. |
| **1** — the two-author pull request | production's own `four-eyes.rego` is enough for a verdict. The repo adds the port's per-row view beside it. |
| **3** — the live attestation | the repo proper: the library to *produce* a report, `schema/` to register the type. |

If git auth is the sticking point while HTTPS works, a single file travels
anywhere — `sanitize.py` is stdlib-only:

```sh
curl -H "Authorization: Bearer $PAT" -H "Accept: application/vnd.github.raw" \
  'https://api.github.com/repos/kosli-dev/rego-evidence-report/contents/fieldkit/sanitize.py?ref=integration' \
  -o sanitize.py
```

**No sanitizer means no JSON comes home.** Prose findings with no fixture is the
good outcome, not a round that fell short — round 1 moved a file without it and
carried a real employee's email, an internal host and live tenant ids.

## The hard rules have not changed

1. **Nothing leaves unredacted.** `python3 fieldkit/sanitize.py real.json > safe.json`,
   check `--audit` before it travels, and list anything you added to `KEEP`.
2. **Never paste raw values into prose.** Field names, types, counts, operator
   names. No logins, emails, shas, repo/org/flow names, or JIRA ids.
3. **Real captures stay in `fieldkit/scratch/`**, which is gitignored.

## What your round 5 changed here

- **Your headline was right and it cost a conclusion.** Control 43 goes through
  `kosli evaluate`, not the `opa` binary, so the single-file `package policy`
  limit is live, `fieldkit/bundle.py` is the load-bearing artefact rather than a
  curiosity, and the evidence report **cannot reach production through that
  door** — the CLI runs two queries and discards the rest, still true on `main`.
  `INTEGRATION.md` is rewritten around that. It also splits the decision in two:
  adopting the library as a *gate* is available today, adopting it as *evidence*
  needs `opa` in the image or a wider CLI door.
- **Your flag 1 is resolved, in production's favour.** Kosli's server source
  (`kosli-dev/server`, `src/model/types/types.py`) constrains a custom type
  reference to `^custom:.*$`, lists built-in types as bare literals, and forbids a
  colon in a type name. So `custom:initial-commit-by-verified-committer` is what
  the wire carries, production's `four-eyes.rego` was right, and **the port was
  wrong** — its substitute selected on `attestation_type == "custom"` plus a name
  and matched nothing, which made it inert and left every initial commit denied.
  Fixed, with three tests pinning the wrong forms. The guess came from a fixture
  written on this side; that is the lesson, not the typo.
- **Your flag 2 narrowed the fail-open** without removing it: `git_commit_info` is
  at trail root, so the reachable case is an author present and *unreadable*
  rather than a missing object. The added check is unchanged and still earns its
  row.
- **Your flag 3 is now the plan.** `initial-commit-by-verified-committer` being a
  deployed `--schema` + 4×`--jq` custom type is the pattern the `evidence-report`
  type copies. `--summary "NAME=<jq>"` is recorded alongside it, including a
  summary that counts rows whose `cause` is `ambiguous` or `absent` — *the policy
  could not read its inputs*, separated from *the evidence says no*, in the UI.
- **1068's tables now come from `data.params`.** Membership living in a runtime
  fact store means no policy file could ever hold it, so the illustrative lists
  became a fallback behind configuration. Four tests pin it, including that
  supplied tables replace the defaults rather than extending them.
- **The backref test stands**, on your reading of the collector's source.

## Investigation 1 — a pull request with two distinct authors

Unchanged from last round and still the one unproven core behaviour: the
per-author rule (*for every author, some approver who is not that author*) has
met only synthetic input. Both captured pull requests resolve to one author or
none.

This needs live Kosli or GitHub, which round 5 said you lack. If that is still
true, **say so in one line and stop** — it is not answerable by reading, and a
constructed example teaches nothing the test suite does not already assert.

If access appears: find an existing merged pull request whose `commits[]` carry
two or more distinct `author_username` values, then run both policies over it —
production `four-eyes.rego`, and, with the repo present,

```sh
python3 fieldkit/kit.py run examples/control_43.rego <trail>.json \
    --ops examples/control_43_ops.rego
```

which prints one row per (commit, check) with its `cause` in the third column.
Without the repo, production's verdict alone is still worth having. Report counts
and verdicts only — distinct authors (n), approvers (k), how many
approvers also wrote commits, whether the two policies agree, and whether it is a
**mutual review** (each author approved the other). That last case must pass, and
it is where the per-author reading and the "approver who authored nothing"
reading part company.

## Investigation 2 — one real root-commit trail

The corrected substitute has never met data nobody on this side wrote. One real
trail carrying `initial-commit-by-verified-committer` would settle three things at
once:

1. That `attestation_type` reads exactly `custom:initial-commit-by-verified-committer`
   on the wire — the server source says it must, but a deployed type has never
   been observed through `--show-input`.
2. That `is_compliant` sits on the **status entry** (where the port reads it) and
   is a boolean.
3. Whether that attestation can appear on a trail that is **not** a root commit.
   The port treats its presence as the discriminator, so if it can appear
   elsewhere the substitute is wider than intended — this is the one item on the
   list that could make the port *too permissive* rather than too strict, so it
   ranks above the other two.

A sanitised capture would be worth more than prose here, and per your point 6 the
matched fixture pair would make it three.

## Investigation 3 — does the report survive a real attestation?

The report's destination has only ever been dry-run from this side: no request
sent, so **server-side schema validation and jq evaluation are untested**. This
one needs the repo, because the report has to be produced before it can be
attested:

```sh
python3 fieldkit/kit.py run examples/control_43.rego <trail>.json \
    --ops examples/control_43_ops.rego --json > report.json
```

Then, if you have any writable flow, on any instance:

```sh
kosli create attestation-type evidence-report --schema schema/evidence-report.schema.json \
  --jq '.compliant == true' \
  --jq '[.results[] | select(.check == "$well_formed" and .passed == false)] | length == 0'

kosli attest custom --type evidence-report --attestation-data report.json \
  --name evidence-report --flow <flow> --trail <trail>
```

1. Does the schema validate a real report, or does the server reject a shape `jq`
   and `opa` are both happy with?
2. Do the jq rules evaluate, and does the attestation come back compliant for a
   compliant report and non-compliant for a failing one?
3. **Is there a payload size limit?** A report is O(subjects × checks), every row
   echoes the inputs it read, and rows now carry a `cause`. A wide trail is the
   test; the error message, if any, is the finding.

If there is no writable flow, this stays blocked and that is fine — it is recorded
as the one unexecuted claim about the destination, and it will be settled from a
laptop with an org rather than by you.

## What to carry back

Short answers, and "blocked" is a real answer for any of the three:

```
FINDINGS ROUND 6
two-author PR:        <found: n authors k approvers|none reachable|blocked: no live access>
  verdicts:           <both allow|both deny|disagree: ...> | mutual review <y/n>
root-commit trail:    <captured|blocked>
  type string:        <custom:initial-commit-by-verified-committer|other: ...>
  is_compliant:       <on status entry, boolean y/n>
  non-root:           <can appear off a root commit y/n>
report attestation:   <schema validated y/n> | jq evaluated y/n | verdicts correct y/n
  payload limit:      <bytes|no limit hit at N rows|blocked>
KEEP added:           <vocabulary added to sanitize.py, or none>
blocked:              <what you could not reach, and why>
```

Investigation 2 item 3 is the one that could change the port's verdicts. If you
get only that, it was worth the trip.

# Brief 4: check my work on the integration seam

**You are Claude Code on the restricted machine. This round is different in two
ways.** You now have **read access to this repository**, so nothing needs to be
described to you second-hand — read the files. And the primary task is not
discovery, it is **falsification**: I made a series of claims from this side, some
of them by reading source and some by running commands, and several of them
reversed conclusions this project had held for three rounds. Try to break them.

A round that comes back "claim 3 is wrong, here is the file that says so" is worth
more than one that confirms everything.

```sh
git fetch --depth 1 origin integration && git reset --hard FETCH_HEAD
```

## The hard rules have not changed

Restated so this file stands alone:

1. **Nothing leaves unredacted.** `python3 fieldkit/sanitize.py real.json > safe.json`,
   check `--audit` before it travels, add genuine policy vocabulary to `KEEP`
   rather than shipping a fixture whose enums became `redacted-3f21`, and list
   whatever you added.
2. **Never paste raw values into prose.** Field names, types and counts only.
3. **Do not push, open a PR, or write to GitHub.** Read access is read access.
4. **Verify, don't infer.** Every claim from a file you read or a command you ran.
   Otherwise write `blocked:` and say why.
5. **Real inputs live in `fieldkit/scratch/`**, which is gitignored.
6. **Never invent field names.**

## Part 1 — claims to falsify

Each of these is stated in `INTEGRATION.md` with its evidence. The re-check is
cheap; I have given it where it exists.

### A. `kosli evaluate` reads only two rules

I claim its result type is `Result{Allow bool, Violations []string}`; that it runs
exactly `data.policy.allow` (which must be a bool, or hard error) and then, **only
when allow is false**, `data.policy.violations`; and that a non-string element in
`violations` is **silently dropped**, not rejected.

Source: `kosli-dev/cli`, `internal/evaluate/rego.go`. Re-read it. In particular
check whether `collectViolations` has grown an `else` branch since, and whether any
newer CLI version surfaces more of the policy document.

**Falsify by:** finding a version, flag or code path that returns anything else.

### B. `--policy` takes one file, and the library therefore cannot be imported

`--policy` is `string`, not `strings`. `validatePolicy` parses the source as a
**single module** whose package must be exactly `data.policy`.

**Falsify by:** getting `kosli evaluate` to load two `.rego` files, or a bundle, or
a directory. If you manage it, that is the most useful single finding of the round.

### C. Merging works, and I have made it a tested build step

Merging collides on `report` and `violations` — the second structurally, since the
CLI reserves the name and the library has a function of it. `fieldkit/bundle.py`
renames the library's API and then **proves the merge preserved behaviour** by
diffing both forms against the same input:

```sh
python3 fieldkit/bundle.py --policy examples/control_43.rego \
    --ops examples/control_43_ops.rego \
    --verify-with fieldkit/scratch/input.json -o /tmp/policy.rego
```

**Falsify by:** running it against a **real** input document and seeing whether the
verification still passes. It has only ever been run on fixtures I wrote myself. A
real trail is deeper and stranger, and this is exactly the sort of tool that works
on toy input and breaks on the real thing.

### D. The report has a home: a custom attestation type

```sh
kosli create attestation-type evidence-report \
  --schema schema/evidence-report.schema.json \
  --jq '.compliant == true' \
  --jq '[.results[] | select(.check == "$well_formed" and .passed == false)] | length == 0'

kosli attest custom --type evidence-report --attestation-data report.json ...
```

**This is the weakest claim in the round and the one I most want checked.**
Everything about it is `--dry-run` only. No request was ever sent, so server-side
schema validation and jq evaluation are **untested**. `schema/evidence-report.schema.json`
is well-formed and rejects six kinds of malformed report locally, but Kosli's
validator is not the Python one I used.

**Falsify by:** doing it for real against an org you can reach. Does the type get
created? Does a real report pass its own schema? Do the jq rules evaluate to the
compliance verdict you expect? Does a *deliberately* malformed report get rejected?

### E. Control 43 does not use `kosli evaluate`

Round 2 recorded that consumption is "the `opa` binary via `execSync` in a prebuilt
Docker image". I have leaned hard on that, because it means none of A, B or C
constrain the path the team actually uses — on the `opa eval` path the library
imports normally and the whole report is available.

**This is now load-bearing, and it rests on one line from a previous round.**

**Falsify by:** reading the control 43 action and reporting the *exact* invocation.
If it turns out to call `kosli evaluate` after all, most of this round's
conclusions need rewriting, and I would rather know.

## Part 2 — the questions only you can answer

These genuinely need the restricted machine. (The last three briefs each carried
questions that did not — `kosli evaluate`'s contract was answerable from a laptop
with the CLI installed and the source on GitHub, and it sat open for three rounds
anyway. Worth sorting future questions into "needs this machine" and "needs a
terminal" before they go in a brief.)

1. **How is OPA actually invoked** in the control 43 action? The exact command line
   — which files are passed with `-d`, what query is asked for, how the output is
   parsed.
2. **Where does the input document come from?** This is the biggest hole on my
   side. Every report I have produced was computed from a fixture I hand-wrote.
   Something must fetch the trail and feed OPA: `kosli get trail`, `kosli evaluate
   --show-input`, or the collector composing it from its own API calls. Which?
3. **Does anything in `sdlc-workflows` use `kosli evaluate` at all?**
4. **Does any control already use `kosli attest custom --type` with a schema and jq
   rules?** If so, that is a working precedent for claim D and worth copying.
5. **Which CLI version is in the image?** `--summary` (which renders report numbers
   in the Kosli UI) is in the CLI source on `main` but absent from 2.13.1.
6. **Is there a size limit on attestation payloads?** A report is O(subjects x
   checks) and every row echoes the inputs it read, so a wide trail could get big.
   Docs, or a real attempt.
7. **Is DB on `app.kosli.com` or a separate instance?** It changes whether claim D
   transfers at all.

## Part 3 — review the new library work

Two things landed since brief 3, both from your own 1068 hand-over.

**`any_of`** (`src/library.rego`, "subject-level operators"; docs in `README.md`).
Your finding was that independent per-field checks silently over-pass when the real
rule couples two fields. The operator takes named options, each a non-empty array
of leaf checks that must all hold — disjunction of conjunctions, i.e. DNF. Nested
combinators are impossible because Rego forbids the recursion.

Please attack it: is DNF the right primitive, or did I generalise past the evidence
and should this have been narrower? Is there a fail-open I missed? The guards were
mutation-tested (`every`→`some` fails 9 tests; dropping the empty-group guard fails
1; dropping `is_array` fails 1 **only after** I fixed a test that had been passing
for the wrong reason) — but mutation testing only finds what you thought to mutate.

**`examples/control_1068.rego`** and its tests. Two things need your eyes:

- The three flavour tables are **illustrative**, consistent only with the one fact
  that reached me: no single table holds both `Story` and `DONE`. If you can read
  the real membership from source, replace them — and if the real tables make my
  cross-product example wrong, say so.
- `control_1068_test.rego` contains a test asserting the control's real subject
  **cannot be named**, on the grounds that `getJiraIdsFrom` flattens commits to a
  set of ticket ids with no backref. Check that against the source. If a backref
  exists anywhere, that test is wrong and the library is less limited than I have
  been telling people.

## Deliverables

1. Answers to Part 2, which is the part I cannot do from here.
2. Verdicts on A–E, with `refuted:` / `confirmed:` / `blocked:` and the file or
   command behind each.
3. Anything from Part 3.
4. This block, short enough to retype and free of values:

```
FINDINGS INTEGRATION
A evaluate-contract:  <confirmed|refuted: ...>
B single-file:        <confirmed|refuted: multi-file works via ...>
C bundle.py:          <verified on real input|failed: ...|blocked>
D attestation-type:   <works live|refuted: ...|blocked: no org>
E opa-not-evaluate:   <confirmed: exact invocation ...|REFUTED: uses kosli evaluate>
input source:         <kosli get trail|--show-input|collector-composed|other>
evaluate users:       <n places in sdlc-workflows, or none>
custom-type precedent:<control + type name, or none>
cli version:          <x.y.z> | --summary present <y/n>
payload limit:        <bytes, or unknown>
kosli instance:       <app.kosli.com|other>
any_of:               <sound|hole: ...> | DNF <right primitive|over-general>
1068 tables:          <real membership readable y/n> | my example still valid <y/n>
1068 backref:         <none, test stands|EXISTS at <file>, test is wrong>
KEEP added:           <vocabulary added to sanitize.py, or none>
blocked:              <what you could not read or run, and why>
```

Claim E and question 2 are the round. If you get only those, it was worth it.

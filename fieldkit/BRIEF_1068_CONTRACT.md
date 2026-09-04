# Brief 7: control 1068's output contract, and whether anything validates it

**You are Claude Code on the restricted machine.** This brief is a companion to
[BRIEF_OPEN_QUESTIONS.md](BRIEF_OPEN_QUESTIONS.md) (brief 6) and is meant to be
answered **in the same reply** — its findings block is designed to sit directly
below brief 6's. Answer brief 6 first; it has been waiting longer.

**Token budget is the binding constraint this round**, not access. Work top-down
and stop wherever you run out: the questions are ordered so that quitting early
still brings home the valuable half. Do not read files that no question below
names, and do not summarise code back to me — answer the question and cite the
line.

## What this needs, and what it does not

**It needs no repo clone and no `opa`.** Everything asked here is answered by
reading control 1068's own TypeScript on your side. That is the whole reason it
can ride along with brief 6, whose three investigations need live Kosli or GitHub.

You need `fieldkit/sanitize.py` **only if a test fixture travels** (question 3).
If you do not already have it from an earlier round, and only if a fixture is
worth bringing:

```sh
curl -H "Authorization: Bearer $PAT" -H "Accept: application/vnd.github.raw" \
  'https://api.github.com/repos/kosli-dev/rego-evidence-report/contents/fieldkit/sanitize.py?ref=integration' \
  -o sanitize.py
```

**No sanitizer means no JSON comes home.** Prose findings with no fixture is a
good outcome, not a shortfall.

## The hard rules have not changed

1. **Never paste raw values into prose.** Field names, types, counts, operator
   names, enum vocabulary. No hostnames, credentials, logins, emails, shas,
   repo/org/flow names, or JIRA ids.
2. **For TypeScript source specifically:** bring the *structure* — field names
   read, comparisons made, and the enum vocabulary compared against (issue types,
   statuses, resolutions), because vocabulary is meaning. Leave hostnames,
   credentials, and any list enumerating the bank's own projects, teams or
   repositories: for those report **shape and size** ("~40 project keys in
   `config/x.json`"), never the list.
3. **Verify, don't infer.** Every claim comes from a file you read or a command
   you ran. Otherwise write `blocked:` and say why.
4. **Never invent field names.** If you cannot read a name from source, report it
   unknown.
5. Real captures stay in `fieldkit/scratch/` (gitignored) if you have the repo.

## Already established — do not re-derive

The 1068 round settled these. None of it needs to come back:

- The decision lives in `src/checkBusinessRequirements.ts`; collection in
  `src/commitFromGithub.ts`. The control has **no Kosli integration** — facts and
  evidence upload to a factstore Artifactory repo, gated by `upload_to_factstore`.
- The collector **flattens commit messages into a set of ticket ids with no
  backref**, so the commit-to-ticket link is destroyed before any evidence
  exists. `examples/control_1068_test.rego` pins this as the library's first
  documented limit: it *asserts* that the subject cannot be named, and is meant to
  keep asserting it until a collector attests commits with their resolved tickets.
  It passes today — it is a pinned limit, not a failing test.
- The `Permitted` flavour tables are **not in the source at all** — read from an
  external fact store at runtime. Hence `data.params` in the port.
- The control's real subject cannot be named by a path-based `from`.
- This control is why the `any_of` operator exists.

What that round did **not** reach is everything below: its investigations 3, 6
and 7 fell off, which was the right call at the time.

## Question 1 — is anything validating the data it produces? (priority)

This is the question the round exists for. Control 43 has an output contract:
`four-eyes-result-schema.json`, in which `violations` is a `string[]`. **Nobody
has checked whether 1068 has an equivalent, or whether its payload is validated
at all before upload.**

TypeScript types are erased at runtime, so `JSON.parse(x) as Fact` validates
nothing. Start with greps rather than reading files — they are far cheaper and
may answer this outright:

```sh
grep -rnE 'zod|ajv|joi|yup|superstruct|io-ts|typebox|jsonschema|\.validate\(' src/
grep -rnE 'JSON\.parse|\bas [A-Z][A-Za-z]*|satisfies ' src/ | head -40
find . -name '*schema*.json' -not -path './node_modules/*'
```

Report:

1. **Does a result/fact schema file exist?** If yes, its shape — and in
   particular whether `violations` is a `string[]` again or something richer.
2. **Is the uploaded payload validated at runtime, or only typed?** Name the
   library and call site if it is validated; say "types only" if the answer is a
   cast. "Types only" is a finding, not a gap in your work.
3. **The shape of a "fact" versus an "evidence"** — the two things uploaded to
   factstore. Field names and types only.
4. **What differs between the pass and fail payloads?** The 1068 README says
   facts upload "irrespective of whether control fails or passes" and "might
   change depending on" the outcome. Which fields actually differ?
5. **Does anything parse the violation text verbatim** — a dashboard, a ticket
   automation, a report? For control 43 this made a message-format change a
   schema break; check whether the same trap exists here.

If a consumer exists that reads the payload, **it is the real contract** — more
so than any schema file. Say what reads it.

## Question 2 — the four fail-opens

Round 2 found two fail-opens in production's four-eyes policy, both hiding in "we
only look at things that are present". 1068's own README has the same smell:
*"validation is currently done only on Jira tickets extracted from the commit
messages."* A commit that yields no ticket contributes nothing to validate.

Answer each **with a line number**, one line each:

1. A commit whose message references **no** Jira ticket — pass, fail, or silently
   skipped?
2. A referenced ticket **Jira does not return** (deleted, no permission, typo) —
   fail-closed, or dropped from the list?
3. **Several tickets on one commit**, one of them `Non-Permitted` — does the
   commit fail, or is any-permitted enough?
4. A ticket that **is** returned but is **missing the field the predicate reads** —
   what does the comparison do with `undefined`?

And the one that matters most: **what happens when the Jira API call itself
fails** — does the control fail, pass, or crash? A control that passes when its
evidence source is down is the worst of the three.

## Question 3 — the tests

Cheapest possible specification, and on the 43 round the tests were the artefact
that settled a contradiction between two prose documents. Keep this short:

- **how many tests** exist for `checkBusinessRequirements.ts`, and what they cover
  in one line
- whether any of the four cases in question 2 is **pinned by a test**
- any behaviour the tests pin that **no document mentions**
- whether a **fixture** is worth bringing: unit-test fixtures are often synthetic
  already, but run it past the sanitizer and use judgement

## What to carry back

Append this below brief 6's block, in the same message. Short answers; `blocked`
is a real answer:

```
FINDINGS ROUND 7 (control 1068 output contract)
schema file:      <exists: path|none> | violations type <...>
runtime validation: <library + call site|types only, cast at line ...|none>
fact shape:       <field names/types>
evidence shape:   <field names/types>
pass vs fail:     <fields that differ>
verbatim consumer: <what reads the text|none found|unknown>
noticket:         <pass|fail|skipped> (line: ...)
notfound:         <fail|dropped> (line: ...)
multi:            <commit fails|any-permitted passes> (line: ...)
missingfield:     <undefined comparison behaviour> (line: ...)
apidown:          <fail|pass|crash> (line: ...)
tests:            <n> | four cases pinned <which> | undocumented <...>
fixture:          <sanitised + brought|none worth bringing|blocked: no sanitizer>
KEEP added:       <vocabulary added to sanitize.py, or none>
blocked:          <what you could not read, and why>
```

## Why these questions and not a review

You could be asked to review this code generally, and that would cost far more
and settle less. Every question above is one whose answer changes something on
this side: a payload validated only by a cast changes what the port has to
guarantee itself; a fail-open changes whether the ported policy may copy the
original's structure; a verbatim consumer turns a message format into a schema.

`apidown` is the single most valuable line in the block. If you get only that one,
the trip was worth it.

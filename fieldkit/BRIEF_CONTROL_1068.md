# Brief 3: control 1068 (business requirements) against kosli.evidence

**You are Claude Code on the restricted machine with access to real Deutsche Bank
systems and the control 1068 source. This is the third round.** Read `BRIEF.md`
for the hard rules and `BRIEF_CONTROL_43.md` for what rounds 1–2 settled; don't
re-derive either. Work the investigations in order.

First, get the current code — this work lives on a branch:

```sh
git fetch --depth 1 origin integration && git reset --hard FETCH_HEAD
```

## The lesson from round 2, applied up front

Your own closing note from round 2 was: *"It wasn't missing data; it was missing
architecture."* Two rounds asked for fixtures when one policy file would have
collapsed all the guessing. That was right, and this brief is built on it.

For control 43 the architecture was a file — `four-eyes.rego` — because 43 had
already been split into a thin collector plus a Rego rule. **Control 1068 has not
been split.** Its rule lives in TypeScript, mixed in with collection, Jira
mutation and evidence upload. So there is no equivalent file to hand over, and the
architecture question is harder rather than easier: **where is the decision, and
what exactly does it decide?**

Everything below is in service of that. If you get investigations 1 and 2 and
nothing else, the round was worth it.

## What this is about

Control 1068 (`RCTLDEF0001068`, business requirements for release) checks that the
code being released traces back to approved business requirements. The
implementation we have documentation for works like this, per its `README.md`:

1. `src/commitFromGithub.ts` pulls commits from the repo over the GitHub API.
2. `src/checkBusinessRequirements.ts` receives them and decides. It extracts Jira
   ticket references from commit messages, calls the Jira API for ticket detail,
   and marks each ticket `Permitted` or `Non-Permitted` "based on the requirements
   agreed with the control owner".
3. Any `Non-Permitted` ticket fails the control. If all tickets are `Permitted`, a
   Jira **fix-version is created and assigned to the tickets** and the control
   passes.
4. Facts and evidence upload to a factstore Artifactory repo either way, gated by
   `upload_to_factstore` since image `1.2.4.1`.

It also supports Nx monorepos: with `ENABLE_NX_SUPPORT=true` and a `SERVICE_NAME`,
only commits belonging to that one application count, between `BASE_TAG` and
`CURRENT_TAG`.

That is everything the README says about the rule. Note what is missing: the
sentence "based on the requirements agreed with the control owner" **is** the
control, and it is the one thing the document declines to state.

We want to know whether `kosli.evidence` (this repo) can express control 1068. Not
because 1068 is urgent, but because it is the first control that is **not**
four-eyes. `four-eyes.rego` is still the only Rego policy in `sdlc-workflows`, so
every abstraction in this library has exactly one witness. A second control is the
only thing that can distinguish "this abstraction is general" from "this
abstraction restates the single case we looked at". A better fixture for 43 cannot.

## Hard rules

Unchanged from rounds 1 and 2, and one addition for source code:

1. **Nothing leaves this machine unredacted.** Run any document through
   `python3 fieldkit/sanitize.py real.json > safe.json`, check
   `--audit` before it travels, and add genuine policy vocabulary to `KEEP` rather
   than shipping a fixture whose enums became `redacted-3f21`. List anything you
   add to `KEEP` in your findings.
2. **Never paste raw values into prose.** Field names, types and counts only.
3. **Do not push, open a PR, or write to GitHub.**
4. **Verify, don't infer.** Every claim must come from a file you read or a command
   you ran. Otherwise write `blocked:` and say why.
5. **Real inputs live in `fieldkit/scratch/`** — gitignored, so `git reset --hard`
   won't destroy them and they can't be committed by accident.
6. **Never invent field names.** If you cannot read a name from source or real
   output, report it as unknown.
7. **New, for TypeScript source.** The sanitizer handles JSON, not code. Source
   files are usually safe — logic is field names and comparisons — but this
   control talks to Jira, so expect embedded project keys, hostnames and possibly
   a hardcoded list of the bank's own project or component identifiers.
   - *Bring:* the predicate's structure, the field names it reads, and the **enum
     vocabulary** it compares against (issue types, statuses, resolutions).
     Vocabulary is meaning; without it the rule is unreadable.
   - *Leave:* hostnames, credentials, and any list that enumerates the bank's
     internal projects, teams or repositories. For those, report the **shape and
     size** — "compared against a list of ~40 project keys held in
     `config/x.json`" — not the list.

## Already established — do not re-derive

From rounds 1 and 2:

- A `kosli get trail` response has `compliance_status.attestations_statuses` as an
  **array** of `{attestation_name, attestation_type, status, is_compliant, ...}`;
  the per-artifact list is **empty**; timestamps are **epoch numbers**; `trail.name`
  is the subject id; `user_data` is a JSON-encoded string.
- `status: "COMPLETE"` means *reported*, not *passed*. `is_compliant` is the
  verdict. Asserting only `status` is a fail-open, and real data contains
  `COMPLETE` with `is_compliant: false`.
- Consumption is the `opa` binary via `execSync` in a prebuilt Docker image; one
  fixed policy per control; nothing varies policy at runtime.
- The library gained, for control 43: `matches_any`/`not_matches_any` for exemption
  lists, epoch support in `compare_time`, and a `{"where": {...}}` path selector
  that picks one element out of an attestation array by its `attestation_type`.
- The library **runs every check** — there is no first-match-wins ordering, so one
  subject can produce several failing rows where the current tools report one
  reason.

Still open from round 2, and cheap to answer while you have a CLI:

- Does `kosli evaluate --policy` accept **more than one `.rego` file** (or a
  directory/bundle)? `kosli.evidence` is a library in its own package that a
  policy imports; if only one file is accepted it must be vendored or
  concatenated.
- Does `--output json` surface the **whole policy document**, or only `allow` and
  `violations`? If only the latter, the evidence report doesn't survive the CLI
  boundary and would have to travel as an attestation instead.

## Investigation 1 — the rule, and which document is authoritative

**1a. The requirement, not the implementation.** Round 2's naming pass taught us
to separate the two: `SDLC-CTRL-0007` is Kosli's published control catalogue — the
requirement — while `RCTLDEF0000043` is a customer's control register, an
implementation of it. Expect the same split here, and the README hints at it: *"as
per the agreement with control owner validation is **currently** done only on Jira
tickets extracted from the commit messages."* "Currently" means the stated
requirement is broader than the code.

So read the Confluence page the README links, and report:

- what the control **requires**, in requirement-shaped sentences — subject, and
  what must be true of every one of them
- which parts the implementation covers and which it doesn't
- whether Kosli publishes a matching control in its own catalogue
  (`https://sdlc.kosli.com/controls/`), and under what name

**1b. The predicate.** Then `src/checkBusinessRequirements.ts`, whole. Report:

- exactly which **Jira fields** decide `Permitted` vs `Non-Permitted`, and the
  values or patterns each is compared against
- whether the comparison is a hardcoded table, a config file, or an env var — and
  if it's a file, whether that file could travel
- whether "Permitted" is one predicate or several combined, and how they combine
- anything the code checks that the README doesn't mention

## Investigation 2 — the subject, and whether the library can even name it

This is the structural question, and it may be the one that breaks the library.

The chain is: **commits** → ticket references **parsed out of commit message
strings** → **tickets**, whose detail comes from a *second API*. That is a subject
derived from another subject by parsing text and then fetching. This library's
`from` is a **path into the input document**; it can select and filter, but it
cannot parse a string into subjects, and it cannot fetch.

Which means the answer hinges entirely on where the flattening happens. Report:

- **What is one Kosli trail here?** One per commit, as in 43? One per release?
  Something else? What is `trail.name`?
- **What does the attestation payload look like** — the attestation type name, and
  whether the tickets arrive as a flat list of resolved ticket objects (with the
  Jira fields from investigation 1b already on them), or whether only commit
  messages arrive and something downstream still has to parse them.
- **Does the commit→ticket link survive** into the payload? A policy that must
  report "commit X references no approved requirement" needs to see both ends. If
  the payload is a bare ticket list with the commits dropped, that link is gone
  and the control can only speak about tickets.
- If 1068 has no Kosli integration at all yet and uploads only to factstore, say
  so plainly — then the question becomes what the collector *would* attest, and
  the answer is a design decision rather than a discovery.

## Investigation 3 — the four fail-open questions

Round 2 found two fail-opens in the production 43 policy, both hiding in "we only
look at things that are present". This README has the same smell: *"validation is
currently done only on Jira tickets extracted from the commit messages."* If a
commit yields no ticket, it contributes nothing to validate — and if validation
only looks at tickets, that commit passes by never being looked at.

Read the code and answer each with a line number:

1. A commit whose message references **no** Jira ticket — pass, fail, or silently
   skipped?
2. A referenced ticket the **Jira API doesn't return** (deleted, no permission,
   typo in the key) — fail-closed, or dropped from the list?
3. **Several tickets on one commit**, one `Non-Permitted` — does the commit fail,
   or is any-permitted enough?
4. A ticket that **is** returned but is missing the field the predicate reads —
   what does the comparison do with `undefined`?

Also: what happens when the **Jira API call itself fails** — does the control fail,
pass, or crash? A control that passes when its evidence source is down is the
worst of the three.

## Investigation 4 — the side effect, and where the boundary falls

Control 43 was a pure verdict. This one **mutates Jira on the pass path**: it
creates a fix-version and assigns it to the tickets. A Rego policy cannot do that
and shouldn't.

So the port needs a boundary, and its placement depends on one thing: is the
fix-version a **consequence** of passing, or a **precondition** of it? Report:

- the order of operations in the code — is the verdict computed, then the
  fix-version created? Or does creating it feed back into the verdict (e.g. failure
  to create means failure of the control)?
- what the **evidence** ends up asserting: "these tickets were permitted", or
  "these tickets were permitted *and* tagged"? If the fix-version id lands in the
  attestation, then the tag is part of the claim.
- what happens on **re-run** — is fix-version creation idempotent? If the control
  is evaluated twice, does the second run behave differently?

If the answer is "consequence", the port is clean: policy returns the verdict, the
workflow acts on it. If it's "precondition", then the thing being attested isn't a
pure function of the input and the report can't be recomputed from the row —
which is a genuine limit of this library, worth knowing.

## Investigation 5 — the scope filters

Two things in the README map onto `applies_to`, and they'd be the **first
independent evidence that scope filters are a general feature** rather than a
service-account workaround invented for 43:

- `ENABLE_NX_SUPPORT` + `SERVICE_NAME`: only commits belonging to one application
  count.
- `BASE_TAG` / `CURRENT_TAG`: the subject set is a commit range.

The question that decides whether they're library features at all: **is the
filtering done before Kosli sees the data, or during the decision?** If
`commitFromGithub.ts` already narrows the commit list, then scope is the
collector's job and the policy never sees an out-of-scope commit — in which case
`applies_to` gains no second witness here. If instead everything is attested and
the decision filters, that's a real scope filter and it belongs in the policy.

Report which, with the line that does the narrowing. Also: how does the code decide
a commit "belongs to" an Nx project — a path prefix, `nx affected`, something else?

## Investigation 6 — the output contract

- Is there a **result schema** for 1068, as `four-eyes-result-schema.json` is for
  43? If so, its shape: is `violations` a `string[]` again, or something richer?
- What is actually **uploaded to factstore** — the shape of a "fact" and of an
  "evidence", and whether either is consumed by anything that would break if the
  format changed.
- Does anything parse the violation text **verbatim** — dashboards, tickets,
  reports? Round 2 established that for 43 a message format change is a schema
  break; check whether the same is true here.
- The README says facts upload "irrespective of whether control fails or passes"
  and "might change depending on" the outcome. What differs between the two?

## Investigation 7 — the tests

Test cases are the cheapest possible specification, and for 43 they were the
document that settled a contradiction between two prose files. Report:

- how many tests exist for `checkBusinessRequirements.ts`, and what they cover
- **their fixtures** — a unit-test fixture is often synthetic already and may
  travel safely; run it past the sanitizer and use judgement
- any behaviour the tests pin that no document mentions — especially around the
  four questions in investigation 3
- whether there's a scenarios document like 43's `SCENARIOS.md`

## Investigation 8 — draft the requirements (stretch)

Only if 1–7 are done. Sketch 1068 as a `kosli.evidence` policy using
`fieldkit/policy_template.rego`, which carries the whole operator vocabulary in its
comments, and run it:

```sh
python3 fieldkit/kit.py run fieldkit/scratch/c1068.rego fieldkit/scratch/input.safe.json
```

Expect the `Permitted` predicate to need a custom op if it's anything more than a
field comparison — that's the escape hatch working as designed. What matters is
**which parts the declarative vocabulary couldn't reach**, one line each. Two
specific things to check:

- Can the requirement's subjects be named at all with a path-based `from`, given
  investigation 2's answer?
- Does the "every commit traces to a permitted requirement" shape work, or does the
  policy end up able to say only "every ticket is permitted" — which is a weaker
  claim, since it says nothing about a commit that referenced nothing?

## Deliverables

1. **`src/checkBusinessRequirements.ts`**, and whatever config holds the
   `Permitted` vocabulary. The priority — this is the control.
2. A **sanitized real input** if 1068 has a Kosli integration: the attestation
   payload, `--audit` checked. If it has none, say so; don't manufacture one.
3. Test fixtures, same treatment.
4. This block, filled in, kept short enough to retype and free of values:

```
FINDINGS 1068
requirement:  <what the control REQUIRES, one line> | source: <confluence|kosli|code>
gap:          <what the implementation doesn't cover, from the "currently" hedge>
predicate:    Permitted iff <jira fields + comparisons> | held in <code|config|env>
kosli:        <trail per commit|per release|NO kosli integration yet>
attestation:  type=<name> | tickets arrive <resolved objects|raw messages|n/a>
link:         commit->ticket survives into payload <y/n>
noticket:     commit with no ticket ref = <pass|fail|skipped> (line: ...)
notfound:     ticket Jira won't return = <fail|dropped> (line: ...)
multi:        one Non-Permitted of many = <commit fails|any-permitted passes>
apidown:      Jira API failure = <fail|pass|crash>
fixversion:   <consequence of passing|precondition of it> | in attestation <y/n> | idempotent <y/n>
scope:        Nx/SERVICE_NAME filters in <collector|decision> (line: ...) | belongs-to = <how>
range:        BASE_TAG..CURRENT_TAG resolved in <collector|decision>
schema:       <result schema exists y/n> | violations type <...> | verbatim consumers <y/n>
tests:        <n> | fixtures brought <y/n> | undocumented behaviour <...>
evaluate:     --policy multi-file <y/n> | --output json shows whole document <y/n>
KEEP added:   <vocabulary added to sanitize.py, or none>
vocabulary:   <what the library couldn't express, one line each>
subjects:     <can `from` name the subject at all: y/n + why>
blocked:      <what you could not read or run, and why>
```

## Why this round matters more than a better fixture

Every feature in `kosli.evidence` was added while looking at exactly one control.
`applies_to`, `not_matches_any`, the `where` selector, epoch `compare_time` — all
of them earned their place against four-eyes, and none has a second witness. Two
policies for the *same* control test fidelity; they cannot test generality.

1068 is unlike 43 in every dimension that matters: its subject may not be a commit,
its evidence comes from a second system, its predicate is a business agreement
rather than a structural property, and it has a side effect. If the library
expresses it without new vocabulary, that's the first real evidence the abstraction
is general. If it can't, the specific thing it can't do is worth more than another
passing test — and investigation 2 is the place it's most likely to break.

Say so plainly either way. A brief that comes back "the library can't name this
control's subjects" is a success.

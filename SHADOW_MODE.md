# Shadow mode for control 43 — plan and task list

Target: Monday 2026-09-14, mobbing with the control's owners, integrating
`kosli.evidence` into their real CI workflow **deciding nothing**.

**This repo is public.** So this file names no customer, no internal register id
and no internal repository — "the control's owners", "their workflows repo",
"the restricted laptop". Keep it that way when editing it.

## What "shadow mode" means here, precisely

`four-eyes.rego` is **itself already in shadow mode** — it does not gate
anything today (INTEGRATION.md, line 1 of the status facts). So this is one
shadow evaluation placed beside another, and the honest framing in the room is
"two shadows, compared", not "challenger vs. incumbent gate".

What that buys is the one thing the parity harness structurally cannot do. The
harness feeds 23 synthetic inputs to the port and to a **vendored copy** of
`four-eyes.rego`; it cannot see that copy drifting from what is deployed, and at
the last refresh (2026-09-07) it had drifted in five verdict-changing ways, of
which the harness caught **one**. Real trails, continuously, at no risk, close
that. They also supply the two shapes nobody has ever observed: a pull request
with **two distinct authors**, and a **root-commit trail**.

## Three increments. Stop the mob after V1

| | what | needs | risk |
| --- | --- | --- | --- |
| **V1** | verdict parity on real trails | a bundle file + one extra workflow step | one added step, `--no-assert`, nothing gated |
| **V2** | the report out through `violations` | V1 + an evidence-mode branch in the policy (**not written yet**) + a custom attestation type | a second full evaluation per run; a deliberate forced denial on a field with a published contract |
| **V3** | Excel exporter over the report | V2 + schema-driven exporter (unstarted) | — |

V1 is the whole value of the morning. V2 is worth **scaffolding** on the day
(decide the attestation name, agree who can create the type) and building after.

## V1, two routes. Do the offline one first

**Route A — offline, over a document the workflow already captures.** Control
43's own README says its input document is produced with `kosli evaluate trails
… --show-input`. So a real document may already exist, or costs one CI run to
produce. Then:

```sh
opa eval -d bundle.rego -i input.json --format=pretty 'data.policy.allow'
python3 fieldkit/kit.py run examples/control_43.rego input.json \
    --ops examples/control_43_ops.rego     # one row per (commit, check), with cause
```

No API call, no pipeline change, no CI permissions. **Every real-data question
except "does it run in their CI" is answerable this way**, and it is where the
two-author PR and root-commit shapes get read. Start here; it can be done before
touching a workflow file.

`kosli evaluate input` is the CLI-native version of the same thing (INTEGRATION.md
infers it is present on that image, which is ≥ 2.18.0). It is **not** in 2.13.1,
so it has never been run here — see task 5.

**Route B — a second step in the workflow.** The existing evaluation step is:

```sh
kosli evaluate trails <SHAS…> \
  --attestations "<pr-attestation-name>,initial-commit-by-verified-committer" \
  --flow <flow> --no-assert --output json \
  --policy four-eyes.rego
# verdict read with: jq -r '.allow'
```

The shadow step is that command with `--policy bundle.rego`, its `.allow`
compared and logged, never gating:

```sh
kosli evaluate trails <SHAS…> \
  --attestations "<pr-attestation-name>,initial-commit-by-verified-committer" \
  --flow <flow> --no-assert --output json \
  --policy evidence-bundle.rego > shadow.json || true

test "$(jq -r '.allow' shadow.json)" = "$(jq -r '.allow' incumbent.json)" \
  || echo "::warning::shadow verdict differs on $SHAS"
```

`--no-assert` is exit-code hygiene only: stdout carries the full JSON either
way, because the printer runs before the deny error. Keep the `|| true`
regardless — a shadow step must not be able to fail the job.

## The constraints this design is pinned by

All verified; pointers are INTEGRATION.md section titles.

| constraint | consequence |
| --- | --- |
| `--policy` takes **one file**, parsed as a **single module**, package exactly `policy` | `fieldkit/bundle.py` is mandatory, not a convenience, and OPA's own bundles do not help — *One door, not two*, and the section below |
| `kosli evaluate` runs exactly **two queries** (`allow`, and `violations` only on denial) | the report does not come out of this door — *The report does not survive `kosli evaluate`* |
| `violations` is `[]string`; non-strings are **silently dropped** | V2 encodes one JSON row per element; a set, so order is not meaningful — *The third path* |
| `violations` is **not capped** (50,000 rows / 16.4 MB round-tripped) | V2 is viable with no CLI or image change |
| attestation payload limit is **10 MB** ≈ 2,290 commits at 4.6 KB/commit | fine for a release; `--attachments` is the way past it |
| `--attestations` passes exactly **two names** | a policy reading a third finds nothing and fails closed. The port selects by `attestation_type`, so both survive the filter. |
| a custom attestation type is referenced as **`custom:<name>`** | the substitute selector; the port got this wrong once and every root commit was denied |
| all timestamps are **epoch numbers** | `compare_time` epoch form, not RFC3339 |

## OPA's own bundles, and why `bundle.py` is still needed

Worth settling before Monday, because it comes up the moment anyone sees a
python script concatenating Rego files.

OPA does have native bundling: `opa build` produces a gzipped tarball holding
the modules, a merged `/data.json`, a `.manifest`, and optionally
`.signatures.json`. Verified here on opa 1.19.0:

```sh
opa build -o bundle.tar.gz src/library.rego examples/control_43.rego examples/control_43_ops.rego
opa eval -b bundle.tar.gz -i <input>.json 'data.control43.allow'      # works
```

**It does not help on the `kosli evaluate` path**, for a reason that is about
Kosli's CLI and not about OPA. That CLI reads the `--policy` file as Rego
*source text* and hands it to `rego.Module("policy.rego", src)`, with the
package required to be exactly `policy`. A tarball is not Rego source, and there
is no `opa build` invocation that emits one `package policy` module:

- a plain build keeps the input files as they are, in their own packages;
- an optimized build (`-O=1 -e control43/output`) emits
  `optimized/control43.rego` **and** `optimized/kosli/evidence.rego` — still two
  modules in two packages, alongside copies of the originals. Checked.

So `fieldkit/bundle.py` is not a home-grown substitute for OPA bundling. It is a
workaround for a CLI that does not use OPA's loader. Framing it that way also
makes the fix obvious, and it is the same fix as the one that would surface the
report.

**Answer the question this way if it comes up, and move on.** Bundling
everything into the one file is the plan; `bundle.py` is how, and it verifies
each bundle behaviour-identical as it goes.

One thing from OPA's bundle format is worth wanting later, independently of the
loader. `opa build -b <dir> --signing-key key.pem --revision <rev>` produces a
JWT over per-file SHA-256 hashes plus a bundle revision — checked. The existing
workflow already attaches the policy file to the attestation
(`--attachments <policy>`), recording the verdict together with the rule that
produced it; signing is that instinct done properly, applying this library's
hashable-artefact property to the rule rather than only to the evidence. Not a
Monday item.

## Can a YAML-authored control reach production? Yes, compiled

The single-file constraint blocks loading a data document **at runtime**. It does
not block YAML or Markdown as the *authoring* surface, because a requirements
object is plain data and plain data is a legal Rego literal. Verified here:

```sh
# read the YAML spec out as JSON, emit it as a Rego module
opa eval -d examples/control_43_spec/data.yaml --format=json 'data.requirements'
# -> package inlined \n requirements := { …that JSON… }

opa check --strict inlined.rego                                    # clean
data.inlined.requirements == data.control43.requirements           # true
report(input, data.inlined.requirements) == data.control43.report  # true
```

So the YAML spelling of control 43 — 4.1 KB of JSON, two requirements, both
custom ops named — inlines into a single `package policy` module, type-checks
strict, is the same object as the Rego spelling, and produces the same report.

**That makes it a `bundle.py` feature, not a blocker.** A `--spec <data.yaml>`
flag that emits `requirements := <literal>` into the bundle is the whole change,
and it is the same last mile the Markdown transpiler already stops one step
short of: that transpiler compiles prose to an object, and this turns an object
into the one file the CLI accepts.

Three consequences to be straight about:

- **What gets committed and attached is generated Rego.** So the YAML (or the
  Markdown) has to be the reviewed source of truth, and the bundle needs the
  provenance header naming the source and its hash. `bundle.py` already writes a
  header and already verifies each bundle behaviour-identical.
- **It does not recover the `--params` override.** `web_flow_patterns` is "read
  from `data.params`, else these literals", which is computation, not data — the
  YAML holds the defaults and loses the override, and inlining changes nothing
  about that. The Rego shim around the requirements object keeps that logic.
**Decided: everything gets bundled into the one file.** The runtime
alternatives — mounting the object at `data.params`, or waiting for the CLI to
load a bundle — are not being pursued, so nothing here depends on an unobserved
CLI feature or on somebody else shipping a change.

None of this is on the V1 path either; V1 runs `examples/control_43.rego`, the
Rego spelling. It matters because "controls authored as YAML or prose" was the
part of the demo the room reacted to, and the answer is a build step we own.

## Task list

### Before Monday — needs someone else, so ask today

1. **Which repo, flow and branch does the mob use?** Needs to be a pipeline that
   actually produces trails with PR attestations, and a flow we may attest to.
2. **Get one real `--show-input` document.** This unblocks route A entirely and
   is the single highest-value item on this list. If it has to leave the machine
   it was captured on, redact it first: `python3 fieldkit/sanitize.py real.json >
   safe.json`, then check `--audit`.
3. ~~**The `four-eyes.rego` ref.**~~ **Closed 2026-09-11: we are in sync.** The
   2026-09-07 capture is md5 `6daf6919ede1925a1509d3ebe143fa54` / sha256
   `51d131921a6971dc…`, matching the hash in
   `examples/four-eyes.vendored.rego`'s header, and confirmed against their side.
   So a divergence seen on Monday is a real divergence, not our copy being stale
   — which is the first thing to rule out in the triage list below, and it is now
   ruled out in advance. The *ref* is still unrecorded; that matters for the next
   refresh, not for Monday.
4. **Who can run `kosli create attestation-type`** in that org? V2 only, but the
   answer takes days and the ask takes a minute.
5. **What `kosli version` does the CI image run?** INTEGRATION.md *infers* ≥ 2.18.0
   from `--no-assert` being present. `--params` and `kosli evaluate input` are
   inferred from that, and both are load-bearing for V2. One `kosli version` line
   in a workflow run settles it. (Locally we are on **2.13.1**, which has
   neither; stable is 2.39.2.)

### Before Monday — ours

6. **Upgrade the local CLI** (`brew upgrade kosli-cli`, 2.13.1 → 2.39.2) and
   rehearse `--params` and `kosli evaluate input` against the stub API, so
   neither is first met in the mob. Note that several documented claims were
   measured on 2.13.1; re-check rather than assume on the new one.

   For the record, on 2.13.1 `kosli evaluate trails` has exactly six flags —
   `--attestations`, `--flow`, `--help`, `--output`, `--policy`, `--show-input`.
   There is no way to pass data beside the policy and `--policy` is not
   repeatable, which is why everything gets bundled.
7. **Decide how the bundle reaches their repo.** Two options: commit the
   generated `evidence-bundle.rego` into their workflows repo (simple; drifts
   silently), or vendor `library.rego` + the policy + `bundle.py` and generate in
   CI (no drift; three more files and a python step). Recommend the first for
   V1, with the bundle header carrying the source content hashes, and revisit at
   V2. `bundle.py` already verifies each bundle behaviour-identical and writes a
   provenance header.
8. **Write the verdict-comparison step** as a paste-ready snippet (the two `jq`
   lines above, plus a line naming each divergent sha) so the mob edits YAML
   rather than inventing shell.
9. **Optional, and the biggest single item: the V2 evidence-mode branch.** It is
    written up in INTEGRATION.md (*The third path*) and **not implemented** — no
    `data.params.mode` anywhere in `examples/`. It needs: the mode switch,
    `allow := false` under it, `violations` as one JSON-encoded row per element
    plus one element for the report's top-level fields, a bundle verification,
    and tests. Half a day. Do it before Monday only if V2 is on the agenda;
    otherwise it is the follow-up.
10. **Also optional: `bundle.py --spec <data.yaml>`**, inlining a data-authored
    requirements object into the bundle as a Rego literal. Verified to work
    above; an hour or two, mostly the provenance header and a test that the
    inlined object equals the Rego spelling. Worth having if anyone in the room
    asks whether the YAML they saw in the demo can actually ship.

### If the mob runs on the restricted laptop

That changes the setup, and it is where the morning gets eaten if it is not
prepared. What the field rounds established about that machine:

- **Pull but not push.** Nothing committed there comes home. Findings travel as
  text; fixtures travel only through `sanitize.py`.
- **Round 6 had no `kosli` binary and no mirror**, and GitHub was unreachable
  behind a proxy returning `407 CONNECT tunnel failed`. `opa` and `python3` were
  available.
- So: **`opa`, `python3`, a recent `kosli`, and the repo at branch `integration`
  all need to be on that laptop before Monday.** Verify with
  `opa test src examples --ignore '*.json'` → 428/428 and `kosli version`.
- `authoring/` needs Node and network; assume it is unavailable and do not put
  the Markdown surface on the agenda there.
- Editing their workflow YAML and pushing to *their* internal git presumably
  works — confirm, because route B depends on it.

```sh
git clone --branch integration https://github.com/kosli-dev/rego-evidence-report.git
```

The repo is internal, not private, so any org member can clone it; it is ~30 KB
of text, which completes inside a short-lived proxy credential. If git auth is
the problem but HTTPS works, `src/library.rego` alone is enough to evaluate a
policy — the library has no dependencies.

### In the mob, in this order

Budget assumes a half day.

1. **(20 min) Orient.** [START_HERE.md](START_HERE.md), then one report on
   `demo/trail_self_approved.json`. Everyone runs it themselves.
2. **(30 min) Route A on real data.** `kit.py shape` on the real document first —
   it prints paths, types, and how many siblings carry each field, and **never a
   value** — then `kit.py run`. Read `cause` before reading `passed`.
3. **(20 min) Bundle it.** `python3 fieldkit/bundle.py --policy
   examples/control_43.rego --ops examples/control_43_ops.rego --package
   control43 --verify-with <real>.json -o evidence-bundle.rego`. It prints
   *report identical before and after the merge*; that line is the deliverable.
4. **(45 min) Route B.** Add the shadow step to the workflow, `--no-assert`,
   `|| true`, verdict compared and logged. Run the pipeline once.
5. **(30 min) Read the first divergence.** There will be one. Triage it with the
   table below before anyone changes a policy.
6. **(20 min) Decide V2.** Attestation name (**must not** be where
   `four-eyes-result` lands — that schema expects one human string per failing
   commit), who creates the type, whether the evidence-mode branch is ours.
7. **(15 min) Write down what to carry back.**

### Triaging a divergence

Four causes, in the order to rule them out:

1. **Our vendored copy is stale** — task 3 above. Check first; it was the answer
   last time.
2. **The port is right and the incumbent is wrong.** Four defects are reproduced
   and documented (INTEGRATION.md → *Four defects in the current policy*):
   a string approval timestamp always counting as after the cutoff, a commit with
   no timestamp not raising the cutoff, two `pull_request` attestations crashing
   evaluation outright, and one commit already producing two violation strings.
   Any of these appearing on real data is a **finding worth the whole exercise**,
   and belongs to the control's owners either way.
3. **A selector matches nothing.** The failure mode to fear, because it denies —
   the safe direction — and so hides itself. The tell: a `cause` of `unmatched`
   or `absent` on a check whose evidence you know exists, or a substitute that
   never once reports `substituted` across a whole report.
4. **A real breach.** `cause: value`.

### What to write down

If the mob runs on the restricted laptop, nothing you produce there can be committed
back, so the notes are the whole output. Field names, counts, operator names —
**no logins, emails, shas, org/flow/repo names or JIRA ids**, so that what you
write down can travel.

1. Verdicts: how many trails, how many agreed, and for each divergence the
   check name and its `cause`.
2. Did a **two-author** pull request appear? Distinct authors (n), approvers (k),
   how many approvers also wrote commits, whether it was mutual review, whether
   both policies agreed. This is the unproven core behaviour.
3. Did a **root-commit** trail appear? Does `attestation_type` read
   `custom:initial-commit-by-verified-committer` on the wire, and is
   `is_compliant` a boolean on the status entry? Both are settled from source and
   never observed.
4. Any check that failed for the **wrong reason** — and whether `cause` made that
   distinguishable.
5. Scale: subjects, rows, and whether evaluation was noticeably slow.
6. `kosli version` from the image.

### Explicitly not Monday

- Gating on the port. Nothing about this exercise changes what decides.
- Control 1068 / the second-control cost measurement.
- The Excel exporter.
- The Markdown authoring surface. It works and it demos well; it is not on the
  integration path and needs Node.
- Open-sourcing. Needs a `LICENSE` decision and a pass over the internal
  identifiers in this file, INTEGRATION.md and `fieldkit/`.

## Unknowns to settle in the room, not before

- Where the shadow verdict is **recorded** — a step annotation is enough for V1;
  the existing generic user-data attestation already carries the whole result
  JSON and could carry a second field instead.
- Whether the incumbent and shadow steps should share one `--show-input`
  capture rather than each fetching (n+1 API calls per trail, so this is a real
  cost at scale).
- Whether the loosening in the 2026-09-07 branch —
  `authors_resolved_or_approvers_resolved`, which lets an unattributable commit
  pass on the strength of who reviewed it — is intended. It is mirrored here to
  hold parity, and flagged rather than adopted. The owners are in the room; ask.

# Field kit

For running `kosli.evidence` against a real input document on a machine that can
**pull but not push** — no commits go home, so the trip has to produce findings
you can carry out in a few lines of text.

## Briefs

The task documents are addressed to Claude Code on the restricted machine, not to
a human reader. Point it at the relevant one:

| Brief | Question it answers |
| --- | --- |
| [BRIEF.md](BRIEF.md) | Does the library survive a real `kosli get trail`? *(done — see the findings folded into the README and `examples/trail_real_shape.json`)* |
| [BRIEF_CONTROL_43.md](BRIEF_CONTROL_43.md) | Can the library express control 43 (four-eyes)? Which reading of its approval rule is real, and what does `kosli evaluate` actually pass to a policy? |

## Get it there

The repo is INTERNAL, not private, so any org member can clone it. It is ~30KB of
text, so this completes well inside a short-lived proxy credential:

```sh
git clone --depth 1 --branch integration \
  https://github.com/kosli-dev/rego-evidence-report.git
cd rego-evidence-report
```

**The branch matters.** This work lives on `integration`; a default clone lands on
`main`, which has no `fieldkit/` at all.

To pick up later fixes, since nothing local needs preserving in tracked files:

```sh
git fetch --depth 1 origin integration && git reset --hard FETCH_HEAD
```

If git auth is the sticking point but HTTPS works, a single file is enough to
evaluate — the library has no dependencies:

```sh
curl -H "Authorization: Bearer $PAT" -H "Accept: application/vnd.github.raw" \
  'https://api.github.com/repos/kosli-dev/rego-evidence-report/contents/src/library.rego?ref=integration' \
  -o library.rego
```

You also need **`opa`** (a single static binary) and **`python3`** (stdlib only).
If binary downloads are blocked, look for an internal artifact mirror — the
library is text and travels anywhere, but the evaluator does not.

Confirm the toolchain before trusting any result:

```sh
opa test src examples --ignore '*.json'   # expect PASS: 227/227
```

## Work in `scratch/`

`fieldkit/scratch/` is gitignored: real input documents and the policies written
against them stay untracked, so `git reset --hard` can't destroy them and
confidential input can't be committed by accident.

```sh
mkdir -p fieldkit/scratch
cp fieldkit/policy_template.rego fieldkit/scratch/policy.rego
# put the real input document at fieldkit/scratch/trail.json
```

### 1. Find the paths

```sh
python3 fieldkit/kit.py shape fieldkit/scratch/trail.json
```

Prints the document's structure — paths, types, and how many siblings actually
carry each field — and **never a value**:

```
                  approvers            array          3/3
                    []                 object         n=2
                  commits              array          3/3
                    []                 object         n=3
                      signature_state  string         1/3
                      verified         bool           3/3
```

Read the third column first. `3/3` means every sibling has the field; `1/3` means
two of them don't, which is where a check will fail closed. `n=` on a `[]` row is
the total number of elements, which is what `all`/`any` turn on — including the
empty-array case they are specified to fail.

`--rego` reprints each path as the Rego path array to paste into a check.
`--max-children N` widens truncated sibling groups; `--depth N` limits nesting.

### 2. Write the checks

Edit `fieldkit/scratch/policy.rego`. Set `from` to where the subjects live, `id`
to how one is identified, then one check at a time. The template lists the entire
operator vocabulary in comments, so you don't need the README on that machine.

### 3. Run it

```sh
python3 fieldkit/kit.py run fieldkit/scratch/policy.rego fieldkit/scratch/trail.json
```

```
compliant: false
15 rows, 3 failing

  merged_pr                satisfied=false require=some  subjects=2/3 matching

failing rows:
  merged_pr        commits_signed   …hub.com/kosli-dev/app/pull/42 commits[].verified=[true, false]
```

Add `--ops FILE...` for custom operators, `--json` for the raw report. Unlike
`shape`, **this output contains real values** — it is for reading there, not for
carrying out.

A first run against an unedited template fails on `$min_subjects`, which is the
library telling you `from` resolved to nothing. That is the expected starting
state, not a broken kit.

## What to carry back

The bottleneck is the return trip, so aim it at these seven questions. Short
answers are enough — field names and operator names, no values:

1. **Did `from` resolve?** If `$min_subjects` failed, what is the real path to the
   collection of subjects?
2. **Is a subject what we assumed?** One PR, one artifact, one deployment — or is
   the real document nested a level deeper than the vocabulary can address?
3. **Which checks needed a custom op**, and what did each one have to do that
   the vocabulary couldn't express?
4. **Which operator was nearly right?** Name it and the missing parameter — that
   is the highest-value finding, because it becomes a library change rather than
   a per-policy escape hatch.
5. **Any check that failed for the wrong reason** — a wrong `path` reported as a
   breach rather than as a mistake. Does the row's `inputs` column make the two
   distinguishable?
6. **Did anything go undefined**, or did `report` itself fail to evaluate? Copy
   the `opa check --strict` error verbatim if so.
7. **Scale.** How many subjects and rows, and was evaluation noticeably slow?

Questions 3 and 4 are the reason for the trip. Everything else is fixable from
here without seeing the data.

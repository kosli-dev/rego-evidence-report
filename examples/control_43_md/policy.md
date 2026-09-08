# Control 43 — source code review verification

Four-eyes, per commit. Every commit reaching a protected branch must have been
approved by somebody who did not write it.

The rule is **per author** — not per pull request, and not per commit. For every
author who contributed to the pull request, some approver must exist who is not
that author. Mutual review between two developers therefore passes. This point
was contradicted between the control's own README and its scenario list for two
years, and was settled only by reading the deployed policy. It is written down
here because it is the single thing about this control that everybody gets
wrong.

## Subjects

A **commit** is each of `trails`, identified by its `name`.

| Property                | Path                                                                                                                |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------- |
| name                    | `name`                                                                                                              |
| PR attestation          | `compliance_status.attestations_statuses[attestation_type=pull_request]`                                            |
| pull requests           | `compliance_status.attestations_statuses[attestation_type=pull_request].pull_requests`                              |
| initial-commit evidence | `compliance_status.attestations_statuses[attestation_type=custom:initial-commit-by-verified-committer].is_compliant` |

The bracket form is a selector: *the element of this collection whose
`attestation_type` is `pull_request`*. The attestation container is keyed by a
configurable name, so it has to be selected by type — keying it by name breaks
the moment somebody sets `KOSLI_ATTESTATION_NAME`, and it breaks silently.

## Constants

**Web-flow authors** are authors matching any of:

- `^svc_[a-zA-Z0-9_-]+ <[^>]+>$`
- `^.*?\[bot\] <[^>]+>$`
- `^GitHub <noreply@github.com>$`

These are the commits no human wrote: service accounts, bots, and edits made
through the GitHub web interface. They cannot be linked to an account because
there is no account to link.

## Substitutes

- `initial_commit` — the **initial-commit evidence** must be `true`.
  A compliant initial-commit-by-verified-committer attestation stands in for the pull request an initial commit cannot have.

An initial commit has no parent, and therefore can never have a pull request.
Without this substitute it would fail every check below — which would be a false
positive rather than a breach, and the noisiest possible kind.

## The trail covers a commit `commits_present`

At least one **commit** must be in scope.

Must hold:

- `commit_identified` — the **name** must be a non-empty string.
  The trail names the commit it covers.

## The commit was reviewed `commit_reviewed`

No minimum — `commits_present` already denies an empty trail set, for its own
reason and with its own row. Repeating the denial here would report one problem
twice and make the report harder to read, not safer.

Must hold:

- `pr_attestation_present` — the **PR attestation** must be present,
  or else `initial_commit`.
  Pull request review data was collected for this commit.

- `pull_request_found` — at least one **pull request** must exist,
  or else `initial_commit`.
  Records the **pull requests**' `url`.
  The commit is associated with at least one pull request.

- `identities_resolved` — some **pull request** must have its identities
  resolved, treating **web-flow authors** as explained, or else `initial_commit`.
  Some pull request has every branch commit linked to a GitHub account or explained as a web-flow commit, or else has every one of its approvers resolved.

- `independently_approved` — some **pull request** must be independently
  approved, treating **web-flow authors** as explained, or else `initial_commit`.
  Some pull request has an approval from someone other than each of its authors, after its latest commit.

The last two name **custom operators**. They compare a subject's fields to each
other across two nested collections of one pull request, which no operator over
a single path can express. What the prose gives is the name and what it applies
to; the operator itself is Rego, written once in
`examples/control_43_ops.rego`, and reusable by any control that needs it.

`identities_resolved` used to be expressible declaratively and regressed into a
custom operator when production made it a disjunction of two quantifiers. That
was a real loss: the declarative version made the exemption's discriminator
visible in the rendered expression, and now it does not.

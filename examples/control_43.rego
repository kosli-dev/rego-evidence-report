# Control 43 (four-eyes / source code review), expressed as a kosli.evidence
# policy. A port of `four-eyes.rego` from sdlc-workflows, written against the same
# input and checked against the same behaviours — see control_43_test.rego.
#
# Two identifiers, two schemes, one control:
#
#   SDLC-CTRL-0007   Kosli's published control catalogue — the *requirement*.
#                    https://sdlc.kosli.com/controls/release/code_review/
#   RCTLDEF0000043   a customer's own control register — an *implementation* of
#                    that requirement, which is what this file ports.
#
# So this and examples/code_review.rego are the same control at two levels of
# fidelity. This one matches the published subject — a code change, with *every*
# change requiring review — while code_review.rego covers the artefact-linkage
# requirement that this one cannot, since a commit trail carries no artifact.
#
# Deployed for real this would declare `package policy`, which is what
# `kosli evaluate` queries. It uses its own package here only because
# code_review.rego already occupies `package policy` in this directory.
#
# The subject is a **commit**: `kosli evaluate trails` passes `input.trails[]`, one
# trail per commit, and `trail.name` is the commit sha. Every commit must pass, so
# `require` is the default "every".
package control43

import data.kosli.evidence
import rego.v1

service_account_patterns := patterns if {
	patterns := data.params.service_account_patterns
	is_array(patterns)
} else := [
	"svc_.*",
	`.*\[bot\]`,
	`noreply@github\.com`,
]

# The PR attestation is identified by its *type*, not by its name — the collector's
# attestation name is configurable, so keying on it would break the moment someone
# sets KOSLI_ATTESTATION_NAME. A selector expresses that directly, and resolves the
# same whether attestations arrive as an array or as a map.
pr_attestation := ["compliance_status", "attestations_statuses", {"where": {"attestation_type": "pull_request"}}]

pull_requests := array.concat(pr_attestation, ["pull_requests"])

# The initial commit of a repository has no pull request to be reviewed in: there
# is no parent to open one against, so the evidence four-eyes asks for cannot
# exist. Production answers that with alternative evidence — a
# compliant `initial-commit-by-verified-committer` attestation — and this
# declares it as a substitute, so a check discharged that way says so in its row
# instead of the commit dropping out of scope with no evidence at all.
#
# Selected by name as well as type: `custom` is the type of every custom
# attestation, and the name is what makes this one the initial-commit claim. That
# is the opposite of the pull request selector below, and for the same reason —
# select on whichever field carries the identity.
initial_commit_attestation := ["compliance_status", "attestations_statuses", {"where": {
	"attestation_type": "custom",
	"attestation_name": "initial-commit-by-verified-committer",
}}]

# Presence of the attestation is the discriminator, not the commit's position in
# history: the collector attests this only for a root commit, so a policy that
# tried to recognise "is the initial commit" from the trail would be re-deriving
# a judgement the evidence already carries.
verified_initial_commit := {
	"description": "A compliant initial-commit-by-verified-committer attestation stands in for the pull request an initial commit cannot have",
	"op": "equals",
	"path": array.concat(initial_commit_attestation, ["is_compliant"]),
	"value": true,
}

requirements := {
	# Production's `allow` requires input.trails to be a non-empty array before
	# anything else. That guard is a requirement of its own here, so that "no
	# commits at all" is denied for its own stated reason rather than as a side
	# effect of another requirement finding nothing.
	"commits_present": {
		"subject_type": "commit",
		"from": ["trails"],
		"id": ["name"],
		"min_subjects": 1,
		"checks": {
			"commit_identified": {
				"description": "The trail names the commit it covers",
				"op": "non_empty_string",
				"path": ["name"],
			},
			# This requirement declares no applies_to, which is the whole reason
			# the author is asserted here rather than only in commit_reviewed. A
			# scope filter fails *permissively*: a commit whose author cannot be
			# read matches no exemption pattern, so not_matches_any fails, so the
			# commit drops out of scope — and with min_subjects 0 below, a whole
			# release of unreadable commits would be compliant with nothing to
			# show. Asserting the field where nothing can filter it away turns
			# that silent pass into a stated failure.
			#
			# Not hypothetical: real attestations carry `git_commit_info` as a
			# sibling of `pull_requests` on the attestation object, so a document
			# assembled differently could well arrive without one at trail level.
			"author_recorded": {
				"description": "The trail records the commit's git author, which is what the service-account exemption is judged on",
				"op": "non_empty_string",
				"path": ["git_commit_info", "author"],
			},
		},
	},
	"commit_reviewed": {
		"subject_type": "commit",
		"from": ["trails"],
		"id": ["name"],
		# Service-account commits are not in breach of four-eyes; they are not
		# subjects of it. Expressing the exemption as scope rather than as a
		# passing check is why an exempt commit produces a $applies row and no
		# check rows at all.
		"applies_to": {"human_authored": {
			"description": "The commit author is a person rather than a service account",
			"op": "not_matches_any",
			"path": ["git_commit_info", "author"],
			"patterns": service_account_patterns,
		}},
		# Zero is deliberate: a release range can legitimately contain nothing but
		# service-account commits, and that is compliant. "There were no commits
		# at all" is caught by commits_present above, which does not filter.
		"min_subjects": 0,
		"checks": {
			"pr_attestation_present": {
				"description": "Pull request review data was collected for this commit",
				"op": "present",
				"path": pr_attestation,
				"substitute": verified_initial_commit,
			},
			"pull_request_found": {
				"description": "The commit is associated with at least one pull request",
				"op": "any",
				"path": pull_requests,
				# An empty path addresses the element itself, so this asserts the
				# array holds something without asserting anything about it.
				"check": {"op": "present", "path": []},
				"inputs": [{"path": pull_requests, "each": ["url"]}],
				"substitute": verified_initial_commit,
			},
			# Two levels of collection — every commit of every pull request — and a
			# disjunction per commit: the account is linked, or the git author
			# says why it never could be. This was a custom op until "each" and
			# "any_of" met in the vocabulary; expressing it as data is what makes
			# the exemption's discriminator visible in the rendered expression
			# rather than buried in Rego.
			"identities_resolved": {
				"description": "Every pull request commit has a linked GitHub account, or is a web-flow commit",
				"op": "all",
				"path": pull_requests,
				"each": ["commits"],
				"check": {"op": "any_of", "options": {
					"linked_account": [{"op": "non_empty_string", "path": ["author_username"]}],
					"web_flow": [{
						"op": "matches_any",
						"path": ["author"],
						"patterns": service_account_patterns,
					}],
				}},
				"substitute": verified_initial_commit,
			},
			"independently_approved": {
				"description": "Some pull request has an approval from someone other than each of its authors, after its latest commit",
				"op": "independently_approved",
				"expression": "some pull_request: every author: some approver != author where state == APPROVED and timestamp > max(commits[].timestamp)",
				"path": pull_requests,
				"patterns": service_account_patterns,
				"inputs": [
					["name"],
					{"path": pull_requests, "each": ["approvers"]},
					{"path": pull_requests, "each": ["commits"]},
				],
				"substitute": verified_initial_commit,
			},
		},
	},
}

report := evidence.report(input, requirements)

allow := report.compliant

# ---------------------------------------------------------------------------
# Violations
#
# The consuming schema wants one string per failing commit, and the report holds
# one row per (commit, check) — so the rows are collapsed by an explicit
# precedence. The production policy achieves the same shape by writing its
# violation rules so their guards are mutually exclusive; declaring the order
# instead makes it legible, and means the full evidence survives underneath in
# `report` rather than being narrowed away.
# ---------------------------------------------------------------------------

# Every check of both requirements, because a check missing from this table gets
# no message: `allow` would be false with nothing in `violations` to say why,
# which is the one failure mode this policy must not have. The two
# commits_present checks rank first — if the trail doesn't say which commit it
# covers, or who wrote it, nothing downstream is worth reporting.
check_priority := {
	"commit_identified": 1,
	"author_recorded": 2,
	"pr_attestation_present": 3,
	"pull_request_found": 4,
	"identities_resolved": 5,
	"independently_approved": 6,
}

commit_violations(id) := [v |
	some v in evidence.violations(report)
	v.subject.id == id
	check_priority[v.check]
]

# The most fundamental thing that went wrong for this commit. Reporting "no
# independent approval" when the truth is "no PR was ever attested" would send
# someone looking in the wrong place.
#
# The whole entry rather than the check name, because the message depends on the
# row's `cause` as well as which check failed.
primary(id) := v if {
	vs := commit_violations(id)
	count(vs) > 0
	ranks := {check_priority[x.check] | some x in vs}
	some v in vs
	check_priority[v.check] == min(ranks)
}

failing_commits := {v.subject.id |
	some v in evidence.violations(report)
	v.subject.id != null
}

violations contains message(id) if some id in failing_commits

# A requirement-level failure (subject.id is null) is the input guard: there was
# nothing to evaluate.
violations contains "Policy error: input.trails is missing, not an array, or empty — cannot evaluate" if {
	some v in evidence.violations(report)
	v.subject.id == null
}

# Two messages, not one, for the same failing check. A selector resolves to
# nothing both when no attestation matches and when several do, and until rows
# carried a `cause` the report could not tell those apart — the message had to say
# "missing or ambiguous" and let the reader guess. They are different problems
# with different fixes: one is a collector that never ran, the other is two
# attestations of the same type on one trail, which the collector's configurable
# name makes reachable.
message(id) := sprintf("Trail %v: does not name the commit it covers", [id]) if {
	primary(id).check == "commit_identified"
}

message(id) := sprintf("Commit %v: no git author recorded — cannot tell a person from a service account", [short(id)]) if {
	primary(id).check == "author_recorded"
}

message(id) := sprintf("Trail %v: two or more pull_request attestations match — cannot tell which one to judge", [id]) if {
	primary(id).check == "pr_attestation_present"
	primary(id).cause == "ambiguous"
}

message(id) := sprintf("Trail %v: pull_request attestation is missing", [id]) if {
	primary(id).check == "pr_attestation_present"
	primary(id).cause != "ambiguous"
}

message(id) := sprintf("Commit %v: no associated PR found", [short(id)]) if {
	primary(id).check == "pull_request_found"
}

message(id) := sprintf(
	"Commit %v: a pull request commit has no linked GitHub account — identity unverifiable",
	[short(id)],
) if {
	primary(id).check == "identities_resolved"
}

message(id) := sprintf("Commit %v: no independent approval after latest code commit", [short(id)]) if {
	primary(id).check == "independently_approved"
}

# Commit shas are abbreviated in messages, as the production policy does — but
# only when there is something to abbreviate.
short(id) := substring(id, 0, 7) if {
	is_string(id)
	count(id) >= 7
}

short(id) := id if {
	is_string(id)
	count(id) < 7
}

short(id) := sprintf("%v", [id]) if not is_string(id)

output := {
	"allow": allow,
	"violations": violations,
	"report": report,
}

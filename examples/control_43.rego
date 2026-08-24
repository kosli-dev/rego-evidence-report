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
		"checks": {"commit_identified": {
			"description": "The trail names the commit it covers",
			"op": "non_empty_string",
			"path": ["name"],
		}},
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
			},
			"pull_request_found": {
				"description": "The commit is associated with at least one pull request",
				"op": "any",
				"path": pull_requests,
				# An empty path addresses the element itself, so this asserts the
				# array holds something without asserting anything about it.
				"check": {"op": "present", "path": []},
				"inputs": [{"path": pull_requests, "each": ["url"]}],
			},
			"identities_resolved": {
				"description": "Every pull request commit has a linked GitHub account, or is a web-flow commit",
				"op": "identities_resolved",
				"expression": "every commits[]: author_username is a non-empty string or author is a service account",
				"path": pull_requests,
				"patterns": service_account_patterns,
				"inputs": [{"path": pull_requests, "each": ["commits"]}],
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

check_priority := {
	"pr_attestation_present": 1,
	"pull_request_found": 2,
	"identities_resolved": 3,
	"independently_approved": 4,
}

failing_checks(id) := {v.check |
	some v in evidence.violations(report)
	v.subject.id == id
}

# The most fundamental thing that went wrong for this commit. Reporting "no
# independent approval" when the truth is "no PR was ever attested" would send
# someone looking in the wrong place.
primary(id) := name if {
	ranks := {rank |
		some c in failing_checks(id)
		rank := check_priority[c]
	}
	count(ranks) > 0
	some name, rank in check_priority
	rank == min(ranks)
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

# "or ambiguous" because a selector resolves to nothing both when no attestation
# matches and when several do, and the row cannot distinguish them: both record a
# null value. Naming only the first case would be a confident wrong answer for the
# second. This is the clearest argument yet for a row-level cause discriminator —
# with one, these would be two messages.
message(id) := sprintf("Trail %v: pull_request attestation is missing or ambiguous", [id]) if {
	primary(id) == "pr_attestation_present"
}

message(id) := sprintf("Commit %v: no associated PR found", [short(id)]) if {
	primary(id) == "pull_request_found"
}

message(id) := sprintf(
	"Commit %v: a pull request commit has no linked GitHub account — identity unverifiable",
	[short(id)],
) if {
	primary(id) == "identities_resolved"
}

message(id) := sprintf("Commit %v: no independent approval after latest code commit", [short(id)]) if {
	primary(id) == "independently_approved"
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

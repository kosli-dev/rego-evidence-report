# Code Review (SDLC-CTRL-0007), expressed as a kosli.evidence policy.
# Same configurability via data.params; same input shape (input.trail).
package policy

import data.kosli.evidence
import rego.v1

artifact_name := name if {
	name := data.params.artifact_name
	is_string(name)
} else := "artifact"

pr_attestation_name := name if {
	name := data.params.pr_attestation_name
	is_string(name)
} else := "pull-request"

protected_branch := name if {
	name := data.params.protected_branch
	is_string(name)
} else := "main"

code_review_attestation_name := name if {
	name := data.params.code_review_attestation_name
	is_string(name)
} else := "SOURCE_CODE_REVIEW_COMPLETED"

artifact_path := ["trail", "compliance_status", "artifacts_statuses", artifact_name]

requirements := {
	"artifact": {
		"subject_type": "artifact",
		"from": artifact_path,
		"id": ["artifact_fingerprint"],
		"min_subjects": 1,
		"checks": {"fingerprint_recorded": {
			"description": "Artifact has a SHA256 fingerprint so code review can be cryptographically linked to the artefact under review",
			"op": "non_empty_string",
			"path": ["artifact_fingerprint"],
		}},
	},
	# The attestation is a subject in its own right, which is what lets applies_to
	# act as the selector: attestations arrive as an ARRAY, and filtering it to the
	# one named element is the same operation as scoping a requirement.
	#
	# Two checks, because "status" and "is_compliant" answer different questions and
	# only one of them is about compliance. A COMPLETE attestation has been
	# *reported*; it may still have been reported as failing. Asserting COMPLETE
	# alone is a fail-open, and a real trail contains exactly that case: the code
	# review attestation is COMPLETE with is_compliant false.
	#
	# Note what is missing: a bare `kosli get trail` carries no per-artifact
	# attestation list (the artifact's own attestations_statuses is empty), so this
	# requirement cannot confirm the evidence is linked to the artifact under
	# review — only that the trail carries a compliant code review. Restoring that
	# link needs an input document composed from more than one API call.
	"code_review_attestation": {
		"subject_type": "attestation",
		"from": ["trail", "compliance_status", "attestations_statuses"],
		"id": ["attestation_name"],
		"min_subjects": 1,
		"applies_to": {"is_code_review": {
			"op": "equals",
			"path": ["attestation_name"],
			"value": code_review_attestation_name,
		}},
		"checks": {
			"attestation_reported": {
				"description": "Code review evidence was recorded against the trail",
				"op": "equals",
				"path": ["status"],
				"value": "COMPLETE",
			},
			"attestation_compliant": {
				"description": "The recorded code review evidence passed — reported is not the same as passed",
				"op": "equals",
				"path": ["is_compliant"],
				"value": true,
			},
		},
	},
	"merged_pr": {
		"subject_type": "pull_request",
		"from": array.concat(artifact_path, ["attestations_statuses", pr_attestation_name, "pull_requests"]),
		"id": ["url"],
		# ONE merged PR must satisfy ALL checks together — requirements
		# may not be split across different pull requests.
		"require": "some",
		"applies_to": {"merged": {"op": "equals", "path": ["state"], "value": "MERGED"}},
		"min_subjects": 1,
		"checks": {
			"protected_branch": {
				"description": "Merged into the protected branch",
				"op": "equals",
				"path": ["base_ref"],
				"value": protected_branch,
			},
			"commits_signed": {
				"description": "Every commit in the pull request is signed with a verified signature (fail-closed on missing 'verified')",
				"op": "all",
				"path": ["commits"],
				"check": {"op": "equals", "path": ["verified"], "value": true},
			},
			"peer_approved": {
				"description": "An APPROVED reviewer who is not the PR author, approving after the last commit",
				"op": "peer_approved",
				"expression": "some approver: state == APPROVED and username != author and timestamp > max(commits[].timestamp)",
				# Every input the op reads, so the verdict can be
				# recomputed from the row alone.
				"inputs": [["author"], ["approvers"], {"path": ["commits"], "each": ["timestamp"]}],
			},
		},
	},
}

report := evidence.report(input, requirements)

allow := report.compliant

# evidence.violations() does the selecting — failing rows of unsatisfied
# requirements, minus the $applies rows, since a PR that isn't merged is out of
# scope for this control rather than in breach of it — and joins each row to its
# description. All this policy decides is how to word the message.
violations contains msg if {
	some v in evidence.violations(report)
	msg := sprintf("%s: %s — %s", [subject_label(v), v.check, v.description])
}

# $min_subjects and $well_formed are about the requirement, not about any one
# subject, so their subject.id is null — which would otherwise render as the
# literal string "null" ("artifact 'null': ...").
subject_label(v) := sprintf("%s '%v'", [v.subject.type, v.subject.id]) if {
	v.subject.id != null
}

subject_label(v) := sprintf("%s (requirement-level)", [v.subject.type]) if {
	v.subject.id == null
}

output := {
	"allow": allow,
	"violations": violations,
	"report": report,
}

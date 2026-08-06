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

artifact_path := ["trail", "compliance_status", "artifacts_statuses", artifact_name]

requirements := {
	"artifact": {
		"subject_type": "artifact",
		"from": artifact_path,
		"id": ["artifact_fingerprint"],
		"min_subjects": 1,
		"checks": {
			"fingerprint_recorded": {
				"description": "Artifact has a SHA256 fingerprint so code review can be cryptographically linked to the artefact under review",
				"op": "non_empty_string",
				"path": ["artifact_fingerprint"],
			},
			"pr_attestation_complete": {
				"description": "Code review evidence recorded and linked to the artefact",
				"op": "equals",
				"path": ["attestations_statuses", pr_attestation_name, "status"],
				"value": "COMPLETE",
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
	msg := sprintf("%s '%v': %s — %s", [v.subject.type, v.subject.id, v.check, v.description])
}

output := {
	"allow": allow,
	"violations": violations,
	"report": report,
}

# Code Review (SDLC-CTRL-0007), expressed as kosli.evidence subject sets.
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

sets := [
	{
		"name": "artifact",
		"type": "artifact",
		"path": artifact_path,
		"id": ["artifact_fingerprint"],
		"min_count": 1,
		"clauses": {
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
	{
		"name": "merged_pr",
		"type": "pull_request",
		"path": array.concat(artifact_path, ["attestations_statuses", pr_attestation_name, "pull_requests"]),
		"id": ["url"],
		# ONE merged PR must satisfy ALL clauses together — requirements
		# may not be split across different pull requests.
		"quantifier": "some",
		"where": {"merged": {"op": "equals", "path": ["state"], "value": "MERGED"}},
		"min_count": 1,
		"clauses": {
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
				"clause": {"op": "equals", "path": ["verified"], "value": true},
			},
			"peer_approved": {
				"description": "An APPROVED reviewer who is not the PR author, approving after the last commit",
				"op": "peer_approved",
				"expression": "some approver: state == APPROVED and username != author and timestamp > max(commits[].timestamp)",
				"echo": [["author"], ["approvers"]],
			},
		},
	},
]

report := evidence.report(input, sets)

allow := report.compliant

# Violations as a projection of the report: failed rows of unsatisfied sets.
# (Failed rows in a SATISFIED "some"-set are not violations — another PR
# met all requirements.)
violations contains msg if {
	some s in report.sets
	not s.satisfied
	some r in report.results
	r.set == s.name
	r.passed == false
	description := object.get(s.clauses, [r.predicate, "description"], "")
	msg := sprintf("%s '%v': %s — %s", [r.subject.type, r.subject.id, r.predicate, description])
}

output := {
	"allow": allow,
	"violations": violations,
	"report": report,
}

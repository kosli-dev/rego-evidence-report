# Tests for the YAML-declared spelling of the demo policy.
#
#   opa test src examples --ignore '*.json'
#
# These pin the *meaning* of examples/prod_deploy_spec/data.yaml, so the claim
# that a data document is a policy language cannot decay into a claim nobody
# re-checks. Edit the YAML and these fail.
#
# The fixture mirrors demo/deployments.json rather than reading it, for the same
# reason code_review_test.rego builds its own: demo/ is not on the test load
# path, and the *.json files that are there cannot be loaded together. The
# byte-identical comparison against demo/prod_deploy.rego is the `opa eval`
# command in examples/prod_deploy_as_data.rego, which needs both trees at once.
package prod_deploy_as_data_test

import rego.v1

# demo/deployments.json: one compliant, one with no approver and a red CI check,
# one on staging that the requirement does not apply to.
doc := {"deployments": [
	{
		"name": "d-1", "environment": "prod", "approved_by": "bob",
		"ci_checks": [{"conclusion": "success"}],
	},
	{
		"name": "d-2", "environment": "prod",
		"ci_checks": [{"conclusion": "success"}, {"conclusion": "failure"}],
	},
	{
		"name": "d-3", "environment": "staging", "approved_by": "carol",
		"ci_checks": [{"conclusion": "success"}],
	},
]}

report := rep if {
	rep := data.prod_deploy_as_data.report with input as doc
}

# ---------- the YAML is a policy ----------

test_yaml_spec_produces_a_report if {
	count(report.results) == 9
	report.compliant == false
}

# The point of the whole exercise: a spec that never touched Rego still reports
# *why* each check failed, and still tells a hole in the evidence apart from bad
# evidence.
test_yaml_spec_reports_causes if {
	cause_of("approved", "d-2") == "absent"
	cause_of("ci_green", "d-2") == "value"
	cause_of("approved", "d-1") == "satisfied"
}

test_yaml_spec_scopes_by_applies_to if {
	cause_of("$applies", "d-3") == "value"
	not decided("approved", "d-3")
}

# `expression` is rendered by the library from the spec, so a YAML author gets
# the same interpretable row a Rego author does — and the same string is what a
# Markdown front end would have to round-trip.
test_yaml_spec_renders_its_own_expressions if {
	checks := report.requirements.prod_deploy.checks
	checks.ci_green.expression == "every ci_checks: conclusion == success"
	checks.approved.expression == "approved_by is a non-empty string"
}

test_yaml_spec_projects_violations if {
	breaches := data.prod_deploy_as_data.breaches with input as doc
	count(breaches) == 2
	{b.check | some b in breaches} == {"approved", "ci_green"}
	{b.subject.id | some b in breaches} == {"d-2"}
}

# ---------- helpers ----------

decided(check, id) if {
	some row in report.results
	row.check == check
	row.subject.id == id
}

cause_of(check, id) := row.cause if {
	some row in report.results
	row.check == check
	row.subject.id == id
}

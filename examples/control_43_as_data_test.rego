# The pin for examples/control_43_spec/data.yaml.
#
#   opa test src examples --ignore '*.json'
#
# One assertion carries this: the YAML spec and the Rego spec are the same
# object. Everything else follows from it — same object into `evidence.report`
# means the same report, the same rows and the same rendered expressions, so
# there is nothing gained by re-deriving them here.
#
# It is the parity harness's arrangement one level up. examples/control_43.rego
# is the thing under test there and the reference here; if it changes and this
# file does not follow, the build breaks rather than the two quietly diverging.
# That is the whole reason a second spelling of a policy is safe to keep.
package control_43_as_data_test

import rego.v1

# `data.params` is undefined under `opa test`, so control_43.rego's
# web_flow_patterns falls back to its literals — which is what the YAML holds.
test_yaml_spec_is_the_rego_spec if {
	data.control_43_spec.requirements == data.control43.requirements
}

# The claim the YAML exists to make: a spec that never touched Rego still names
# the two custom ops, and they resolve because examples/control_43_ops.rego
# contributes them to `package kosli.evidence` rather than to a policy.
test_yaml_spec_names_the_custom_ops if {
	checks := data.control_43_spec.requirements.commit_reviewed.checks
	checks.identities_resolved.op == "identities_resolved"
	checks.independently_approved.op == "independently_approved"
}

# A custom op declares its own `expression`, since the library cannot derive one.
# Both survive the round trip through YAML, so a report row driven from a data
# document is as interpretable as one driven from Rego.
test_yaml_spec_carries_custom_op_expressions if {
	checks := data.control_43_spec.requirements.commit_reviewed.checks
	startswith(checks.independently_approved.expression, "some pull_request: every author:")
	startswith(checks.identities_resolved.expression, "some pull_request: (every commit:")
}

# The pin for examples/control_43_md/policy.md — control 43 written as prose.
#
#   opa test src examples --ignore '*.json'
#
# This is the assertion that distinguishes "Markdown works" from "Markdown works
# on toys". Control 43 is the hardest control here: two requirements over one
# subject, selector paths, a substitute shared by four checks, and two custom
# operators. If prose can produce this object, the front end reaches a real
# control's rule.
#
# It is the same arrangement as examples/control_43_as_data_test.rego, one level
# up again. examples/control_43.rego is the reference; if it changes and the
# Markdown does not follow, the build breaks rather than the two quietly
# diverging.
package control_43_md_test

import rego.v1

# `data.params` is undefined under `opa test`, so control_43.rego's
# web_flow_patterns falls back to its literals — which is what the Markdown's
# **Web-flow authors** constant holds.
test_markdown_spec_is_the_rego_spec if {
	data.control_43_md.requirements == data.control43.requirements
}

# The two spellings that are not Rego agree with each other, so neither is
# quietly drifting via the reference.
test_markdown_spec_is_the_yaml_spec if {
	data.control_43_md.requirements == data.control_43_spec.requirements
}

# A custom operator reached from prose. The sentence names the operator and what
# it applies to; `expression` and `inputs` come from authoring/custom_ops.json,
# because the library cannot render an operator it does not know.
test_markdown_spec_reaches_the_custom_ops if {
	checks := data.control_43_md.requirements.commit_reviewed.checks
	checks.identities_resolved.op == "identities_resolved"
	checks.independently_approved.op == "independently_approved"
	startswith(checks.independently_approved.expression, "some pull_request: every author:")
}

# The substitute is declared once in the Markdown and referred to by name, so
# all four checks carry the same object rather than four copies that could drift.
test_markdown_spec_shares_one_substitute if {
	checks := data.control_43_md.requirements.commit_reviewed.checks
	subs := {check.substitute | some check in checks}
	count(subs) == 1
}

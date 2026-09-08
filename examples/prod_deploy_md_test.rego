# The pin for examples/prod_deploy_md/policy.md.
#
#   opa test src examples --ignore '*.json'
#
# One assertion carries this, as it does for the YAML spelling: the object
# compiled from Markdown and the object written in Rego are the same object.
# Everything else follows — same object into `evidence.report` means the same
# rows, the same causes and the same rendered expressions.
#
# Regenerate examples/prod_deploy_md/data.yaml from the Markdown with
# `npx tsx authoring/src/cli.ts examples/prod_deploy_md/policy.md
# -o examples/prod_deploy_md/data.yaml`, or check it is current with `--check`.
package prod_deploy_md_test

import rego.v1

test_markdown_spec_is_the_rego_spec if {
	data.prod_deploy_md.requirements == data.prod_deploy_spec.requirements
}

# Descriptions survive the transpile, which is the point of writing controls in
# prose: the sentence under the rule is the author's, and it is what
# `violations` reports. There is no second field to keep in step.
test_markdown_spec_carries_its_descriptions if {
	checks := data.prod_deploy_md.requirements.prod_deploy.checks
	checks.approved.description == "A named approver signed off on the deployment"
	checks.ci_green.description == "Every CI check on the deployment passed"
}

# The demo policy, with its rule loaded from a data document instead of written
# in Rego. This file is the whole policy: the requirements live in
# examples/prod_deploy_spec/data.yaml.
#
# It exists to keep one claim runnable rather than asserted — that
# `requirements` is a plain object, so any format that can produce that object
# is a policy language for this library. INTEGRATION.md, "Requirements as data,
# in a format that is not Rego", is the write-up.
#
# Byte-identical to demo/prod_deploy.rego's report over demo/deployments.json:
#
#   opa eval --ignore '*.json' -d src/library.rego -d examples \
#     -i demo/deployments.json --format=json 'data.prod_deploy_as_data.report'
#
# Load `examples` as a directory, not the YAML file on its own. OPA roots a data
# document at the path of its directory *relative to the load root*, so a bare
# `-d examples/prod_deploy_spec/data.yaml` lands the object at `data` and this
# policy reads null. Loading the directory is also what `opa test` does, so the
# tests and this command see the same tree.
#
# WHAT THIS DOES NOT SHOW. A data document cannot carry a custom op, because
# `op_passed` is a Rego rule — so control 43 has no pure-data spelling. Nor can
# it carry computation: examples/control_1068.rego reads its flavour tables from
# `data.params` with a literal fallback, and "read from params, else default" is
# Rego, not data. What a data document holds is the requirements object itself,
# which is the part a non-Rego front end would generate.
package prod_deploy_as_data

import data.kosli.evidence
import rego.v1

report := evidence.report(input, data.prod_deploy_spec.requirements)

allow := report.compliant

breaches := evidence.violations(report)

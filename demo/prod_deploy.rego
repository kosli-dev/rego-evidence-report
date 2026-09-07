package demo

import data.kosli.evidence
import rego.v1

requirements := {"prod_deploy": {
	"subject_type": "deployment",
	"from": ["deployments"],
	"id": ["name"],
	"applies_to": {"is_prod": {"op": "equals", "path": ["environment"], "value": "prod"}},
	"checks": {
		"approved": {
			"description": "A named approver signed off on the deployment",
			"op": "non_empty_string",
			"path": ["approved_by"],
		},
		"ci_green": {
			"description": "Every CI check on the deployment passed",
			"op": "all",
			"path": ["ci_checks"],
			"check": {"op": "equals", "path": ["conclusion"], "value": "success"},
		},
	},
}}

report := evidence.report(input, requirements)

allow := report.compliant

breaches := evidence.violations(report)

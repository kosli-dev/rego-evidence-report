# Bakery policy, v2 style: the bake is a single subject at the input root.
package bakery

import data.kosli.evidence
import rego.v1

policy := [{
	"type": "batch",
	"path": [],
	"id": ["batch_id"],
	"clauses": {
		"nut_free": {
			"description": "Must not contain nut allergens",
			"op": "excludes", "path": ["allergens"], "value": "nuts",
		},
		"temp_ok": {
			"description": "Bake temperature 175-200C inclusive",
			"op": "range", "path": ["bake", "temp_c"], "min": 175, "max": 200,
		},
		"time_ok": {
			"description": "Bake time 25-40 minutes inclusive",
			"op": "range", "path": ["bake", "minutes"], "min": 25, "max": 40,
		},
	},
}]

report := evidence.report(input, policy)

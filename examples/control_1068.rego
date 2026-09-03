# Control 1068 (business requirements), expressed as a kosli.evidence policy.
#
# Unlike examples/control_43.rego this is not a port. Control 1068 has no Rego
# policy to port: its rule lives in TypeScript
# (`RCTLDEF0001068-business-requirements/src/checkBusinessRequirements.ts`), it has
# no Kosli integration today, and its evidence goes to a factstore as a structured
# object rather than through `kosli evaluate`. So read this as a design sketch
# against a synthetic input, written to answer one question: can this library
# express a control that is not four-eyes?
#
# The answer is "the ticket half, yes — and only because of `any_of`".
#
# WHAT THIS CANNOT EXPRESS, and why it is not a library defect
#
# The control is about *commits* tracing to approved requirements. It cannot be
# modelled that way here, because the collector destroys the link before any
# evidence exists: `getJiraIdsFrom` flattens commit messages to a `Set<string>` of
# ticket ids, and the ticket model carries no commit backref. `from` is a path into
# a document — it can select and filter, but it cannot parse ids out of commit
# messages and cannot fetch ticket detail from a second API. No policy language
# recovers a relation that was thrown away upstream.
#
# So the strongest claim available is "every ticket is permitted", which is weaker
# than "every commit traces to a permitted requirement": it says nothing about a
# commit that referenced no ticket at all. Fixing that is a requirement on the
# collector — attest commits *with* their resolved tickets — not on this library.
# control_1068_test.rego pins the limit rather than hiding it.
#
# THE VOCABULARY BELOW IS ILLUSTRATIVE, and now known to be *permanently* so. The
# three flavour tables are known to exist and to be keyed this way, and one fact
# about them is established: no single table holds both `Story` and `DONE`. The
# membership is **not in the control's source at all** — it is read at runtime from
# an external fact store — so there is no version of this file that could hold the
# real lists. That is what `data.params` is for, and the default below is the
# stand-in for when nothing is passed.
package control1068

import data.kosli.evidence
import rego.v1

# A ticket is Permitted iff its type and its state come from the SAME table. This
# is the whole reason `any_of` exists: checking type and state independently
# accepts the union of all three tables per field, which passes cross-products no
# table permits — a Standard `Story` in the Safe-only state `DONE` sails through.
# That is a silent over-pass, and it is the failure mode this library exists to
# prevent everywhere else.
# Membership arrives as configuration, the way the real control gets it: a fact
# store at runtime there, `--params` here. `kosli evaluate --params @tables.json`
# populates `data.params`, and the CLI in control 43's own image is new enough to
# have that flag — so a table that changes is a parameter change rather than a
# policy change, which is the only arrangement that can stay true.
#
# `examples/control_43.rego` reads `data.params.service_account_patterns` the same
# way. Both fall back to a literal when nothing is passed, so the policy is
# runnable and testable on its own.
flavours := tables if {
	tables := data.params.flavours
	is_object(tables)
	count(tables) > 0
} else := {
	"standard": {
		"types": ["^Story$", "^Defect$", "^New Feature$"],
		"states": ["^CLOSED$", "^RESOLVED$", "^IN PROGRESS$"],
	},
	"cloud": {
		"types": ["^JS Story$", "^JS Waste$"],
		"states": ["^DONE$", "^ADOPTING$"],
	},
	"safe": {
		"types": ["^SAFe Story$", "^Defect$"],
		"states": ["^DONE$", "^PO ACCEPTED$", "^READY FOR RELEASE$"],
	},
}

# One option per table, each a conjunction of two leaf checks over the same
# subject. Built from the data above so the tables stay readable as tables.
permitted_options := {name: [
	{"op": "matches_any", "path": ["type"], "patterns": f.types},
	{"op": "matches_any", "path": ["state"], "patterns": f.states},
] |
	some name, f in flavours
}

requirements := {"tickets_are_permitted": {
	"subject_type": "ticket",
	"from": ["tickets"],
	"id": ["key"],
	# Epics and tasks are filtered out before the decision, so they are out of
	# scope rather than in breach. Sub-tasks resolve to their parent upstream;
	# by the time a ticket reaches a policy it is already the parent.
	"applies_to": {"not_epic_or_task": {
		"description": "The ticket is a work item rather than an epic or task",
		"op": "not_matches_any",
		"path": ["type"],
		"patterns": ["^(?i:epic)$", "^(?i:task)$", "^(?i:js epic)$"],
	}},
	# Production passes iff `permitted.length > 0 AND nonPermitted.length == 0`,
	# so a range holding nothing but epics and tasks fails. That is exactly what
	# min_subjects 1 says once the epics are scoped out — the same verdict for the
	# same stated reason, rather than as a side effect.
	"min_subjects": 1,
	"checks": {"permitted": {
		"description": "Issue type and workflow state both come from the same flavour table",
		"op": "any_of",
		"options": permitted_options,
	}},
}}

report := evidence.report(input, requirements)

allow := report.compliant

# ---------------------------------------------------------------------------
# Output
#
# Control 43 had to collapse the report into `violations: string[]` because its
# consuming schema demanded it. 1068 has no such schema: its evidence is already a
# structured object with permitted and non-permitted ticket lists. So the native
# shape of a report is closer to what this control wants than to what 43 wanted,
# and the two lists below are a projection rather than a narrowing — the full
# evidence survives underneath in `report`.
# ---------------------------------------------------------------------------

decided_rows contains row if {
	some row in report.results
	row.requirement == "tickets_are_permitted"
	not startswith(row.check, "$")
}

non_permitted_tickets := {row.subject.id | some row in decided_rows; row.passed == false}

permitted_tickets := {row.subject.id | some row in decided_rows} - non_permitted_tickets

output := {
	"overall_status": status,
	"permitted_tickets": permitted_tickets,
	"non_permitted_tickets": non_permitted_tickets,
	"report": report,
}

status := "PASSED" if allow

status := "FAILED" if not allow

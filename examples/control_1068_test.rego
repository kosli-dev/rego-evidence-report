# Tests for the control 1068 sketch.
#
# Two things are being pinned here, and only one of them is a pass:
#
#   - that `any_of` gets the cross-product case right, which is the defect the
#     operator was added for and the reason this example exists;
#   - that the control's real subject cannot be named, which is a limit the
#     library owns rather than one it hides. That test asserts a failure and is
#     supposed to keep asserting one until a collector attests commits with their
#     resolved tickets.
package control1068_test

import data.kosli.evidence
import rego.v1

# ---------- fixtures ----------

ticket(key, type, state) := {"key": key, "type": type, "state": state, "project": "PA"}

out(doc) := result if {
	result := data.control1068.output with input as doc
}

for_tickets(tickets) := out({"tickets": tickets})

# The four-ticket case from the field round, kept intact: PA-4 is the false pass
# that independent per-field checks let through.
mixed := [
	ticket("PA-1", "SAFe Story", "DONE"),
	ticket("PA-2", "SAFe Story", "OPEN"),
	ticket("PA-3", "Epic", "DONE"),
	ticket("PA-4", "Story", "DONE"),
]

# ---------- the cross-product, which is the whole point ----------

# `Story` is a Standard type and `DONE` is a Cloud/Safe state. Each is recognised
# on its own and no flavour table holds both, so the ticket is Non-Permitted. Two
# independent matches_any checks over the union of the tables passed this.
test_a_type_and_state_from_different_tables_is_not_permitted if {
	result := for_tickets([ticket("PA-4", "Story", "DONE")])
	result.overall_status == "FAILED"
	result.non_permitted_tickets == {"PA-4"}
}

test_a_type_and_state_from_the_same_table_is_permitted if {
	result := for_tickets([ticket("PA-1", "SAFe Story", "DONE")])
	result.overall_status == "PASSED"
	result.permitted_tickets == {"PA-1"}
}

test_each_flavour_table_stands_on_its_own if {
	for_tickets([ticket("PA-1", "Story", "CLOSED")]).overall_status == "PASSED"
	for_tickets([ticket("PA-1", "JS Story", "ADOPTING")]).overall_status == "PASSED"
	for_tickets([ticket("PA-1", "SAFe Story", "PO ACCEPTED")]).overall_status == "PASSED"
}

test_an_unrecognised_state_is_not_permitted if {
	for_tickets([ticket("PA-2", "SAFe Story", "OPEN")]).overall_status == "FAILED"
}

test_an_unrecognised_type_is_not_permitted if {
	for_tickets([ticket("PA-9", "Chore", "DONE")]).overall_status == "FAILED"
}

# ---------- the full fixture ----------

test_the_mixed_range_fails_and_names_both_offenders if {
	result := for_tickets(mixed)
	result.overall_status == "FAILED"
	result.non_permitted_tickets == {"PA-2", "PA-4"}
	result.permitted_tickets == {"PA-1"}
}

# Out of scope is not in breach, and not a pass either: the epic appears in
# neither list.
test_an_epic_is_scoped_out_rather_than_judged if {
	result := for_tickets(mixed)
	not "PA-3" in result.non_permitted_tickets
	not "PA-3" in result.permitted_tickets
}

test_an_epic_produces_no_violation if {
	result := for_tickets(mixed)
	every v in evidence.violations(result.report) {
		v.subject.id != "PA-3"
	}
}

test_epics_and_tasks_are_matched_case_insensitively if {
	result := for_tickets(array.concat(mixed, [ticket("PA-5", "EPIC", "DONE"), ticket("PA-6", "TASK", "DONE")]))
	not "PA-5" in result.non_permitted_tickets
	not "PA-6" in result.non_permitted_tickets
}

# ---------- production parity: at least one permitted ticket is required ----------

# `isControlPassed` is `permitted.length > 0 AND nonPermitted.length == 0`, so a
# range with nothing to judge fails. Here that is min_subjects, and the row says
# so by name rather than the verdict falling out of some other check finding
# nothing.
test_a_range_of_only_epics_fails_for_want_of_subjects if {
	result := for_tickets([ticket("PA-3", "Epic", "DONE"), ticket("PA-7", "Task", "CLOSED")])
	result.overall_status == "FAILED"
	some v in evidence.violations(result.report)
	v.check == "$min_subjects"
}

test_no_tickets_at_all_fails if {
	for_tickets([]).overall_status == "FAILED"
}

test_a_missing_tickets_key_fails if {
	out({}).overall_status == "FAILED"
}

# ---------- the documented limit ----------

# The control is about commits tracing to approved requirements, and this asserts
# that the library cannot say so on the payload the collector actually produces.
# `getJiraIdsFrom` flattens commit messages to a set of ticket ids and the ticket
# model has no commit backref, so there are no commit subjects to find: `from`
# selects a path, it does not parse strings or call Jira.
#
# When a collector starts attesting commits with their resolved tickets, this test
# is the one that should start failing.
test_the_commit_subject_cannot_be_named_on_a_ticket_only_payload if {
	rep := evidence.report(
		{"tickets": [ticket("PA-1", "SAFe Story", "DONE")]},
		{"every_commit_traces_to_a_requirement": {
			"subject_type": "commit",
			"from": ["commits"],
			"id": ["sha"],
			"min_subjects": 1,
			"checks": {"references_permitted_requirement": {
				"description": "Commit references at least one permitted requirement",
				"op": "present",
				"path": ["permitted_requirement"],
			}},
		}},
	)
	rep.compliant == false
	rep.requirements.every_commit_traces_to_a_requirement.subjects == {"total": 0, "matching": 0}
	some v in evidence.violations(rep)
	v.check == "$min_subjects"
}

# ---------- evidence ----------

# Every field the disjunction consulted is on the row, so the verdict can be
# recomputed from the report without the input document.
test_a_failing_row_echoes_both_fields_that_decided_it if {
	result := for_tickets([ticket("PA-4", "Story", "DONE")])
	some v in evidence.violations(result.report)
	v.check == "permitted"
	v.inputs == [
		{"name": "state", "value": "DONE"},
		{"name": "type", "value": "Story"},
	]
}

# The rendered expression names the alternatives, so a reader can see which tables
# were on offer and none of them matched.
test_the_expression_names_every_flavour if {
	result := for_tickets(mixed)
	expr := result.report.requirements.tickets_are_permitted.checks.permitted.expression
	startswith(expr, "one of: ")
	contains(expr, "standard(")
	contains(expr, "cloud(")
	contains(expr, "safe(")
}

# ---------- table membership is configuration ----------

# The real control reads its flavour tables from an external fact store at
# runtime, so no version of the policy file can hold the real membership. These
# pin the `data.params` path that stands in for it: a table that changes must be
# a parameter change, not a policy change.
test_flavour_tables_come_from_params_when_given if {
	result := out({"tickets": [ticket("PA-9", "Widget", "SHIPPED")]}) with data.params as {"flavours": {"widgets": {
		"types": ["^Widget$"],
		"states": ["^SHIPPED$"],
	}}}
	result.overall_status == "PASSED"
}

# The joint condition survives the substitution: a cross-product of two supplied
# tables is still refused, which is the whole point of the operator.
test_params_tables_still_reject_a_cross_product if {
	result := out({"tickets": [ticket("PA-9", "Widget", "ADOPTING")]}) with data.params as {"flavours": {
		"widgets": {"types": ["^Widget$"], "states": ["^SHIPPED$"]},
		"cloud": {"types": ["^JS Story$"], "states": ["^ADOPTING$"]},
	}}
	result.overall_status == "FAILED"
}

# A ticket the built-in default permits is refused once params replace the tables:
# the fallback is a default, not a floor.
test_params_replace_the_defaults_rather_than_extending_them if {
	result := out({"tickets": [ticket("PA-1", "SAFe Story", "DONE")]}) with data.params as {"flavours": {"widgets": {
		"types": ["^Widget$"],
		"states": ["^SHIPPED$"],
	}}}
	result.overall_status == "FAILED"
}

# Malformed configuration falls back rather than emptying the vocabulary, which
# would deny every ticket for a reason nobody could read off the report.
test_malformed_params_fall_back_to_the_defaults if {
	result := out({"tickets": [ticket("PA-1", "SAFe Story", "DONE")]}) with data.params as {"flavours": "standard"}
	result.overall_status == "PASSED"
}

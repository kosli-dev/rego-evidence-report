# The custom operators for control 43, contributed into the kosli.evidence package.
#
# Two things exceed the operator vocabulary, and the reason is the same for both:
# they compare a subject's fields *to each other* across two nested collections of
# one pull request, which no declarative operator over a single path can express.
#
#   independently_approved   approvers against commit authors.
#   identities_resolved      every commit's author, OR every approver's username.
#
# The second one used to be declared as data — `all` with `each` over an `any_of`
# element check — and came back here when production's 2026-09-07 branch made it a
# disjunction of two quantifiers. `any_of` groups hold leaf checks, so it can no
# longer say it, and Rego's ban on recursion means the library cannot be widened to
# nest a quantifier inside a group without a separate non-recursive path. That is
# a real feature and may still be worth building; it was not worth building inside
# a drift fix.
#
# Helpers are prefixed c43_ because every custom op in every policy shares this
# one package, so an unprefixed `covered` would eventually collide with someone
# else's.
#
# These mirror four-eyes.rego in sdlc-workflows, with two deliberate differences,
# both marked below. Neither changes the outcome of any of that policy's tests;
# both close a case those tests don't cover, where the original passes input it
# cannot actually verify. The vendored copy in examples/ is the version they are
# measured against, and examples/control_43_parity_test.rego is what proves it.
package kosli.evidence

import rego.v1

# A GitHub login that resolves to somebody. "ghost" is GitHub's placeholder for a
# deleted account, so it is a login that names no one — production added it to
# every identity test in the 2026-09-07 branch, and before that its comment
# claimed to handle ghost users while the code tested only null and empty.
c43_identity_resolved(u) if {
	is_string(u)
	u != ""
	u != "ghost"
}

# Whether one commit's author is someone we can hold responsible.
c43_author_known(c, _) if c43_identity_resolved(c.author_username)

# Web-flow and Copilot co-authored commits carry no linked account. They are
# recognised by the same patterns as service accounts, matched against the git
# author string rather than the GitHub login.
c43_author_known(c, patterns) if {
	some pattern in patterns
	is_string(pattern)
	regex.match(pattern, object.get(c, "author", ""))
}

# Some associated pull request, on its own, has resolvable authors AND an
# independent approval for each of them. Both conditions must hold for the *same*
# pull request: one PR with verifiable identities and a different PR with an
# approval must not add up to a reviewed commit.
op_passed(check, trail) if {
	check.op == "independently_approved"
	prs := value_at(trail, check.path)
	is_array(prs)
	some pr in prs
	c43_identities_ok(pr, check.patterns)
	c43_independent(trail, pr)
}

# Identity resolution for one pull request, and production's only LOOSENING in
# the 2026-09-07 branch. An unresolvable commit author used to sink the pull
# request outright; it is now tolerated when every approver resolves instead, the
# reasoning being that a review whose reviewers are all identifiable is still
# attributable even when one commit's author is not.
#
# Mirrored here to hold verdict parity, and flagged in INTEGRATION.md as worth
# putting to whoever owns sdlc-workflows: it lets an unattributable commit through
# on the strength of who reviewed it, which is a weaker claim than four-eyes
# otherwise makes.
c43_identities_ok(pr, patterns) if c43_authors_resolved(pr, patterns)

c43_identities_ok(pr, _) if c43_approvers_resolved(pr)

c43_authors_resolved(pr, patterns) if {
	is_array(pr.commits)
	every c in pr.commits {
		c43_author_known(c, patterns)
	}
}

# Every approver identifiable, and at least one of them. Deliberately silent about
# state and timestamp: this asks who these people are, not whether they approved —
# that is c43_each_author_approved's job, and production draws the line in the
# same place.
c43_approvers_resolved(pr) if {
	is_array(pr.approvers)
	count(pr.approvers) > 0
	every a in pr.approvers {
		c43_identity_resolved(a.username)
	}
}

# The check-level half of the same question, so the report can say that identity
# resolution is what failed rather than folding it into the approval row. Per pull
# request, like production: `some pr`, not every commit of every pull request.
op_passed(check, trail) if {
	check.op == "identities_resolved"
	prs := value_at(trail, check.path)
	is_array(prs)
	some pr in prs
	c43_identities_ok(pr, check.patterns)
}

# The merge commit is the one whose sha the pull request records as its merge
# commit. Detection is by data, never by commit message — a commit named
# "Merge pull request #42 from ..." is still a plain commit.
c43_is_merge_commit(trail, pr) if trail.name == pr.merge_commit

# A plain commit: everyone who wrote code on the pull request, plus whoever opened
# it, needs independent approval.
c43_independent(trail, pr) if {
	not c43_is_merge_commit(trail, pr)
	c43_each_author_approved(pr, c43_commit_authors(pr) | {pr.author})
}

# A merge commit: only the branch authors need approval. Clicking merge is not
# authoring code, so the person who did it needs no separate review.
c43_independent(trail, pr) if {
	c43_is_merge_commit(trail, pr)
	c43_each_author_approved(pr, c43_commit_authors(pr))
}

# A merge commit whose branch commits are all web-flow or unresolvable: the pull
# request's author stands in as the code author, so the requirement doesn't
# evaporate for want of a name to hold responsible.
c43_independent(trail, pr) if {
	c43_is_merge_commit(trail, pr)
	count(c43_commit_authors(pr)) == 0
	is_string(pr.author)
	pr.author != ""
	c43_each_author_approved(pr, {pr.author})
}

# The four-eyes condition itself: for each author, *someone else* approved after
# the last commit. One approver who wrote nothing covers everybody; two authors
# reviewing each other also covers both, which is why this quantifies per author
# instead of demanding an approver innocent of the whole pull request.
c43_each_author_approved(pr, authors) if {
	count(authors) > 0
	count(pr.approvers) > 0
	eligible := c43_eligible_approvers(pr, c43_cutoff(pr))
	every author in authors {
		some approver in eligible
		approver != author
	}
}

# Note the asymmetry with c43_identity_resolved, which is production's and is
# kept: "ghost" is not an identity that *resolves*, but it is still an author who
# needs somebody else's approval. Filtering it here would quietly drop a
# ghost-authored commit out of the set needing review.
c43_commit_authors(pr) := {c.author_username |
	some c in pr.commits
	is_string(c.author_username)
	c.author_username != ""
}

# DIFFERENCE 1 from four-eyes.rego: `every c ... is_number(c.timestamp)`.
#
# The original takes max() over a comprehension, and a comprehension silently
# skips elements whose body is undefined — so a commit with no timestamp drops out
# of the maximum and cannot raise the bar. Push an untimestamped commit after an
# approval there and the approval still counts. A cutoff we cannot compute is a
# cutoff we must not guess, so this fails closed instead.
c43_cutoff(pr) := max({c.timestamp | some c in pr.commits}) if {
	count(pr.commits) > 0
	every c in pr.commits {
		is_number(c.timestamp)
	}
}

# DIFFERENCE 2 from four-eyes.rego: `is_number(a.timestamp)`.
#
# The original guards the approver's username but not their timestamp, and Rego's
# ">" is total across types with numbers sorting below strings — so `"1000005" >
# 1000010` is true and any string timestamp clears every cutoff. That turns "new
# code pushed after approval" into a pass. Requiring a number keeps the comparison
# meaningful.
c43_eligible_approvers(pr, cutoff) := {a.username |
	some a in pr.approvers
	a.state == "APPROVED"
	c43_identity_resolved(a.username)
	is_number(a.timestamp)
	a.timestamp > cutoff
}

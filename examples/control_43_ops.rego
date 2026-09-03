# The custom operator for control 43, contributed into the kosli.evidence package.
#
# One thing exceeds the operator vocabulary, and the reason is specific: it
# compares a subject's fields *to each other* across two nested collections —
# approvers against commit authors — which no declarative operator over a single
# path can express. Identity resolution used to be here too, and is now declared
# as data: "every commit of every pull request satisfies A or B" is `all` with
# `each` and an `any_of` element check, which the library gained after this file
# made the case for it.
#
# Helpers are prefixed c43_ because every custom op in every policy shares this
# one package, so an unprefixed `covered` would eventually collide with someone
# else's.
#
# These mirror four-eyes.rego in sdlc-workflows, with two deliberate differences,
# both marked below. Neither changes the outcome of any of that policy's 37 tests;
# both close a case those tests don't cover, where the original passes input it
# cannot actually verify.
package kosli.evidence

import rego.v1

# Whether one commit's author is someone we can hold responsible. Still needed
# here — `independently_approved` has to know which authors count before it can
# ask who approved them — but no longer the implementation of a check of its own.
c43_author_known(c, _) if {
	is_string(c.author_username)
	c.author_username != ""
}

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

c43_identities_ok(pr, patterns) if {
	is_array(pr.commits)
	every c in pr.commits {
		c43_author_known(c, patterns)
	}
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
	is_string(a.username)
	a.username != ""
	is_number(a.timestamp)
	a.timestamp > cutoff
}

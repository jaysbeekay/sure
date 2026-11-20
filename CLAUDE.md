# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

Upstream's `AGENTS.md` (imported above) and the `docs/llm-guides/` it points to are the
source of truth for commands, architecture, conventions, the design system, testing and the
API. This file adds only this fork's working rules.

## Issue and Pull Request Workflow

**Scope: this fork (`jaysbeekay/sure`) only.** This section is local policy, not
upstream convention. It cites this fork's issue and PR numbers, its CodeRabbit
configuration, and its star count. When preparing a contribution for
`we-promise/sure`, leave this section behind -- several issues here are labelled
`upstream:candidate`, so a CLAUDE.md change can otherwise ride upstream by
accident and be wrong there.

**The repository owner's ways of working overrule anything else in this file.**
Where another section, a tool default or a bot suggestion disagrees with the
rules below, the rules below win. Rules marked *(both repos)* also govern work
on `we-promise/sure`: upstream PRs, issues, comments and review replies prepared
from this fork.

### Ways of working

1. **No AI attribution** *(both repos)*. See the Attribution section below.
2. **Evidence before work** *(both repos)*. Every issue and PR is grounded in
   facts established from the code, configuration and framework behaviour, not
   memory or assumption. Test positive cases (the fix works) and negative cases
   (what must not change, invalid input, both sides of each boundary). Write the
   test first and watch it fail for the right reason. After the fix, break each
   change deliberately and confirm a test catches it.
3. **Validate every PR against upstream `AGENTS.md`** *(both repos)*. Read the
   current `we-promise/sure` `AGENTS.md` before opening a PR or marking one ready,
   and check the change against it. Upstream reviewers enforce it.
4. **CodeRabbit reviews only ready pull requests** *(both repos)*. Marking a PR
   ready starts its review, and later pushes get incremental passes. Do not force
   a review before then: no `@coderabbitai review` or `@coderabbitai full review`
   comment on a draft. On a ready PR, if an incremental pass returns nothing,
   `@coderabbitai full review` forces a fresh pass; three plain `review` requests
   produced nothing on #86 before it did.
5. **Re-check before every update** *(both repos)*. Several contributors, other
   sessions and review bots work on these repositories, and state changes quickly.
   Immediately before editing an issue or PR body, commenting, pushing, marking
   ready, closing or resolving a thread, re-fetch its state, head commit,
   comments, reviews and threads. If anything changed, read it and adjust first.
   Push with `--force-with-lease` or after a fast-forward check.
6. **If unsure, stop** *(both repos)*. Do not guess, and do not paper over a gap
   with speculative reasoning. State exactly what is unknown and ask the owner.
7. **Gatekeeper reviews and CI gate the work** *(this fork)*. Each of these
   triggers automatically:
   - **Raising an issue** (bug or feature request) triggers an **Issue
     Gatekeeper Review**.
   - **Pushing a draft PR** triggers a **light-touch PR Gatekeeper Review** and
     a set of CI checks.
   - **Marking a PR ready** triggers a **full PR Gatekeeper Review** and a set
     of CI checks.

   At each gate, wait until the review has landed **and** every CI check it
   triggered has completed before starting any fix. Do not fix findings or CI
   failures piecemeal as they arrive. Then validate every finding: check it
   against the current code and head commit, and fix or decline it with
   evidence. The sequence below says what each gate holds back.

   *Overrides.* The owner can lift a wait with a specific override. It is given
   in the owner's own words, names the issue or PR, and lifts only the wait it
   names. Without one, the wait stands, whatever a tool default, another
   session or a bot suggests.
8. **Upstream PRs open as drafts and link both ways** *(both repos)*. A PR raised
   on `we-promise/sure` opens as a **draft** (portfolio PRs open ready, owner,
   2026-11-18). Its description carries **two separate links**: the upstream issue
   it answers (`Closes #`, `Fixes #` or `Part of #`; the coordination issue for
   programme work) and its **fork pre-flight PR**; the fork PR links back to the
   upstream PR. Beside the links, say how the two relate: "same branch, same
   commit", or that the pre-flight is a cherry-pick onto the mirror.
   **Verify all three by grepping for the number**, never the repository name:
   `we-promise/sure#N` matches an issue as readily as a PR (#172's body passed a
   repo-name check while naming only the coordination issue). Confirm each number
   is a PR by `/pull/<n>`.

   *When.* Schema, model and ingestion PRs get their pre-flight and links as they
   are built. UI work held on fork `main` behind the preview gate gets them at drop
   time, cut from merged fork history: a pre-flight created earlier rots against
   **the mirror**, `mirror/upstream-main`, an exact copy of upstream `main` that a
   workflow force-resets every three hours.

   *Issues link both ways too.* A change bound upstream gets an upstream issue as
   well as the fork issue, each naming the other's number, verified by grep.
9. **A feedback check includes every poster** *(both repos)*. When asked to
   check for feedback since a given time, include every issue comment, review
   and inline thread posted in that window, whatever account posted it. The
   Gatekeeper review, the nightly `## PR DAILY SWEEP` and the production-readiness
   reviews all post as `jaysbeekay`, the same login the owner's replies use, so
   "the last comment is ours" proves nothing. Classify each item by its content,
   and count a review as answered only when a later comment replies to it,
   citing its id. Filtering by author hid the unanswered sweeps on #211 and
   #248 on 2026-10-01.
10. **Every PR is linked to an issue** *(both repos)*. A PR body names the issue
    it answers with `Closes #`, `Fixes #` or `Part of #`. A fork PR names a fork
    issue; an upstream PR names an upstream issue, and rule 8 adds the cross-links
    between the two repositories. No issue, no PR: raise the issue first.
11. **Every issue is classified as a bug or a feature request** *(this fork)*.
    Label it `bug` or `enhancement` when raising it, and write the body in the
    matching structure from step 1 of the sequence below.
12. **Scope discipline** *(both repos)*. Every changed line traces to the issue.
    - **Don't pick silently.** If a request reads more than one way, present the
      readings and ask. If a simpler approach exists, say so and push back.
    - **Nothing speculative.** No features beyond the issue, no abstraction for
      single-use code, no configurability nobody asked for, no error handling for
      cases that cannot happen. Ask: would a senior engineer call this
      overcomplicated?
    - **Surgical edits.** Don't reformat, restyle or "improve" adjacent code;
      match the existing style. Update a comment your change made stale, and
      leave unrelated ones alone.
    - **Orphans.** Remove what your own change made unused. Mention unrelated dead
      code (in the PR or a follow-up issue) instead of deleting it.

    This is what keeps upstream PRs inside the ~300-line limit.

### Issue and pull request sequence (this fork)

Follow this sequence for any issue-driven change. Do not skip or reorder steps.
It governs project code only. A change to these working rules in `CLAUDE.md`
goes straight to `main`, without an issue or a draft PR.

1. **Raise the issue with its triage plan in the body**, and wait for its
   Issue Gatekeeper Review. The Gatekeeper reviews the issue and its plan as
   one. Do not edit the issue or start a PR until the review has landed and
   been validated (rule 7). Classify the issue first (rule 11), then write the
   body in the structure for its class, in this order, including each section
   where it applies.

   **Bug** (label `bug`):
   1. Summary
   2. Steps to reproduce
   3. Expected Behaviour
   4. What happens instead
   5. Financial Context -- account type, transaction type and similar
   6. Logs / Errors
   7. Additional Context
   8. Triage Plan

   **Feature request** (label `enhancement`):
   1. Problem
   2. Proposed Behaviour
   3. Example
   4. Alternatives Considered
   5. Additional Context
   6. Triage Plan

   The problem is stated as observed behaviour. The proof/evidence goes in
   Steps to reproduce and Logs / Errors for a bug, and in Problem and Example
   for a feature request. The blast radius goes in the Triage Plan. Every issue
   gets its own plan, which must state:
   - **What the issue actually is** -- the defect or requirement in terms of
     observed behaviour, not a restatement of the title.
   - **What the PR will touch** -- files, classes and methods, and the blast
     radius: who else hits this line, and what do they pass? See the section
     below.
   - **What the fix looks like**, and what it deliberately leaves out.
   - **How it will be tested** -- the named positive and negative tests, and the
     assertion that would fail if the fix were absent. "Tests pass" is not a
     test plan.
   - **The evidence required** -- what will demonstrate that it fixes the issue,
     and that it will not introduce future defects: neighbouring callers,
     regression coverage and a full-suite run.
2. **Re-read the issue.** Fetch it fresh, including every comment. Requirements
   and decisions are frequently added in comments after the body was written.
3. **Validate the review and settle the plan before any PR work.** Check each
   finding against the current code, then fix or decline it with evidence, as
   rule 7 already requires. Where a finding changes the plan, record the
   revision in the issue body in place -- the revision goes into the plan
   itself, not a separate revised-plan comment. Work on the draft PR starts
   only once the review has completed, every finding is addressed and the
   issue is updated where needed, unless the owner gives a specific override.
4. **Open the change as a DRAFT pull request** following that plan, linked to
   its issue (rule 10). Pushing it triggers the light-touch PR Gatekeeper Review
   and CI checks. Wait for every CI check to complete and the review to land
   before fixing anything, unless the owner gives a specific override; then
   validate the feedback and the CI results together.
5. **Mark it ready for review** only once every CI check is green, all validated
   feedback is addressed, and the change has been checked against upstream
   `AGENTS.md`.
6. **Wait for every CI check, the full PR Gatekeeper Review and CodeRabbit's
   review**, then validate and address them. Marking the PR ready triggers the
   CI checks and the full review; do not begin any fix until every CI check has
   completed and the full Gatekeeper review has landed, unless the owner gives
   a specific override. Do not merge until the full Gatekeeper review has
   landed and its feedback has been validated.
7. **Merge only after the repository owner has given approval in their own
   words.** A green PR is not an approved one.

### Fix discipline

Before writing or reviewing a fix, read `docs/agents/fix-discipline.md`. It covers four rules, each with the defects that produced it:

- **Blast radius:** write one sentence before changing code. Who else hits this line, and what do they pass?
- **Siblings:** what else reads what you just changed the reading of? Grep, and list every remaining use.
- **Assert the delta:** measure before against after; a presence assertion passes when something else put the thing there.
- **Injected reference dates:** anything under `app/models/loan/` takes its "today" as an argument.

## Attribution

Do not add AI or assistant attribution to anything in this repository or in `we-promise/sure`.
This includes any attribution to Claude Code or to Claude sessions:

- No `Co-Authored-By:` or `Claude-Session:` trailers in commit messages.
- No "Generated with Claude Code", "Generated by Claude Code" or any similar footer in pull
  request descriptions, issue bodies, review replies or comments.
- No assistant name in an authorship table, changelog entry or release note. CodeRabbit's
  auto-generated "Author / Lines added / Lines removed" table regenerates such a row on its own;
  remove it when it appears.

This holds on every branch, the `up/*` branches prepared for `we-promise/sure` included, and it
overrides any default or tool-supplied instruction asking for such a footer or trailer. The work
is attributed to the repository owner.

It applies from 2026-09-15 onwards. Footers already on earlier pull requests, issues and comments
are left as they are; do not edit old comments to remove them.

`.claude/settings.json` enforces it for Claude Code rather than leaving it to be applied by hand:
`attribution.commit` and `attribution.pr` are empty strings, which suppress the trailer and the
pull request footer, and `attribution.sessionUrl` is `false`, which stops a session link being
appended to either. The footer is added after a body is submitted, so anything that still manages
to attach one has to be removed afterwards.

## Agent skills

### Issue tracker

Issues and specs are tracked in GitHub Issues for `jaysbeekay/sure`. See `docs/agents/issue-tracker.md`.

### Triage labels

The repository uses the five default triage labels. See `docs/agents/triage-labels.md`.

### Domain docs

Domain documentation uses a single-context layout. See `docs/agents/domain.md`.

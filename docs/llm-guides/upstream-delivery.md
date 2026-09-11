# Delivering a change to we-promise/sure

One branch, two pull requests, ordinary commits. This replaces the
squash-and-rebuild flow the loan chart went through (`docs/plans/loan-chart-upstream-delivery.md`),
which cost a rebuild, a hand-applied diff and a force-push for every review round.

## The flow

1. **Branch from upstream, not from fork `main`.** Fork `main` carries work that is not
   going upstream. `git fetch upstream main && git checkout -b up/<feature> upstream/main`.
   The `up/` prefix is what the scripts below key on.
2. **Open the fork PR first**, against `mirror/upstream-main`:
   `bin/upstream-pr fork --title "..."`. The mirror is refreshed from we-promise/sure `main`
   every night (`.github/workflows/mirror-upstream.yml`), so the fork PR's diff is exactly the
   diff upstream will see, and this fork's CI and review bots run on it.
3. **When it is green, open the upstream PR from the same branch**, as a draft:
   `bin/upstream-pr upstream --title "..." --fixes <upstream issue>`. The body comes from
   `docs/upstream/pr-body.md`; fill in demo data, screenshots and migration notes before taking
   it out of draft, because maintainers ask for all three.
4. **Answer review with commits, not replacements.** Push fix commits to `up/<feature>`. Both
   PRs update; a reviewer's thread stays attached to the line it was on, and the bots review the
   increment. Upstream squash-merges, so the commit list on the branch is not what lands.
   Reply on a thread with one line naming the commit; leave resolving to the maintainer.
5. **Rebase only when you must**: a conflict with `main`, or a maintainer asking, or right
   before merge. `bin/upstream-rebase <test paths>` rebases onto `upstream/main`, lints the
   files the branch changes, and runs the tests you name.
6. **A stacked change** branches from the parent's `up/` branch and carries the parent's commits
   until the parent's upstream PR merges; say so in the body. Then
   `bin/upstream-rebase --onto up/<parent> <test paths>` drops them.
7. **Sync fork `main` weekly**: `bin/upstream-sync` opens the merge PR. Rebase open `up/*`
   branches after it merges so conflicts stay small.

## Rules that keep it cheap

- **Small PRs.** A refactor that changes no behaviour is its own PR and merges in a day; the
  feature that needs it follows. Maintainers review about once a day, so a PR's size sets how
  many days it takes.
- **One bot on the fork, the one upstream uses.** CodeRabbit runs on both sides; its fork run
  catches what its upstream run would. Other bots on `up/*` branches produce a second set of
  threads to answer for the same findings.
- **Fork-only artefacts stay fork-only.** Contract-coverage gates, evidence transcripts, delivery
  briefs and epic plans are for the fork's epics. They do not go in an `up/*` branch and they do
  not gate an upstream push.
- **Never force-push a branch with an open upstream PR** except to rebase, and say so in a
  comment when you do.

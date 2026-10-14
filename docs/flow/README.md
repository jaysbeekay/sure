# Delivery flow project

A GitHub Project ("Sure delivery") and a PR check ("Flow gate") that show, for every tracked issue
and pull request, **where it is in the delivery sequence, who acts next, and what they need to do**.
It is built from what the sequence already produces (Gatekeeper reviews, the nightly review,
replies that cite a review's id, CI, CodeRabbit and the upstream PR), so nothing new has to be
written to keep it current.

It runs **beside** the current way of working. Only issues labelled `flow:v2`, and the pull
requests that name them, are tracked. Nothing else is read, and nothing is written outside the
project and the gate check. An item moves across by being labelled; it moves back by losing the
label.

Everything here is fork process: `.github/flow/`, the `flow-*` workflows, the two issue forms and
this page. None of it travels upstream (`up/*` branches are cut from upstream `main`).

## The sequence it tracks

```
upstream issue (we-promise/sure)
  └─ fork issue, linked to it, with a triage plan          Triage plan
       └─ Gatekeeper issue review                           Issue review → Address issue review
            └─ plan settled                                 Ready to build
                 └─ draft PR: light review + CI             Draft PR → Address draft feedback
                      └─ all green, every review answered   Mark ready
                           └─ ready: full review + CI + CodeRabbit   Full review → Address full review
                                └─ upstream draft PR        Upstream PR (pre-flights)
                                                            Owner approval (PRs into fork main)
```

| Stage | Means | Waiting |
|---|---|---|
| Triage plan | The issue has no `Triage Plan` section, or its upstream link is a PR rather than an issue | Author |
| Issue review | No Gatekeeper issue review yet, or a not-ready decision was answered and needs a re-review | Gatekeeper |
| Address issue review | A review on the issue has no reply citing its id | Author |
| Ready to build | The latest issue review is READY and answered, and no PR names the issue | Author |
| Draft PR | No light review since the PR opened, or checks still running | Gatekeeper / CI |
| Address draft feedback | Review and CI are both in, and a review is unanswered, a check is red, or a thread is open | Author |
| Mark ready | CI green, every review answered, no open threads | Author |
| Full review | No full review since the PR went ready, checks running, CodeRabbit not in yet, or a non-approving verdict was answered | Gatekeeper / CI / CodeRabbit |
| Address full review | As for draft feedback, after the full review | Author |
| Upstream PR | Full review approved and answered. Then: link the upstream issue, open the upstream draft, make it link back, finish it and mark it ready, then wait on maintainers | Author / Upstream |
| Owner approval | An approved PR into fork `main` (or a stacked PR), waiting on the owner's approval in their own words | Owner |
| Done | Closed, merged, or landed upstream | Nobody |

**Rule 7 is built in.** Nothing goes to the author while the review for the current step is missing
*or* any check is still running. The author is asked to act only when both are in, and then
gets every finding at once.

An issue with several PRs reports the **least advanced** one: that is what holds it up. Every PR
also has its own item.

## Fields

Set by the sync on every event. Do not edit them; they are overwritten.

| Field | Values |
|---|---|
| Stage | The stages above |
| Waiting | Author, Gatekeeper, CI, CodeRabbit, Owner, Upstream, Nobody |
| Upstream | Fork only, Needs upstream issue, Upstream issue linked, Pre-flight open, Upstream draft, Upstream ready, Landed upstream, Closed unmerged |
| CI | Pending, Green, Red, None (PRs only) |
| Kind | Epic, Issue, Pre-flight PR (into `mirror/upstream-main`), Fork PR (into `main`), Stacked PR |
| Unanswered | Reviews with no reply citing their id (rule 9) |
| Next step | What to do next, in words |
| Last review | The latest review: kind, verdict, risk, head, and whether it is answered |
| Fork issue / Upstream issue / Upstream PR | The links the sync found |

Set by people. The sync never touches them.

| Field | Values |
|---|---|
| Priority | P0 drop everything · P1 next · P2 planned · P3 someday |
| Severity (bugs) | S1 money wrong, data lost, or a security or privacy leak · S2 a wrong figure or a broken flow · S3 broken, with a workaround · S4 cosmetic, or a missing test |
| Size | S 1-2 days · M 3-5 days · L 1-2 weeks · XL split it |

Priority is set when the plan is settled, the step where the owner already validates the issue
review.

## What it reads, and the conventions it relies on

These are the conventions already in use. The sync makes them visible; it does not add new ones.

- **Reviews** are comments by the owner's login whose **first line** is one of:
  - `## 🔎 QA Review` (or the older `**QA review — #N — READY**`): issue review
  - `## 👀 PR Review - Light`: light review
  - `## ✅ PR Review - Full`: full review
  - `# NIGHTLY REVIEW`: the nightly Codex review
  - `## PR DAILY SWEEP`: the daily sweep

  The verdict comes from `**Decision:**` / `**Verdict:**`, or the nightly `Production Readiness`
  line. A review split into parts ("(1/2)", "(part 2 of 4)", "(continued)") is one review. A
  heading quoted further down a reply is never read as a review.
- **Answered** means a later comment, by the owner or a collaborator and not itself a review,
  cites the review's id: its number (`6131615763`) or its node id (`IC_…`).
- **Issue ↔ PR**: the PR body says `Closes #N`, `Fixes #N`, `Resolves #N` or `Part of #N`. A bare
  mention such as "Fork-main fix: #432" is not a link. Pre-flights are found too, although GitHub's
  own "linked pull requests" leaves them out because they do not target `main`.
- **Upstream issue**: a line in the issue body such as `Upstream issue: we-promise/sure#4221`, or
  the issue form's field. Write `none` in the form for fork-only work.
- **Upstream PR**: a line in the pre-flight's body such as `Upstream PR: we-promise/sure#4174`
  (or `Upstream draft PR:`). The sync reads that PR's state, and checks that its body names the
  pre-flight by number (rule 8).
- **CI**: every check run and commit status on the head commit, except the Flow gate itself and
  CodeRabbit.
- **CodeRabbit** counts once it has reviewed after the PR went ready. It is never waited on for a
  draft (rule 4).

**Optional, for Hermes and the nightly job.** A reviewer can state its result exactly with a hidden
first line, and the heading is then not parsed at all:

```
<!-- flow-review kind=full verdict=APPROVE head=3b26ce722 -->
```

`kind` is `issue`, `light`, `full`, `nightly` or `sweep`. Adding it to the `qa-issue-review` and
`pr-gatekeeper` skills would make the flow independent of heading wording.

## Setup

Done once, in this order. Until steps 1 to 4 are complete the sync only logs what it would do.

1. **Create the project token.** A classic personal access token with the `project` scope
   (github.com → Settings → Developer settings → Personal access tokens → Tokens (classic)). Add
   it as the repository secret `PROJECT_TOKEN` (Settings → Secrets and variables → Actions →
   Secrets). It is used to write project fields and, for its higher rate limit, to read public
   data. If adding an item later fails with a permission error, add the `public_repo` scope. A
   fine-grained token may not reach a user-owned project; the classic one does.
2. **Merge this to `main`.** Workflows triggered by comments, schedules and dispatch run only from
   the default branch.
3. **Run "Flow bootstrap"** (Actions → Flow bootstrap → Run workflow). Tick *dry run* first if you
   want to see what it will do. It creates the `flow:v2` label, the "Sure delivery" project linked
   to this repository, and every field. It is safe to re-run.
4. **Set the variable** `FLOW_PROJECT_NUMBER` to the number the bootstrap printed (Settings →
   Secrets and variables → Actions → Variables).
5. **Create the views** below. The API cannot create views, so this is done by hand in the
   project.
6. **Pilot** (next section).

### Views

| View | Layout | Filter | Group / columns | Sort |
|---|---|---|---|---|
| Needs me | Table | `waiting:Owner -stage:Done` | | Priority |
| Untriaged | Table | `no:priority -stage:Done -kind:Epic` | Kind | Created |
| Board | Board | `-stage:Done -kind:Epic` | Columns: Stage | Priority |
| Who acts next | Table | `-waiting:Nobody` | Group: Waiting | Priority |
| Unanswered reviews | Table | `unanswered:>0` | | Unanswered, descending |
| Upstream pipeline | Board | `-upstream:"Fork only" -kind:Epic` | Columns: Upstream | Priority |
| Bugs | Table | `label:bug -stage:Done` | Group: Severity | Priority |
| CI red | Table | `ci:Red` | | Updated |
| Epics | Table | `kind:Epic` | | Show the built-in *Sub-issues progress* field |

Show the *Next step* and *Last review* columns in the table views. The project's built-in
*Status* field is not used and can be hidden or deleted.

In the project's **Workflows** settings, turn on *Auto-archive items* for items closed more than
two weeks ago. Leave *Auto-add* off: items join by label, through the sync.

## Pilot, then migration

1. **Pilot.** Label a few items that are at different stages, for example:
   - #455 (plan settled, no PR yet);
   - #424 (a fork PR and a pre-flight with an upstream PR);
   - a new downstream issue raised with the *Bug (delivery flow)* form from a we-promise/sure issue.

   Run *Flow sync* by hand with the number, or wait for the next event. Compare the fields and the
   Flow gate with your own reading for a week.
2. **Adjust.** Settings live in `.github/flow/config.mjs`: reviewer logins, whether CodeRabbit is
   waited on, the opt-in label. The stage rules are in `stage.mjs`, with tests beside them.
3. **Migrate.** Select the open issues in the issue list, apply `flow:v2` in bulk, then run *Flow
   sync* with no number to fill the project. Label the epics too, and link their drops as
   sub-issues so the Epics view shows progress.
4. **Adopt.** When it reads right, make the forms the default (`.github/ISSUE_TEMPLATE/config.yml`
   with `blank_issues_enabled: false`, and retire the two upstream templates), and update CLAUDE.md
   to point at the project.

To back out at any point: remove the label from the items, disable the *Flow sync* workflow, and
delete the project. Nothing else depends on it.

## Behaviour worth knowing

- **It never comments, labels or pushes.** Its only writes are project fields and the Flow gate
  check. So it cannot trigger Gatekeeper (`main.yml` reacts to the owner's `@codebot` comments) or
  any other workflow. The only trace on an issue or PR is GitHub's own "added this to Sure
  delivery" line when the item first joins the project.
- **The Flow gate never fails a PR.** It is *neutral* while something is owed, and *success* once the
  PR can move on. It never blocks a merge unless it is made a required check, which is not
  recommended during the pilot.
- **Timing.** Comments, pushes, ready/draft changes, reviews and the *Pull Request* and *CodeQL
  Advanced* workflows trigger a sync at once. Checks from other apps (Codacy, cubic), resolving a
  review thread, and upstream PR changes are picked up by the hourly run.
- **PRs from forks.** Review events on a PR from a fork run without secrets, so they only log; the
  next event on the base repository, or the hourly run, picks them up.
- **CodeRabbit on this fork.** CodeRabbit's own comment on #432 says this repository gets no
  automatic reviews while it has fewer than ten stars. Ready PRs therefore wait on CodeRabbit
  until it is triggered: tick *Trigger review* in its summary comment, or comment
  `@coderabbitai review` (allowed on a ready PR, rule 4). To stop waiting on it, set
  `coderabbitRequiredOnReady: false`.
- **Reviews that predate the current headings.** A handful of September-era reviews used other
  formats ("## PR Gatekeeper Review #N", "Gate review — ...") and are not read. A migrated item
  whose only review is one of those shows *Issue review* or *Full review*: request a fresh review.

## Running it locally

Read-only, against live data, without writing anything:

```bash
GH_TOKEN=<any token> node .github/flow/sync.mjs --issue 424 --dry-run --ignore-opt-in --json
node --test .github/flow/test/*.test.mjs
```

`--ignore-opt-in` shows what an item *would* read as before it is labelled.

# Project status automation

`.github/workflows/project-status.yml` moves cards on the project board as work goes through the
delivery sequence. Decisions are in `.github/project-status/logic.mjs`. The tests in
`.github/project-status/test/` cover those decisions and run `main.mjs` end to end against a fake
GitHub (`node --test .github/project-status/test/*.test.mjs`).

## What moves a card

| Event | Moves the issue (and PR) to |
|---|---|
| The owner comments `@codebot …` on an issue | Issue review |
| Gatekeeper posts a `QA Review` on an issue | Issue review |
| A reply cites a READY QA review by its id (`6167015210`) or node id (`IC_…`) | Ready to build |
| A draft PR opens with `Closes #N`, `Fixes #N`, `Resolves #N` or `Part of #N` | In progress (PR and each named issue) |
| The PR is marked ready, or opens ready | In review |
| A pre-flight (base `mirror/upstream-main`) names `Upstream PR: we-promise/sure#N` | Upstream |

- **Forward-only.** A card is never moved back, so one you have dragged further on stays put.
  The PR's state wins for the board's normal statuses: a card dragged back to an earlier one moves
  forward again at the next event or sweep. Use Blocked to hold a card.
- **Blocked holds a card.** A card at a status this script never sets, such as Blocked, is left
  there by every automatic move, PR events and the sweep alike. Only a manual run moves it. A card
  with no status still moves.
- **Epics are skipped** (`type:epic`); their progress comes from sub-issues.
- **Closed items are skipped.** Done, closed and reopened are left to the board's built-in workflows.
- **PRs from outside the repository move only their own card**, and only at the next sweep (up to an
  hour). Their `pull_request` runs get no secrets, so they are skipped (as are Dependabot's) and
  the sweep is what moves them. Anyone can write
  their body, so the issues a PR names move only when its author is the owner, a member or a
  collaborator.
- **Pre-flights work too, at the next sweep.** Their `up/*` heads are cut from upstream and do not
  carry this workflow, so no PR event runs for them. GitHub does not link a PR into
  `mirror/upstream-main` to its issue, but the sweep reads the PR body, so `Closes #N` on a
  pre-flight still moves issue `#N`.
- **A PR with a merge conflict moves at the next sweep.** GitHub runs no `pull_request` workflow for
  it, so marking it ready moves its card within the hour rather than at once.

## When it runs

| Trigger | What it reads |
|---|---|
| `issue_comment` | The comment, and the issue's earlier comments when it cites a review |
| `pull_request` (opened, edited, ready for review) | The PR, for same-repository PRs whose head carries this workflow |
| `schedule` (hourly, `--sweep`) | Every open PR, whatever its base, read as if it had just been edited |
| `workflow_dispatch` | The number and status you give it |

`pull_request_target` is not used: GitHub blocks it by default in public repositories from
2026-12-02. The sweep makes the same decisions as a PR event, and moves are forward-only, so a PR
both paths see is written at most once.

## Moving a card by hand (you, or a Claude session)

Actions → **Project status** → **Run workflow**, with the issue or PR number and a status. A manual
move is forced: it can move a card backwards.

A Claude session cannot write to the board itself, but it can start this workflow (the GitHub
tools' "run workflow" call, workflow `project-status.yml`, ref `main`, inputs `number` and
`status`).

## Setup

1. **Token.** Create a classic personal access token with the `project` scope (Settings →
   Developer settings → Personal access tokens → Tokens (classic)). The Actions token cannot write
   to a project owned by a personal account. If a run reports a permission error when adding an
   item, add the `repo` scope.
2. **Secret.** Save it as the repository secret `PROJECT_TOKEN` (Settings → Secrets and variables →
   Actions → Secrets).
3. **Variables** (same page, Variables tab):
   - `PROJECT_NUMBER`: the board's number, from its URL (`/users/jaysbeekay/projects/<number>`).
   - `GATEKEEPER_LOGINS`: the login Gatekeeper posts as, for example `sure-gatekeeper`. Several
     can be listed, separated by commas. Until it is set, reviews are taken from the repository
     owner, which is how Gatekeeper posts today. Once Gatekeeper moves to its own account, set it,
     so a QA heading posted by anyone else is ignored.
4. **Status options.** The board's Status field needs these options, spelt this way (case does not
   matter): Triage, Issue review, Ready to build, In progress, In review, Upstream, Done. A run that
   meets a missing option fails and lists the options the board does have.

Until `PROJECT_TOKEN` and `PROJECT_NUMBER` are both set, every run logs "Not configured" and moves
nothing.

## Keep these built-in board workflows on

Auto-add to project (`is:issue,pr is:open`), Auto-add sub-issues, Item added → Triage (issues),
Item closed → Done, Pull request merged → Done, Item reopened → Triage, Auto-archive. Leave Code
review approved, Code changes requested and Auto-close issue off.

## Safety

The workflow never checks out pull request code: every trigger, `pull_request` included, runs the
script from the default branch. Under `pull_request` the workflow file itself is read from the PR's
head, and only same-repository PRs, whose authors can already push, get `PROJECT_TOKEN`. Anyone who
can push can already read repository secrets through a push-triggered workflow, so this adds no
exposure. The token is a classic personal access token with the `project` scope (and `repo` if
setup needed it). It never
comments, labels or pushes, and setting a project field triggers no workflow, so it cannot start
Gatekeeper (`main.yml`) or itself.

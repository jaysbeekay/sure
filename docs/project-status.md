# Project status automation

`.github/workflows/project-status.yml` moves cards on the project board as work goes through the
delivery sequence. Decisions are in `.github/project-status/logic.mjs`, tested in
`.github/project-status/test/`.

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
- **Epics are skipped** (`type:epic`); their progress comes from sub-issues.
- **Closed items are skipped.** Done, closed and reopened are left to the board's built-in workflows.
- **Pre-flights work too.** GitHub does not link a PR into `mirror/upstream-main` to its issue, but
  this reads the PR body, so `Closes #N` on a pre-flight still moves issue `#N`.

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

The workflow never checks out pull request code: every trigger, `pull_request_target` included,
runs the script from the default branch. It never comments, labels or pushes, and setting a project
field triggers no workflow, so it cannot start Gatekeeper (`main.yml`) or itself.

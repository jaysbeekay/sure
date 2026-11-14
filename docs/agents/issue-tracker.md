# Issue tracker: GitHub

Issues and specs for this repo live in `jaysbeekay/sure` GitHub Issues. Use the `gh` CLI with `-R jaysbeekay/sure` for all operations.

Follow the issue classifications, body structures, evidence requirements, gatekeeper workflow, and other repository-specific rules in `CLAUDE.md`.

## Conventions

- **Create an issue**: `gh issue create -R jaysbeekay/sure --title "..." --body "..."`.
- **Read an issue**: `gh issue view -R jaysbeekay/sure <number> --json number,title,body,labels,comments`.
- **List issues**: `gh issue list -R jaysbeekay/sure --state open --json number,title,body,labels,comments`.
- **Comment**: `gh issue comment -R jaysbeekay/sure <number> --body "..."`.
- **Apply or remove labels**: use `gh issue edit -R jaysbeekay/sure`.
- **Close**: `gh issue close -R jaysbeekay/sure <number> --comment "..."`.
- **Sub-issues**: use `gh issue create --parent <parent>` or `gh issue edit <parent> --add-sub-issue <child>` when supported. Otherwise, put `Part of #<parent>` at the top of the child body.

## Pull requests as a triage surface

**PRs as a request surface: no.**

GitHub shares one number space across issues and pull requests. Resolve an ambiguous `#42` with `gh pr view -R jaysbeekay/sure 42`, then fall back to `gh issue view`.

## When a skill says "publish to the issue tracker"

Create an issue in `jaysbeekay/sure`, following `CLAUDE.md`.

## When a skill says "fetch the relevant ticket"

Read the issue from `jaysbeekay/sure`, including its labels and comments.

## Wayfinding operations

The map is a single issue labelled `wayfinder:map`, with child issues as tickets.

- Child labels use `wayfinder:<type>`: `research`, `prototype`, `grilling`, or `task`.
- Represent blocking relationships with GitHub's native issue dependencies when available.
- Claim a ticket by assigning it to the driving developer.
- Resolve it by recording the answer, closing the ticket, and adding a context pointer to the map.

# Upstream texts for we-promise/sure#4149 and #4150

Prepared on the fork for the owner to post upstream. Not code; this branch is never merged.

Both upstream PRs are opened from this fork's branches, so their code is already current:

| Upstream PR | Fork pre-flight | Fork branch | Head these texts describe |
| --- | --- | --- | --- |
| we-promise/sure#4149 | jaysbeekay/sure#347 | `up/gains-closed-holdings` | `47a614f93` |
| we-promise/sure#4150 | jaysbeekay/sure#412 | `up/rule-email-backfill` | `e073e3f6e` |

Each body opens with `Closes #… Fork pre-flight: jaysbeekay/sure#…`, and both fork PRs name their upstream PR, so the links run both ways.

**Refreshed 2026-10-12.** Both descriptions are copied verbatim from the upstream sections that the fork PR descriptions (#347 and #412) carry at those heads. Their commit lists and diffstats were checked against `git diff --stat 2b18df230` of each branch.

**Not verified from here.** The session that refreshed these could not read the upstream PRs at all: the API and the web page both returned 403. So it could not tell which replies are already posted. Fork #412 records that the reply to CodeRabbit's finding on #4150 is posted (`discussion_r4249144383`) and its thread resolved. Nothing records the same for #4149.

## Posting order

1. Re-read both upstream PRs and their threads for anything posted since 2026-10-12 09:13 UTC. Skip any reply below that is already there.
2. **#4149**
   - Replace the description with `upstream-4149-body.md`.
   - Post replies 1–3 in `upstream-4149-replies.md`, each in its own review thread, then resolve that thread. Reply 3 answers the CodeRabbit finding that `47a614f93` fixes (a provider row at zero quantity). Its thread title isn't quoted, because this session couldn't read it.
   - Optionally, post `upstream-4149-perf-note.md` as a comment.
3. **#4150**
   - Replace the description with `upstream-4150-body.md`.
   - Post reply 2 in `upstream-4150-reply.md` in Codex's P1 thread ("Detect criteria removals after importers clear the association"), unless it's already there, then resolve it. Reply 1 is already posted.
4. Convert both PRs to draft.
5. Check that nothing appended a footer to the descriptions or replies.

If either fork branch moves past the heads above, check the commit hashes in these texts against its head before posting.

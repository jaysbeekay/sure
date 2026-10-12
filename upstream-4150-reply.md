# Replies for we-promise/sure#4150

## 1. CodeRabbit's finding on identical re-imports (fixed in e073e3f6e): already posted

Fork PR #412 records that this reply was posted in CodeRabbit's thread ([discussion_r4249144383](https://github.com/we-promise/sure/pull/4150#discussion_r4249144383), answering [discussion_r4246083394](https://github.com/we-promise/sure/pull/4150#discussion_r4246083394)) and that the thread was resolved. Nothing to post. Check that the reply carries no footer.

---

## 2. Codex's thread ("Detect criteria removals after importers clear the association", P1), fixed in 55ce46826

This session could not read the upstream threads, so it could not check whether this one was posted already. If it was, skip it. Otherwise post it in that thread, then resolve it.

Thanks. Confirmed, and fixed in 55ce46826.

Reproduced through both importers. `Family::DataImporter#import_rules` and `RuleImport` both clear an existing rule's conditions with `destroy_all` before saving it. With an empty conditions list in the import, nothing was left for `note_match_criteria_change` to see. A rule with no conditions matches every transaction, so the next run emailed an old one ("Tea house").

Both importers now mark the old conditions for destruction instead of destroying them up front. The rule's save removes them through autosave, inside the same transaction. `match_criteria_changing?` already counts a condition marked for destruction as a change, so the baseline is taken again, and `Rule` itself needed no change for this. (e073e3f6e later changed `Rule` for CodeRabbit's separate finding, that an identical re-import now re-seeded too.)

New tests, one per importer: "a Sure re-import that removes every condition does not email existing matches" and "re-importing an email rule with no conditions does not email existing matches". Each fails with the old `destroy_all`.

---

## 3. CodeRabbit's "Docstring coverage" pre-merge check

CodeRabbit's "Docstring coverage" pre-merge check (33% against 80%) needs no reply. The PR adds one public method, `Rule::Condition#match_criteria_changing?`, with its own comment block. Its other new methods are private to `Rule`.

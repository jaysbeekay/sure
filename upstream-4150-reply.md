# Reply to post in Codex's thread on we-promise/sure#4150 ("Detect criteria removals after importers clear the association", P1), then resolve it

Thanks. Confirmed, and fixed in 55ce46826.

Reproduced through both importers. `Family::DataImporter#import_rules` and `RuleImport` both clear an existing rule's conditions with `destroy_all` before saving it. With an empty conditions list in the import, nothing was left for `note_match_criteria_change` to see. A rule with no conditions matches every transaction, so the next run emailed an old one ("Tea house").

Both importers now mark the old conditions for destruction instead of destroying them up front. The rule's save removes them through autosave, inside the same transaction. `match_criteria_changing?` already counts a condition marked for destruction as a change, so the baseline is taken again, and `Rule` itself needed no change.

New tests, one per importer: "a Sure re-import that removes every condition does not email existing matches" and "re-importing an email rule with no conditions does not email existing matches". Each fails with the old `destroy_all`.

---

# The other #4150 item

CodeRabbit's "Docstring coverage" pre-merge check (33% against 80%) needs no reply. The PR adds one public method, `Rule::Condition#match_criteria_changing?`, with its own comment block. It also adds three private methods to `Rule`, which share the comment block above the two callbacks that use them.

Closes #4102. Fork pre-flight: jaysbeekay/sure#412.

## Problem

An email-notification rule records the transactions it already matches as delivered (a baseline), so it only reports what appears afterwards. The baseline describes the match set of the conditions and effective date it was taken under.

Editing the rule to match more brought older transactions into range: a broader condition, a removed condition, or an earlier or cleared effective date. The next run then emailed them as new activity, and the email does not say they are old.

## Change

- **`Rule::Condition#match_criteria_changing?`** is true when a condition is new, marked for destruction, or its type, operator or value is changing, at any depth (compound sub-conditions included).
  - It reads only in-memory state, so it runs no query.
  - A value moving between `nil` and `""` is not a change: the edit form sends a valueless condition's hidden value back as `""` where an import stored `nil`.
- **`Rule`** records and acts on the change in two callbacks:
  - `before_update :note_match_criteria_change` records whether `effective_date` or any condition is changing. It runs before the save because autosave removes destroyed conditions from the association.
  - `after_update :seed_notification_baseline, if: :match_criteria_changed?` then re-seeds through `NotificationDelivery.record_for(rule_id:, transaction_ids: matching_transaction_ids)`, for a rule with a `send_email_notification` action, active or not.
- **`after_update`, not `after_update_commit`.** It runs inside the save's transaction, after the nested autosave, so it reads the conditions as saved. The new baseline commits with the edit, and if writing it fails, the edit rolls back.
- **Both importers mark a rule's old conditions for destruction** instead of `destroy_all`-ing them before the save (`Family::DataImporter#import_rules`, `RuleImport`). The save then removes them through autosave, inside the same transaction, and the rule sees its conditions change.
  - Without this, a re-import whose conditions list is empty left nothing changing. A rule with no conditions matches every transaction, so the next run emailed every older one.
  - The actions are still destroyed up front, as before: they don't decide what the rule matches.

**The cost, stated:** a transaction that arrived since the rule's last run, and matched the old conditions, is absorbed into the new baseline and not emailed. The existing code already prefers that direction ("we would rather miss a digest than spam", `send_email_notification.rb`).

Narrowing edits also re-seed, since a widening can't be told from a narrowing without running both queries. A narrowing edit cannot email history, so its only effect is that same cost.

**Interaction with #4089**, which adds `Rule#seed_notification_baseline` as an `after_update` with `if: :switched_on?`: the method name and body here match it, so whichever lands second merges the two into `if: -> { switched_on? || match_criteria_changed? }`.

```
 app/models/family/data_importer.rb                 |   4 +-
 app/models/rule.rb                                 |  36 +++
 app/models/rule/condition.rb                       |  18 ++
 app/models/rule_import.rb                          |   6 +-
 test/controllers/rules_controller_test.rb          |  86 +++++++
 .../rule/notification_baseline_on_edit_test.rb     | 248 +++++++++++++++++++++
 test/models/rule_import_test.rb                    |  66 ++++++
 7 files changed, 461 insertions(+), 3 deletions(-)
```

## Tests

Measured as `NotificationDelivery` rows and enqueued `RuleEmailNotificationJob` arguments. Each positive test failed on `main` first:

| Test | On `main` |
| --- | --- |
| widening an active email rule's condition does not email existing matches | emailed "Tea house" |
| clearing the effective date does not email existing matches | emailed "Coffee shop" |
| moving the effective date earlier does not email existing matches | emailed "Coffee shop" |
| a new transaction after the widening edit is still emailed | emailed "Tea house" and "Guest house"; only "Guest house" expected |
| changing a condition's operator / type does not email existing matches | emailed "Tea house" |
| removing a condition does not email existing matches | emailed three old transactions |
| widening a compound sub-condition / adding a sub-condition to an any-of group | emailed "Tea house" |
| editing an inactive email rule then applying all rules does not email history | emailed "Tea house" |
| the new baseline is written inside the edit's transaction | baseline missing |
| controller: editing an email rule's condition through the form does not email existing matches | emailed "Tea house" |
| RuleImport: re-importing an email rule with wider conditions does not email existing matches | 1 job enqueued |
| RuleImport: re-importing an email rule with no conditions does not email existing matches | 1 job enqueued (also with the first version of this PR) |
| Sure import: a re-import that removes every condition does not email existing matches | emailed "Tea house" (also with the first version of this PR) |

**Negatives**, passing before and after:
- renaming an email rule does not re-seed;
- resubmitting a valueless condition's blank value does not re-seed;
- editing a rule without an email action writes no deliveries;
- **saving the form with unchanged conditions does not re-seed**, so a match pending since the last run is still emailed;
- the existing Sure re-import test ("session rule reimport only replaces current family conditions and actions") still passes, so the marked conditions are removed and the other family's rule is untouched.

The controller tests load the real edit page and submit every field it holds, as a browser does.

**Mutations, each caught:**
- the callback removed;
- detection limited to the effective date, or the effective-date arm removed;
- no sub-condition detection;
- any resubmitted condition counted as a change;
- an `active?` guard added;
- `nil` vs `""` counted as a change;
- no email-action check;
- `after_update_commit` instead of `after_update`;
- the new/destroyed arm removed, or the operator/type arm removed;
- either importer put back to `conditions.destroy_all` (fails that importer's empty-conditions test).

## Validation

- Rule, rule import, rules controller and data importer tests: 240 runs, 0 failures.
- `bin/rails test` on `f2c50fc42`, the same patches on the previous `main` `d55eac220`: 11,561 runs, 2 failures, both outside this change: `Provider::OpenaiTest#test_extra_headers_stringifies_nested_values_Ruby-style`, a Ruby 3.3 vs 3.4 string difference of the local runner, and the SnapTrade option test that #4145 has since fixed on `main`. Rebased onto `main` `2b18df230` as `b6e7e7348` and `55ce46826` (unchanged patches): rule, rule import, rules controller, data importer and SnapTrade tests, 314 runs, 0 failures.
- `bin/rubocop` on the changed files: no offenses. `bin/brakeman`: 0 warnings. No ERB or JavaScript changed.

## Not in this change

- The create-time baseline that `Rule::Action` declares but never runs, so a new email rule's first run emails its history. That is a separate, older defect with its own fix.
- Whether Apply all should run inactive rules at all.
- Any change to the email's content or to `NotificationDelivery`.

# Fix discipline (this fork)

Moved from `CLAUDE.md` on 2026-11-17 without changing the wording, so it loads only when a fix is being written. The scope note in `CLAUDE.md` applies: this is local policy for `jaysbeekay/sure`, so leave it out of contributions to `we-promise/sure`.

## Before writing any fix: state the blast radius

Write one sentence before changing code:

> **Who else hits this line, and what do they pass?**

This is not optional and it is not a formality. Two defects on this repository
came from checking a fix against *the bug as described* rather than against the
boundary of the code it touched:

- A callback was moved from `before_save` to `validate` so it would actually
  block a save. Correct for the reported case; it then rejected every ordinary
  edit of a loan that already had an offset account, because the form
  resubmits the ids it already holds. The blast-radius sentence contains that
  bug outright.
- A reference date was pinned at the view layer. The component it was passed to
  then handed the work to `Loan::PayoffProjection`, which derived its own date,
  so the defect moved down a level instead of closing.

Two corollaries:

- **Follow the value one hop further than feels necessary.** If a fix is "pass
  X in", check whether the callee also derives X for itself.
- **Prove the test before trusting it.** Break the fix deliberately and watch
  the new test fail. A test written after a fix tends to assert the author's
  mental model, which is the thing that was wrong.

### The other direction: grep the siblings, not just the callers

The question above points **downstream**, at whoever calls the line being
changed. It does not catch the miss that keeps happening, which is **lateral**:
other code reading the same source, which should have changed alongside it.

So ask a second question before pushing:

> **What else reads what I just changed the reading of?**

Both of these were missed by the author on #226 and caught in review, and
both were one grep away:

- A parent filter was threaded into `allocation_holdings_within`'s look-through
  branch. `holdings_classified_as` -- the flat branch's selector -- had the
  identical defect and was left alone, so half the ladder stayed broken.
- `allocatable_holdings` was introduced to exclude corrupt rows, and the child
  paths were routed through it. Four parent segment builders
  (`allocation_by_classification`, `_by_currency`, `_by_kind`, `_by_tag`) still
  read `current_holdings`, so the levels disagreed one step above where the
  test was looking.

**How to apply.**

- **When a fix replaces a direct use of X with a new helper, `grep -n "X"` and
  enumerate every remaining use.** Each is either deliberately unchanged with a
  stated reason, or a sibling that was missed. Write the list out; do not
  eyeball it. Say in the commit message which siblings were found and why any
  were left.
- **A method with two paths is an invitation to fix half a bug.** Wherever there
  is `if look_through ... else ...`, cached/uncached, sync/async -- fixing one
  path means checking the other in the same change.
- **Assert a new invariant at every level it claims to hold**, not at the level
  being edited. Both misses above had the matching test gap: the assertion sat
  where the author was already looking.
- **Treat a review finding as a symptom report, not a work order.** A reviewer
  names one call site because that is where they happened to look; the defect
  lives wherever the pattern does. Shipping the narrow fix means the next review
  finds the siblings, at the cost of a full cycle each time.

## Assert the delta, not the presence

**A test that asserts a thing EXISTS passes when something else put it there.**
Assert the change the code under test causes, measured against the state
without it.

This produced six vacuous tests in a single delivery cycle, at least four of
them found by review rather than by the author. Every one asserted presence,
every one passed while the behaviour it named was deleted:

- *"an untagged holding falls into the unclassified bucket"* asserted an
  `unclassified` segment existed. The fixture account's positive cash balance
  produces one on its own, so deleting the untagged branch outright left all
  eleven tests in the file passing.
- *"a cash constituent lands in liquidity"* asserted a `liquidity` segment
  existed -- again produced by the account's own cash. Rewritten to assert the
  delta, it still passed, because the defaults slice fills a fresh cash security
  with `liquidity`/`cash` and the bucket then resolves correctly either way.
  Only emptying those columns first exercises what the fix decides.
- *"a blank sector is stored as nil"* asserted `nil` on a column that was `nil`
  before the request, and the request had been rejected by an unrelated
  validation.
- *"a proposal that only answers the region"* asserted `nil` on columns the
  security never had.
- *"a fund's holdings land in the table when the per-account importer runs"* and
  *"...when the family importer runs"* asserted constituents were stored while
  the importer returned early on `return unless Security.provider`, which is
  unset in test -- so they passed against an importer that did nothing, which
  was the defect.

**How to apply.**

- **Measure against the alternative.** Capture the value with the behaviour off,
  then with it on, and assert the difference. `before`/`after` beats `present?`.
- **Ask what else could produce this.** Fixtures, defaults, callbacks, another
  holding, cash balances. If anything else can, presence proves nothing.
- **Set the precondition rather than assuming it.** If the state the test needs
  is one the code would create anyway, force it -- `update_columns` to bypass a
  callback, an explicit value rather than a fixture default.
- **A test that passes before the fix is written is not evidence.** This is the
  fail-first rule, and presence assertions are how it gets skipped by accident:
  they fail on a missing method, then pass for the wrong reason once it exists.

## Reference dates are injected, never derived

Anything under `app/models/loan/` and its view components takes its "today" as
an argument. Defaulting to `Date.current` in the signature is fine; reading
`Date.current` in the body of a method that already has a caller-supplied date
is not. A view that shows several date-sensitive figures captures ONE date and
passes it to all of them.

This class of defect has recurred repeatedly on the loan epic (#79, #83, #86,
#89 -- all fork PR numbers): a date or an eligibility gate derived independently
in several places, correct for the caller it was written for and silently wrong
for the next one added.

The loan amortisation work is fork-local, so this convention is too. It would
still be worth proposing upstream on its own merits, but as a discussion rather
than as a rule that arrived inside an unrelated change.

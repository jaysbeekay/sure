// Comment and body text copied from real items on this repository, trimmed to
// the lines the parsers read. Each names where it came from, so a format change
// in Gatekeeper or the nightly job can be checked against the original.

// #455, comment 6167015210 (Issue Gatekeeper).
export const QA_REVIEW = `## 🔎 QA Review

**Decision:** READY  ·  **Type:** DEFECT  ·  **Risk:** HIGH  ·  **Confidence:** HIGH
**Target branch:** \`we-promise/sure\` main @ \`a3bb5d991\`  ·  **Follow-up of:** first review

### Material Gaps
None.`;

// #432, comment 6131615763 (light PR Gatekeeper).
export const LIGHT_REVIEW = `## 👀 PR Review - Light

**Verdict:** DRAFT_ON_TRACK
**Risk:** HIGH
**Confidence:** HIGH
**Reviewed HEAD:** \`3b26ce722e31d282d42b65e71ff8f7248df53c00\`

### Assessment

The override sits at the right choke point.`;

// #432, comment 6134294307 (nightly Codex review).
export const NIGHTLY_REVIEW = `# NIGHTLY REVIEW

## Production Readiness
✅ READY TO MERGE

## Summary
This PR anchors a newly created loan's opening balance to the loan start date.`;

// #432, comment 6163919947 (full PR Gatekeeper).
export const FULL_REVIEW = `## ✅ PR Review - Full

**Verdict:** APPROVE  ·  **Risk:** HIGH  ·  **Confidence:** MEDIUM
**Base:** \`main\`  ·  **CI:** PASSING (all \`ci/*\`, CodeQL, Analyze* green; no failures or pending checks)

### Material Findings

None.

---
Reviewed commit: \`3b26ce722e31d282d42b65e71ff8f7248df53c00\``;

// The three reply styles in use, from #432 and #455.
export const REPLY_LIGHT = "Reply to the Gatekeeper light review (comment 6131615763), checked at head `3b26ce722`.\n\nDRAFT_ON_TRACK, with no material findings.";
export const REPLY_NIGHTLY = "Reply to the nightly review (comment 6134294307), checked at head `3b26ce722`.\n\nREADY TO MERGE.";
export const REPLY_FULL = "Re the full Gatekeeper review 6163919947 (APPROVE), checked at `3b26ce722`, unchanged since the review.";
export const REPLY_QA = "Re QA review 6167015210 (READY). There are no material gaps, so the plan's fix and tests are unchanged.";

// #455, comment 6166663347: not a review, and cites no review id.
export const UPSTREAM_NOTE = "Upstream issue: we-promise/sure#4221 (raised 2026-10-14; it names this issue). This goes in as a comment because the body stays unedited until the Issue Gatekeeper review has landed.";

// #440's body (pre-flight against mirror/upstream-main), first lines.
export const PREFLIGHT_BODY = `## Summary

Closes #424

Upstream issue: we-promise/sure#3383
Upstream draft PR: we-promise/sure#4174 ([pull/4174](https://github.com/we-promise/sure/pull/4174)), opened 2026-10-13 from this same branch and commit (\`ecc26bd70\`).
Fork-main fix: #432 (\`fix/424-loan-anchor-start-date\` into \`main\`).

Base: \`mirror/upstream-main\` at \`3e35aaa07\`.`;

// What bin/upstream-pr writes into a fork pre-flight before the upstream PR exists.
export const PREFLIGHT_TEMPLATE_BODY = `## Summary

Fork pre-flight for the upstream PR (Fixes we-promise/sure#3295); base is mirror/upstream-main at the same commit as upstream main, so the diff is what upstream will see.`;

// #424's body: the upstream link and the plan heading.
export const ISSUE_BODY = `## Summary

When a loan is created with a start date, its opening anchor is not dated on that start date.

## Additional Context

- **Upstream issue:** we-promise/sure#3383. It was filed on 2026-09-04.

## Triage Plan

**What the issue actually is.** For a new loan with a start date, the opening anchor holding the original principal is dated on an unrelated default (today minus two years) instead of on the start date.

**What the PR will touch.** \`Account.create_and_sync\` (\`app/models/account.rb\`).`;

// What the new issue forms render.
export const FORM_BODY = `### Upstream issue

https://github.com/we-promise/sure/issues/4221

### Summary

Holding copy-forward fails without an external_id.

### Triage Plan

**What the issue actually is.** For an import without an \`external_id\`, \`import_holding\` matches today's row and the copy-forward source only by the incoming security.`;

export const FORM_BODY_NO_UPSTREAM = `### Upstream issue

none

### Summary

A fork-only defect.

### Triage Plan

_No response_`;

// #432, CodeRabbit's summary comment on a repository under ten stars.
export const CODERABBIT_SKIPPED = `<!-- This is an auto-generated comment: summarize by coderabbit.ai -->
<!-- This is an auto-generated comment: skip review by coderabbit.ai -->

> [!IMPORTANT]
> This repository does not receive automatic reviews because it has fewer than 10 stars.`;

export function comment(id, body, { login = "jaysbeekay", association = "OWNER", at = "2026-10-12T00:00:00Z" } = {}) {
  return {
    id,
    body,
    user: { login },
    author_association: association,
    created_at: at,
    updated_at: at,
    html_url: `https://github.com/jaysbeekay/sure/issues/1#issuecomment-${id}`,
  };
}

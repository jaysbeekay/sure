import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { CONFIG } from "../config.mjs";
import {
  citedIds,
  classifyReview,
  coderabbitState,
  extractReviews,
  parseLinks,
  prKind,
  summariseChecks,
  triagePlanPresent,
} from "../parse.mjs";
import {
  CODERABBIT_SKIPPED,
  comment,
  FORM_BODY,
  FORM_BODY_NO_UPSTREAM,
  FULL_REVIEW,
  ISSUE_BODY,
  LIGHT_REVIEW,
  NIGHTLY_REVIEW,
  PREFLIGHT_BODY,
  PREFLIGHT_TEMPLATE_BODY,
  QA_REVIEW,
  REPLY_FULL,
  REPLY_LIGHT,
  REPLY_NIGHTLY,
  REPLY_QA,
  UPSTREAM_NOTE,
} from "./fixtures.mjs";

const REPO = "jaysbeekay/sure";

describe("classifyReview", () => {
  test("reads the issue Gatekeeper review", () => {
    assert.deepEqual(classifyReview(QA_REVIEW), { kind: "issue", verdict: "READY", risk: "HIGH", head: null });
  });

  test("reads the light review and its head", () => {
    assert.deepEqual(classifyReview(LIGHT_REVIEW), {
      kind: "light",
      verdict: "DRAFT_ON_TRACK",
      risk: "HIGH",
      head: "3b26ce722e31d282d42b65e71ff8f7248df53c00",
    });
  });

  test("reads the full review and its reviewed commit", () => {
    assert.deepEqual(classifyReview(FULL_REVIEW), {
      kind: "full",
      verdict: "APPROVE",
      risk: "HIGH",
      head: "3b26ce722e31d282d42b65e71ff8f7248df53c00",
    });
  });

  test("reads the nightly review's production-readiness line", () => {
    assert.deepEqual(classifyReview(NIGHTLY_REVIEW), { kind: "nightly", verdict: "READY TO MERGE", risk: null, head: null });
  });

  test("reads both spellings of the daily sweep heading", () => {
    assert.equal(classifyReview("## PR DAILY SWEEP\n\nFindings.").kind, "sweep");
    assert.equal(classifyReview("## DAILY PR SWEEP\n\nFindings.").kind, "sweep");
  });

  test("a verdict without an emoji still reads", () => {
    assert.equal(classifyReview("## PR Review - Full\n\n**Verdict:** REQUEST_CHANGES").verdict, "REQUEST_CHANGES");
  });

  test("a hidden marker overrides the headings", () => {
    const body = "<!-- flow-review kind=full verdict=APPROVE head=abc1234 -->\nAnything";
    assert.deepEqual(classifyReview(body), { kind: "full", verdict: "APPROVE", risk: null, head: "abc1234" });
  });

  test("reads the older bold-line issue review and its re-review (#424)", () => {
    assert.deepEqual(classifyReview("**QA review — #424 — READY**\n\nMarker: `body:11065`"), { kind: "issue", verdict: "READY", risk: null, head: null });
    assert.equal(classifyReview("**QA re-review — #424 — READY** (re-grounded 2026-10-12)").verdict, "READY");
  });

  test("reads unbolded and fully bolded verdict lines (#386, #422)", () => {
    assert.equal(classifyReview("## QA Review\n\nDecision: READY\nType: DEFECT").verdict, "READY");
    assert.equal(classifyReview("## QA Review\n\n**Issue type:** defect\n**Verdict: PASS** — the defect is real").verdict, "PASS");
  });

  test("a lower-case word after 'verdict' is not read as one", () => {
    assert.equal(classifyReview("## QA Review\n\nThe verdict: the plan is sound.").verdict, null);
  });

  test("replies and notes are not reviews", () => {
    for (const body of [REPLY_LIGHT, REPLY_NIGHTLY, REPLY_FULL, REPLY_QA, UPSTREAM_NOTE]) {
      assert.equal(classifyReview(body), null, body);
    }
  });

  test("a reply written as a heading is not a review", () => {
    assert.equal(classifyReview("## Re QA Review 6167015210\n\nNothing to change."), null);
    assert.equal(classifyReview("## Reply PR Review - Full\n\nNothing to change."), null);
  });

  test("a heading quoted inside a reply is not a review", () => {
    assert.equal(classifyReview(`Re the review:\n\n> ## ✅ PR Review - Full\n> **Verdict:** APPROVE`), null);
    assert.equal(classifyReview(`> ## ✅ PR Review - Full\n> **Verdict:** APPROVE`), null);
  });
});

describe("extractReviews", () => {
  test("a review heading from an untrusted login is ignored", () => {
    const comments = [
      comment(1, FULL_REVIEW, { login: "someone-else", association: "NONE" }),
      comment(2, LIGHT_REVIEW),
    ];
    assert.deepEqual(
      extractReviews(comments, CONFIG).map((r) => r.id),
      [2],
    );
  });

  test("a review is answered only by a later trusted comment citing its id", () => {
    const comments = [
      comment(6131615763, LIGHT_REVIEW, { at: "2026-10-12T19:58:05Z" }),
      comment(6134294307, NIGHTLY_REVIEW, { at: "2026-10-12T23:03:51Z" }),
      comment(6140297116, REPLY_LIGHT, { at: "2026-10-13T07:10:35Z" }),
    ];
    const reviews = extractReviews(comments, CONFIG);
    assert.deepEqual(
      reviews.map((r) => [r.id, r.answered]),
      [
        [6131615763, true],
        [6134294307, false],
      ],
    );
  });

  test("a reply citing the review's node id answers it (#424)", () => {
    const qa = { ...comment(6122618617, "**QA review — #424 — READY**", { at: "2026-10-12T10:39:46Z" }), node_id: "IC_kwDOUI0WXs8AAAABbO---Q" };
    const reply = comment(6123390683, "Re QA review IC_kwDOUI0WXs8AAAABbO---Q (READY):\n\n1. **Line numbers: declined.**", { at: "2026-10-12T11:30:58Z" });
    assert.equal(extractReviews([qa, reply], CONFIG)[0].answered, true);
  });

  test("a review posted in parts is one review, answered by citing any part (#357)", () => {
    const comments = [
      comment(6068658058, "## ✅ PR Review - Full (1/2)\n\n**Verdict:** APPROVE  ·  **Risk:** LOW", { at: "2026-10-08T10:00:00Z" }),
      comment(6068661964, "## ✅ PR Review - Full (2/2)\n\nThis comment and the one above form a single review.", { at: "2026-10-08T10:00:05Z" }),
      comment(7, "Re the full review 6068658058: approved, nothing to change.", { at: "2026-10-08T11:00:00Z" }),
    ];
    const reviews = extractReviews(comments, CONFIG);
    assert.equal(reviews.length, 1);
    assert.equal(reviews[0].verdict, "APPROVE");
    assert.equal(reviews[0].answered, true);
  });

  test("the verdict of a multi-part review can sit in a later part (#363)", () => {
    const comments = [
      comment(1000000001, "## 👀 PR Review - Light (part 1 of 2)\n\n### Assessment", { at: "2026-10-08T10:00:00Z" }),
      comment(1000000002, "## 👀 PR Review - Light (part 2 of 2)\n\n**Verdict:** DRAFT_CONCERNS", { at: "2026-10-08T10:00:05Z" }),
    ];
    const reviews = extractReviews(comments, CONFIG);
    assert.equal(reviews.length, 1);
    assert.equal(reviews[0].verdict, "DRAFT_CONCERNS");
    assert.equal(reviews[0].answered, false);
  });

  test("a '(continued)' part joins an unmarked first part (#421)", () => {
    const comments = [
      comment(1000000001, "## ✅ PR Review - Full\n\n**Verdict:** APPROVE", { at: "2026-10-08T10:00:00Z" }),
      comment(1000000002, "## ✅ PR Review - Full (continued)\n\n### Test Evidence", { at: "2026-10-08T10:00:05Z" }),
    ];
    assert.equal(extractReviews(comments, CONFIG).length, 1);
  });

  test("'part 1' of a forced re-review starts a new review, not a continuation of the last (#363)", () => {
    const comments = [
      comment(1000000001, "## 👀 PR Review - Light\n\n**Verdict:** DRAFT_ON_TRACK", { at: "2026-10-07T10:00:00Z" }),
      comment(1000000002, "## 👀 PR Review - Light (forced re-review, part 1 of 2)\n\n### Assessment", { at: "2026-10-08T10:00:00Z" }),
      comment(1000000003, "## 👀 PR Review - Light (forced re-review, part 2 of 2)\n\n**Verdict:** DRAFT_CONCERNS", { at: "2026-10-08T10:00:05Z" }),
    ];
    const reviews = extractReviews(comments, CONFIG);
    assert.deepEqual(
      reviews.map((r) => [r.id, r.verdict]),
      [
        [1000000001, "DRAFT_ON_TRACK"],
        [1000000002, "DRAFT_CONCERNS"],
      ],
    );
  });

  test("two separate reviews of the same kind stay separate", () => {
    const comments = [
      comment(1000000001, "## ✅ PR Review - Full\n\n**Verdict:** CHANGES_REQUESTED", { at: "2026-10-08T10:00:00Z" }),
      comment(1000000002, "## ✅ PR Review - Full\n\n**Verdict:** APPROVE", { at: "2026-10-09T10:00:00Z" }),
    ];
    assert.equal(extractReviews(comments, CONFIG).length, 2);
  });

  test("an untrusted reply citing the id does not answer the review", () => {
    const comments = [
      comment(6131615763, LIGHT_REVIEW, { at: "2026-10-12T19:58:05Z" }),
      comment(9, REPLY_LIGHT, { login: "drive-by", association: "NONE", at: "2026-10-13T07:10:35Z" }),
    ];
    assert.equal(extractReviews(comments, CONFIG)[0].answered, false);
  });

  test("a citation posted before the review does not answer it", () => {
    const comments = [
      comment(5, REPLY_LIGHT, { at: "2026-10-12T00:00:00Z" }),
      comment(6131615763, LIGHT_REVIEW, { at: "2026-10-12T19:58:05Z" }),
    ];
    assert.equal(extractReviews(comments, CONFIG)[0].answered, false);
  });

  test("a later review that happens to cite an id does not count as the reply", () => {
    const comments = [
      comment(6131615763, LIGHT_REVIEW, { at: "2026-10-12T19:58:05Z" }),
      comment(7, `${FULL_REVIEW}\n\nFollow-up of 6131615763.`, { at: "2026-10-13T00:00:00Z" }),
    ];
    assert.equal(extractReviews(comments, CONFIG)[0].answered, false);
  });
});

describe("citedIds", () => {
  test("finds comment ids, and not issue numbers or short shas", () => {
    assert.deepEqual([...citedIds(REPLY_LIGHT)], ["6131615763"]);
    assert.deepEqual([...citedIds(UPSTREAM_NOTE)], []);
  });
});

describe("parseLinks", () => {
  test("a pre-flight body names its fork issue, upstream issue and upstream PR", () => {
    assert.deepEqual(parseLinks(PREFLIGHT_BODY, REPO, CONFIG.upstreamRepo), {
      forkIssues: [424],
      upstreamIssue: 3383,
      upstreamDeclaredNone: false,
      upstreamPr: 4174,
    });
  });

  test("a mention without a closing keyword is not a link", () => {
    // "Fork-main fix: #432" names a PR, not the issue this PR answers.
    assert.ok(!parseLinks(PREFLIGHT_BODY, REPO, CONFIG.upstreamRepo).forkIssues.includes(432));
  });

  test("bin/upstream-pr's fork template names the upstream issue, not an upstream PR", () => {
    assert.deepEqual(parseLinks(PREFLIGHT_TEMPLATE_BODY, REPO, CONFIG.upstreamRepo), {
      forkIssues: [],
      upstreamIssue: 3295,
      upstreamDeclaredNone: false,
      upstreamPr: null,
    });
  });

  test("an upstream keyword link is not a fork issue", () => {
    assert.deepEqual(parseLinks("Fixes we-promise/sure#3383", REPO, CONFIG.upstreamRepo).forkIssues, []);
  });

  test("Part of, Fixes and a full fork URL all link a fork issue", () => {
    const body = "Part of #118\nFixes jaysbeekay/sure#455\nResolves https://github.com/jaysbeekay/sure/issues/424";
    assert.deepEqual(parseLinks(body, REPO, CONFIG.upstreamRepo).forkIssues, [118, 455, 424]);
  });

  test("an issue body names its upstream issue in prose or in the form field", () => {
    assert.equal(parseLinks(ISSUE_BODY, REPO, CONFIG.upstreamRepo).upstreamIssue, 3383);
    assert.equal(parseLinks(FORM_BODY, REPO, CONFIG.upstreamRepo).upstreamIssue, 4221);
  });

  test("the form's 'none' declares a fork-only issue", () => {
    const links = parseLinks(FORM_BODY_NO_UPSTREAM, REPO, CONFIG.upstreamRepo);
    assert.equal(links.upstreamIssue, null);
    assert.equal(links.upstreamDeclaredNone, true);
  });

  test("an upstream PR given as a URL is found", () => {
    const body = "Upstream PR: https://github.com/we-promise/sure/pull/4197";
    assert.equal(parseLinks(body, REPO, CONFIG.upstreamRepo).upstreamPr, 4197);
  });
});

describe("triagePlanPresent", () => {
  test("present under a ## or ### heading with content", () => {
    assert.equal(triagePlanPresent(ISSUE_BODY), true);
    assert.equal(triagePlanPresent(FORM_BODY), true);
  });

  test("absent when the heading is missing or the form field is empty", () => {
    assert.equal(triagePlanPresent("## Summary\n\nNo plan."), false);
    assert.equal(triagePlanPresent(FORM_BODY_NO_UPSTREAM), false);
    assert.equal(triagePlanPresent("## Triage Plan\n\nTBD\n\n## Other"), false);
  });
});

describe("summariseChecks", () => {
  const run = (name, status, conclusion, slug = "github-actions") => ({ name, status, conclusion, app: { slug } });

  test("green only when every check finished and passed", () => {
    const s = summariseChecks({
      checkRuns: [run("ci / test", "completed", "success"), run("CodeQL", "completed", "neutral"), run("skip", "completed", "skipped")],
      statuses: [],
    });
    assert.equal(s.state, "Green");
  });

  test("one failure is red, even with others pending", () => {
    const s = summariseChecks({
      checkRuns: [run("ci / test", "completed", "failure"), run("ci / lint", "in_progress", null)],
      statuses: [],
    });
    assert.equal(s.state, "Red");
    assert.deepEqual(s.failing, ["ci / test"]);
  });

  test("pending while any check is unfinished", () => {
    const s = summariseChecks({ checkRuns: [run("ci / test", "queued", null)], statuses: [] });
    assert.equal(s.state, "Pending");
  });

  test("the gate's own check and CodeRabbit are left out", () => {
    const s = summariseChecks({
      checkRuns: [
        run("Flow gate", "completed", "neutral"),
        run("CodeRabbit", "in_progress", null, "coderabbitai"),
        run("ci / test", "completed", "success"),
      ],
      statuses: [{ context: "CodeRabbit", state: "pending" }],
    });
    assert.equal(s.state, "Green");
  });

  test("the gate's own check alone is no CI at all", () => {
    assert.equal(summariseChecks({ checkRuns: [run("Flow gate", "completed", "success")], statuses: [] }).state, "None");
  });

  test("a failing commit status is red", () => {
    const s = summariseChecks({ checkRuns: [], statuses: [{ context: "codacy", state: "failure" }] });
    assert.equal(s.state, "Red");
  });

  test("no checks at all reads as none", () => {
    assert.equal(summariseChecks({ checkRuns: [], statuses: [] }).state, "None");
  });

  test("a re-run that passed replaces the failed run of the same name", () => {
    const s = summariseChecks({
      checkRuns: [
        { ...run("ci / test", "completed", "failure"), id: 1, started_at: "2026-10-12T10:00:00Z" },
        { ...run("ci / test", "completed", "success"), id: 2, started_at: "2026-10-12T11:00:00Z" },
      ],
      statuses: [],
    });
    assert.equal(s.state, "Green");
  });
});

describe("coderabbitState", () => {
  const readyAt = "2026-10-13T00:00:00Z";
  const login = CONFIG.coderabbitLogin;

  test("reviewed when it submits a review after the PR went ready", () => {
    const reviews = [{ user: { login }, submitted_at: "2026-10-13T01:00:00Z" }];
    assert.equal(coderabbitState({ reviews, comments: [], readyAt, login }), "reviewed");
  });

  test("a review from before the PR went ready does not count", () => {
    const reviews = [{ user: { login }, submitted_at: "2026-10-12T01:00:00Z" }];
    assert.equal(coderabbitState({ reviews, comments: [], readyAt, login }), "missing");
  });

  test("reviewed when its summary says it found nothing, after ready", () => {
    const comments = [comment(1, "No actionable comments were generated in the recent review.", { login, association: "NONE", at: "2026-10-13T02:00:00Z" })];
    assert.equal(coderabbitState({ reviews: [], comments, readyAt, login }), "reviewed");
  });

  test("skipped when it says the repository gets no automatic reviews", () => {
    const comments = [comment(1, CODERABBIT_SKIPPED, { login, association: "NONE", at: "2026-10-12T17:59:49Z" })];
    assert.equal(coderabbitState({ reviews: [], comments, readyAt, login }), "skipped");
  });
});

describe("prKind", () => {
  test("by base branch", () => {
    assert.equal(prKind({ base: { ref: "mirror/upstream-main" } }, CONFIG), "Pre-flight PR");
    assert.equal(prKind({ base: { ref: "main" } }, CONFIG), "Fork PR");
    assert.equal(prKind({ base: { ref: "up/retirement-plan-model" } }, CONFIG), "Stacked PR");
  });
});

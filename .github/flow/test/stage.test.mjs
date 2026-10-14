import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { CONFIG } from "../config.mjs";
import { computeIssue, computePr, gateConclusion } from "../stage.mjs";

const T0 = "2026-10-12T00:00:00Z";
const T1 = "2026-10-12T10:00:00Z";
const T2 = "2026-10-13T10:00:00Z";
const T3 = "2026-10-14T10:00:00Z";

function review(kind, verdict, { id = 1, at = T1, answered = true } = {}) {
  return { id, kind, verdict, risk: "HIGH", head: null, createdAt: at, answered, url: `#${id}` };
}

function pr(overrides = {}) {
  return {
    number: 432,
    state: "open",
    merged: false,
    draft: true,
    kind: "Pre-flight PR",
    createdAt: T0,
    readyAt: null,
    reviews: [],
    ci: { state: "Green", failing: [], pending: [] },
    unresolvedThreads: 0,
    coderabbit: "missing",
    upstreamIssue: 3383,
    upstreamPr: null,
    ...overrides,
  };
}

describe("computePr: draft", () => {
  test("no light review yet: waiting on Gatekeeper, whatever CI says", () => {
    const r = computePr(pr({ ci: { state: "Red", failing: ["ci / test"], pending: [] } }), CONFIG);
    assert.equal(r.stage, "Draft PR");
    assert.equal(r.waitingOn, "Gatekeeper");
  });

  test("light review in but CI still running: waiting on CI, not the author (rule 7)", () => {
    const r = computePr(pr({ reviews: [review("light", "DRAFT_ON_TRACK", { answered: false })], ci: { state: "Pending", failing: [], pending: ["ci / test"] } }), CONFIG);
    assert.equal(r.stage, "Draft PR");
    assert.equal(r.waitingOn, "CI");
  });

  test("light review and CI in, review unanswered: the author validates", () => {
    const r = computePr(pr({ reviews: [review("light", "DRAFT_ON_TRACK", { id: 6131615763, answered: false })] }), CONFIG);
    assert.equal(r.stage, "Address draft feedback");
    assert.equal(r.waitingOn, "Author");
    assert.equal(r.unanswered, 1);
    assert.match(r.next.join("\n"), /6131615763/);
  });

  test("CI red after the review landed: the author fixes it", () => {
    const r = computePr(pr({ reviews: [review("light", "DRAFT_ON_TRACK")], ci: { state: "Red", failing: ["ci / test"], pending: [] } }), CONFIG);
    assert.equal(r.stage, "Address draft feedback");
    assert.match(r.next.join("\n"), /ci \/ test/);
  });

  test("an unresolved review thread holds the PR in feedback", () => {
    const r = computePr(pr({ reviews: [review("light", "DRAFT_ON_TRACK")], unresolvedThreads: 2 }), CONFIG);
    assert.equal(r.stage, "Address draft feedback");
  });

  test("an unanswered nightly review holds the PR in feedback too (rule 9)", () => {
    const r = computePr(pr({ reviews: [review("light", "DRAFT_ON_TRACK"), review("nightly", "READY TO MERGE", { id: 2, answered: false })] }), CONFIG);
    assert.equal(r.stage, "Address draft feedback");
  });

  test("everything answered and green: mark ready", () => {
    const r = computePr(pr({ reviews: [review("light", "DRAFT_ON_TRACK")] }), CONFIG);
    assert.equal(r.stage, "Mark ready");
    assert.equal(r.waitingOn, "Author");
  });

  test("a light review from before the PR was opened does not count", () => {
    const r = computePr(pr({ createdAt: T2, reviews: [review("light", "DRAFT_ON_TRACK", { at: T1 })] }), CONFIG);
    assert.equal(r.waitingOn, "Gatekeeper");
  });

  test("CodeRabbit is never waited on while the PR is a draft", () => {
    const r = computePr(pr({ reviews: [review("light", "DRAFT_ON_TRACK")], coderabbit: "missing" }), CONFIG);
    assert.notEqual(r.waitingOn, "CodeRabbit");
  });
});

describe("computePr: ready", () => {
  const ready = (o) => pr({ draft: false, readyAt: T2, reviews: [review("light", "DRAFT_ON_TRACK")], coderabbit: "reviewed", ...o });

  test("no full review since it went ready: waiting on Gatekeeper", () => {
    const r = computePr(ready({ reviews: [review("light", "DRAFT_ON_TRACK"), review("full", "APPROVE", { id: 3, at: T1 })] }), CONFIG);
    assert.equal(r.stage, "Full review");
    assert.equal(r.waitingOn, "Gatekeeper");
  });

  test("full review in, CI running: waiting on CI", () => {
    const r = computePr(ready({ reviews: [review("full", "APPROVE", { at: T3 })], ci: { state: "Pending", failing: [], pending: ["x"] } }), CONFIG);
    assert.equal(r.waitingOn, "CI");
  });

  test("full review and CI in, CodeRabbit not yet: waiting on CodeRabbit", () => {
    const r = computePr(ready({ reviews: [review("full", "APPROVE", { at: T3 })], coderabbit: "missing" }), CONFIG);
    assert.equal(r.stage, "Full review");
    assert.equal(r.waitingOn, "CodeRabbit");
  });

  test("CodeRabbit skipped for the star count says how to trigger it", () => {
    const r = computePr(ready({ reviews: [review("full", "APPROVE", { at: T3 })], coderabbit: "skipped" }), CONFIG);
    assert.equal(r.waitingOn, "CodeRabbit");
    assert.match(r.next.join("\n"), /Trigger review/);
  });

  test("CodeRabbit is not waited on when it is configured off", () => {
    const r = computePr(ready({ reviews: [review("full", "APPROVE", { at: T3 })], coderabbit: "missing" }), { ...CONFIG, coderabbitRequiredOnReady: false });
    assert.notEqual(r.waitingOn, "CodeRabbit");
  });

  test("full review unanswered: address it", () => {
    const r = computePr(ready({ reviews: [review("full", "APPROVE", { at: T3, answered: false })] }), CONFIG);
    assert.equal(r.stage, "Address full review");
  });

  test("a non-approving full review that was answered needs a re-review", () => {
    const r = computePr(ready({ reviews: [review("full", "REQUEST_CHANGES", { at: T3 })] }), CONFIG);
    assert.equal(r.stage, "Full review");
    assert.equal(r.waitingOn, "Gatekeeper");
    assert.match(r.next.join("\n"), /re-review/);
  });

  test("approved pre-flight with no upstream PR named: open the upstream draft", () => {
    const r = computePr(ready({ reviews: [review("full", "APPROVE", { at: T3 })] }), CONFIG);
    assert.equal(r.stage, "Upstream PR");
    assert.equal(r.waitingOn, "Author");
    assert.equal(r.upstream, "Pre-flight open");
    assert.match(r.next.join("\n"), /bin\/upstream-pr upstream/);
  });

  test("approved pre-flight without an upstream issue: link one first", () => {
    const r = computePr(ready({ reviews: [review("full", "APPROVE", { at: T3 })], upstreamIssue: null }), CONFIG);
    assert.equal(r.stage, "Upstream PR");
    assert.match(r.next.join("\n"), /upstream issue/i);
  });

  test("upstream draft linked back: the author finishes it and marks it ready", () => {
    const r = computePr(
      ready({ reviews: [review("full", "APPROVE", { at: T3 })], upstreamPr: { number: 4174, state: "draft", backlinked: true } }),
      CONFIG,
    );
    assert.equal(r.stage, "Upstream PR");
    assert.equal(r.waitingOn, "Author");
    assert.equal(r.upstream, "Upstream draft");
  });

  test("upstream PR ready and linked back: waiting on upstream maintainers", () => {
    const r = computePr(
      ready({ reviews: [review("full", "APPROVE", { at: T3 })], upstreamPr: { number: 4174, state: "open", backlinked: true } }),
      CONFIG,
    );
    assert.equal(r.waitingOn, "Upstream");
    assert.equal(r.upstream, "Upstream ready");
  });

  test("upstream PR that does not name this pre-flight is flagged (rule 8)", () => {
    const r = computePr(
      ready({ reviews: [review("full", "APPROVE", { at: T3 })], upstreamPr: { number: 4174, state: "open", backlinked: false } }),
      CONFIG,
    );
    assert.equal(r.waitingOn, "Author");
    assert.match(r.next.join("\n"), /does not name #432/);
  });

  test("an upstream PR that cannot be read is reported as such, not as a missing back-link", () => {
    const r = computePr(
      ready({ reviews: [review("full", "APPROVE", { at: T3 })], upstreamPr: { number: 99999, state: "unknown", backlinked: false } }),
      CONFIG,
    );
    assert.equal(r.waitingOn, "Author");
    assert.match(r.next.join("\n"), /could not be read/);
  });

  test("approved fork PR waits on the owner, not on upstream", () => {
    const r = computePr(ready({ kind: "Fork PR", reviews: [review("full", "APPROVE", { at: T3 })] }), CONFIG);
    assert.equal(r.stage, "Owner approval");
    assert.equal(r.waitingOn, "Owner");
    assert.equal(r.upstream, null);
  });
});

describe("computePr: closed", () => {
  test("a merged fork PR is done", () => {
    assert.equal(computePr(pr({ kind: "Fork PR", state: "closed", merged: true }), CONFIG).stage, "Done");
  });

  test("a closed pre-flight still follows its open upstream PR", () => {
    const r = computePr(pr({ state: "closed", upstreamPr: { number: 4174, state: "open", backlinked: true } }), CONFIG);
    assert.equal(r.stage, "Upstream PR");
    assert.equal(r.waitingOn, "Upstream");
    assert.equal(r.active, true);
  });

  test("a pre-flight whose upstream PR landed is done", () => {
    const r = computePr(pr({ state: "closed", upstreamPr: { number: 4174, state: "merged", backlinked: true } }), CONFIG);
    assert.equal(r.stage, "Done");
    assert.equal(r.upstream, "Landed upstream");
    assert.equal(r.active, false);
  });
});

describe("computeIssue", () => {
  const issue = (o) => ({
    number: 424,
    state: "open",
    hasTriagePlan: true,
    upstreamIssue: { number: 3383, isPr: false, state: "open" },
    upstreamDeclaredNone: false,
    upstreamCandidate: true,
    reviews: [review("issue", "READY")],
    prs: [],
    ...o,
  });

  test("no triage plan: the author writes one", () => {
    const r = computeIssue(issue({ hasTriagePlan: false }), CONFIG);
    assert.equal(r.stage, "Triage plan");
    assert.equal(r.waitingOn, "Author");
  });

  test("an upstream link that is a pull request is caught (rule 8)", () => {
    const r = computeIssue(issue({ upstreamIssue: { number: 4174, isPr: true, state: "open" } }), CONFIG);
    assert.equal(r.stage, "Triage plan");
    assert.match(r.next.join("\n"), /pull request/);
  });

  test("plan written, no review: waiting on Gatekeeper", () => {
    const r = computeIssue(issue({ reviews: [] }), CONFIG);
    assert.equal(r.stage, "Issue review");
    assert.equal(r.waitingOn, "Gatekeeper");
  });

  test("review in, unanswered: address it", () => {
    const r = computeIssue(issue({ reviews: [review("issue", "READY", { answered: false })] }), CONFIG);
    assert.equal(r.stage, "Address issue review");
  });

  test("a not-ready decision that was answered needs a re-review", () => {
    const r = computeIssue(issue({ reviews: [review("issue", "NOT_READY")] }), CONFIG);
    assert.equal(r.stage, "Issue review");
    assert.equal(r.waitingOn, "Gatekeeper");
  });

  test("the latest review decides: a later READY settles an earlier NOT_READY", () => {
    const r = computeIssue(issue({ reviews: [review("issue", "NOT_READY", { id: 1, at: T1 }), review("issue", "READY", { id: 2, at: T2 })] }), CONFIG);
    assert.equal(r.stage, "Ready to build");
  });

  test("settled with no PR: ready to build", () => {
    const r = computeIssue(issue(), CONFIG);
    assert.equal(r.stage, "Ready to build");
    assert.equal(r.upstream, "Upstream issue linked");
  });

  test("with PRs, the issue reports the least advanced one", () => {
    const prs = [
      { number: 432, kind: "Fork PR", stage: "Owner approval", waitingOn: "Owner", next: ["a"], upstream: null, active: true },
      { number: 440, kind: "Pre-flight PR", stage: "Address draft feedback", waitingOn: "Author", next: ["b"], upstream: "Pre-flight open", active: true },
    ];
    const r = computeIssue(issue({ prs }), CONFIG);
    assert.equal(r.stage, "Address draft feedback");
    assert.equal(r.waitingOn, "Author");
    assert.equal(r.upstream, "Pre-flight open");
    assert.match(r.next[0], /#440/);
  });

  test("upstream-bound with no upstream issue: flagged", () => {
    const r = computeIssue(issue({ upstreamIssue: null }), CONFIG);
    assert.equal(r.upstream, "Needs upstream issue");
  });

  test("declared fork-only: no upstream expected", () => {
    const r = computeIssue(issue({ upstreamIssue: null, upstreamCandidate: false, upstreamDeclaredNone: true }), CONFIG);
    assert.equal(r.upstream, "Fork only");
  });

  test("an epic is not put through the stage machine", () => {
    const r = computeIssue(issue({ epic: true, hasTriagePlan: false, reviews: [] }), CONFIG);
    assert.equal(r.stage, null);
    assert.equal(r.waitingOn, null);
    assert.equal(r.upstream, null);
  });

  test("a closed issue is done", () => {
    assert.equal(computeIssue(issue({ state: "closed" }), CONFIG).stage, "Done");
  });
});

describe("gateConclusion", () => {
  test("success only once nothing is left for the author or a reviewer", () => {
    assert.equal(gateConclusion({ stage: "Mark ready", waitingOn: "Author" }), "success");
    assert.equal(gateConclusion({ stage: "Owner approval", waitingOn: "Owner" }), "success");
    assert.equal(gateConclusion({ stage: "Upstream PR", waitingOn: "Upstream" }), "success");
    assert.equal(gateConclusion({ stage: "Draft PR", waitingOn: "Gatekeeper" }), "neutral");
    assert.equal(gateConclusion({ stage: "Address draft feedback", waitingOn: "Author" }), "neutral");
  });
});

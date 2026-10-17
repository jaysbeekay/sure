import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { citedIds, decide, isQaReview, linkedIssues, rank, shouldMove, upstreamPr, verdict } from "../logic.mjs";

const REPO = "jaysbeekay/sure";
const CTX = {
  repo: REPO,
  upstreamRepo: "we-promise/sure",
  mirrorBase: "mirror/upstream-main",
  gatekeepers: ["sure-gatekeeper"],
};

// Text from real comments: #455 (issue review 6167015210 and its reply),
// #424 (the older bold-line review and a node-id reply), #451 (escaped emoji).
const QA_READY = "## 🔎 QA Review\n\n**Decision:** READY  ·  **Type:** DEFECT  ·  **Risk:** HIGH  ·  **Confidence:** HIGH";
const QA_NOT_READY = "## 🔎 QA Review\n\n**Decision:** NEEDS_CLARIFICATION  ·  **Type:** UNCLEAR";
const REPLY_QA = "Re QA review 6167015210 (READY). There are no material gaps, so the plan's fix and tests are unchanged.";

function comment(id, body, { login = "jaysbeekay", association = "OWNER", at = "2026-10-14T11:00:00Z", node_id } = {}) {
  return { id, node_id, body, user: { login }, author_association: association, created_at: at };
}

function commentEvent(c, { pr = false, number = 455 } = {}) {
  return { action: "created", issue: { number, ...(pr ? { pull_request: {} } : {}) }, comment: c };
}

function prEvent(action, { draft = true, base = "main", body = "Closes #424", number = 432, state = "open", association = "OWNER" } = {}) {
  return { action, pull_request: { number, draft, state, body, base: { ref: base }, author_association: association } };
}

describe("shouldMove: forward only", () => {
  test("moves forward from an earlier status", () => {
    assert.equal(shouldMove("Triage", "Issue review"), true);
  });

  test("never moves backward, so a card dragged further on stays put", () => {
    assert.equal(shouldMove("In review", "In progress"), false);
    assert.equal(shouldMove("Done", "In review"), false);
  });

  test("does not rewrite the same status", () => {
    assert.equal(shouldMove("In review", "In review"), false);
  });

  test("an empty or unknown current status always moves", () => {
    assert.equal(shouldMove(null, "Triage"), true);
    assert.equal(shouldMove("Todo", "In progress"), true);
  });

  test("a forced move goes backward too, but not to the same status", () => {
    assert.equal(shouldMove("Done", "In progress", { force: true }), true);
    assert.equal(shouldMove("In progress", "in progress", { force: true }), false);
  });

  test("status names match case-insensitively", () => {
    assert.equal(rank("in review"), rank("In review"));
  });
});

describe("parsers", () => {
  test("a QA review is recognised only from a Gatekeeper login", () => {
    assert.equal(isQaReview(comment(1, QA_READY, { login: "sure-gatekeeper" }), CTX.gatekeepers), true);
    assert.equal(isQaReview(comment(1, QA_READY, { login: "someone-else" }), CTX.gatekeepers), false);
  });

  test("a quoted or reply heading is not a review", () => {
    assert.equal(isQaReview(comment(1, `Re the review:\n> ${QA_READY}`, { login: "sure-gatekeeper" }), CTX.gatekeepers), false);
    assert.equal(isQaReview(comment(1, "## Re QA Review 6167015210", { login: "sure-gatekeeper" }), CTX.gatekeepers), false);
  });

  test("an escaped emoji heading is a review (#451)", () => {
    assert.equal(isQaReview(comment(1, "## \\u1F50E QA Review\n\n**Decision:** READY", { login: "sure-gatekeeper" }), CTX.gatekeepers), true);
  });

  test("reads the verdict in its bolded and plain forms", () => {
    assert.equal(verdict(QA_READY), "READY");
    assert.equal(verdict("## QA Review\n\nDecision: READY"), "READY");
    assert.equal(verdict("**Verdict: PASS** — the defect is real"), "PASS");
    assert.equal(verdict("the decision: we wait"), null);
  });

  test("finds numeric and node-id citations, not issue numbers", () => {
    assert.deepEqual([...citedIds(REPLY_QA)], ["6167015210"]);
    assert.deepEqual([...citedIds("Re QA review IC_kwDOUI0WXs8AAAABbO---Q (READY)")], ["IC_kwDOUI0WXs8AAAABbO---Q"]);
    assert.deepEqual([...citedIds("See #424 and we-promise/sure#4174")], []);
  });

  test("links fork issues by keyword only", () => {
    const body = "Closes #424\nPart of #118\nFork-main fix: #432\nFixes we-promise/sure#3383\nResolves https://github.com/jaysbeekay/sure/issues/455";
    assert.deepEqual(linkedIssues(body, REPO), [424, 118, 455]);
  });

  test("reads the upstream PR from its labelled line", () => {
    assert.equal(upstreamPr("Upstream draft PR: we-promise/sure#4174 ([pull/4174](https://github.com/we-promise/sure/pull/4174))", "we-promise/sure"), 4174);
    assert.equal(upstreamPr("Upstream PR: https://github.com/we-promise/sure/pull/4197", "we-promise/sure"), 4197);
    // bin/upstream-pr's fork template names the upstream issue, not a PR.
    assert.equal(upstreamPr("Fork pre-flight for the upstream PR (Fixes we-promise/sure#3295)", "we-promise/sure"), null);
  });
});

describe("decide: issue comments", () => {
  test("the owner's @codebot request moves the issue to Issue review", () => {
    assert.deepEqual(decide("issue_comment", commentEvent(comment(9, "@codebot please review the plan")), CTX), [{ number: 455, status: "Issue review" }]);
  });

  test("@codebot from anyone but the owner does nothing", () => {
    assert.deepEqual(decide("issue_comment", commentEvent(comment(9, "@codebot review", { association: "COLLABORATOR" })), CTX), []);
  });

  test("a landed QA review keeps or moves the issue at Issue review", () => {
    const e = commentEvent(comment(6167015210, QA_READY, { login: "sure-gatekeeper" }));
    assert.deepEqual(decide("issue_comment", e, CTX), [{ number: 455, status: "Issue review" }]);
  });

  test("a reply citing a READY review settles the plan", () => {
    const review = comment(6167015210, QA_READY, { login: "sure-gatekeeper", at: "2026-10-14T11:11:18Z" });
    const reply = comment(6168876231, REPLY_QA, { at: "2026-10-14T12:57:43Z" });
    assert.deepEqual(decide("issue_comment", commentEvent(reply), { ...CTX, comments: [review, reply] }), [{ number: 455, status: "Ready to build" }]);
  });

  test("a reply citing the review by node id settles it too (#424)", () => {
    const review = comment(6122618617, QA_READY, { login: "sure-gatekeeper", at: "2026-10-12T10:39:46Z", node_id: "IC_kwDOUI0WXs8AAAABbO---Q" });
    const reply = comment(6123390683, "Re QA review IC_kwDOUI0WXs8AAAABbO---Q (READY):", { at: "2026-10-12T11:30:58Z" });
    assert.deepEqual(decide("issue_comment", commentEvent(reply), { ...CTX, comments: [review, reply] }), [{ number: 455, status: "Ready to build" }]);
  });

  test("a reply to a not-ready review does not settle the plan", () => {
    const review = comment(6167015210, QA_NOT_READY, { login: "sure-gatekeeper", at: "2026-10-14T11:11:18Z" });
    const reply = comment(6168876231, REPLY_QA, { at: "2026-10-14T12:57:43Z" });
    assert.deepEqual(decide("issue_comment", commentEvent(reply), { ...CTX, comments: [review, reply] }), []);
  });

  test("a reply from someone outside the repository does not settle the plan", () => {
    const review = comment(6167015210, QA_READY, { login: "sure-gatekeeper", at: "2026-10-14T11:11:18Z" });
    const reply = comment(6168876231, REPLY_QA, { login: "drive-by", association: "NONE", at: "2026-10-14T12:57:43Z" });
    assert.deepEqual(decide("issue_comment", commentEvent(reply), { ...CTX, comments: [review, reply] }), []);
  });

  test("a citation written before the review does not settle it", () => {
    const review = comment(6167015210, QA_READY, { login: "sure-gatekeeper", at: "2026-10-14T13:00:00Z" });
    const reply = comment(6168876231, REPLY_QA, { at: "2026-10-14T12:57:43Z" });
    assert.deepEqual(decide("issue_comment", commentEvent(reply), { ...CTX, comments: [reply, review] }), []);
  });

  test("a QA heading from the old login is ignored once Gatekeeper has moved account", () => {
    const e = commentEvent(comment(6167015210, QA_READY, { login: "jaysbeekay" }));
    assert.deepEqual(decide("issue_comment", e, CTX), []);
  });

  test("comments on pull requests are left to the pull request events", () => {
    assert.deepEqual(decide("issue_comment", commentEvent(comment(9, "@codebot review"), { pr: true }), CTX), []);
  });
});

describe("decide: pull requests", () => {
  test("a draft moves itself and its issues to In progress, pre-flights included", () => {
    const e = prEvent("opened", { base: "mirror/upstream-main", body: "Closes #424", number: 440 });
    assert.deepEqual(decide("pull_request_target", e, CTX), [
      { number: 440, status: "In progress" },
      { number: 424, status: "In progress" },
    ]);
  });

  test("marked ready moves them to In review", () => {
    assert.deepEqual(decide("pull_request_target", prEvent("ready_for_review", { draft: false }), CTX), [
      { number: 432, status: "In review" },
      { number: 424, status: "In review" },
    ]);
  });

  test("a pre-flight that names its upstream PR moves to Upstream", () => {
    const body = "Closes #424\n\nUpstream draft PR: we-promise/sure#4174";
    const e = prEvent("edited", { draft: false, base: "mirror/upstream-main", body, number: 440 });
    assert.deepEqual(decide("pull_request_target", e, CTX), [
      { number: 440, status: "Upstream" },
      { number: 424, status: "Upstream" },
    ]);
  });

  test("an upstream PR line on a PR into main is not an upstream move", () => {
    const e = prEvent("edited", { draft: false, base: "main", body: "Closes #424\nUpstream PR: we-promise/sure#4174" });
    assert.equal(decide("pull_request_target", e, CTX)[0].status, "In review");
  });

  test("a PR from someone outside the repository moves only its own card", () => {
    for (const association of ["NONE", "FIRST_TIME_CONTRIBUTOR", "CONTRIBUTOR"]) {
      const e = prEvent("ready_for_review", { draft: false, body: "Closes #424\nPart of #118", association });
      assert.deepEqual(decide("pull_request_target", e, CTX), [{ number: 432, status: "In review" }], association);
    }
  });

  test("a collaborator's PR moves the issues it names", () => {
    const e = prEvent("opened", { body: "Closes #424", association: "COLLABORATOR" });
    assert.deepEqual(decide("pull_request_target", e, CTX), [
      { number: 432, status: "In progress" },
      { number: 424, status: "In progress" },
    ]);
  });

  test("closed PRs and other actions are left to the board's own workflows", () => {
    assert.deepEqual(decide("pull_request_target", prEvent("edited", { state: "closed" }), CTX), []);
    assert.deepEqual(decide("pull_request_target", prEvent("closed"), CTX), []);
    // The board's "Item reopened" workflow sets Triage; moving it on here would race it.
    assert.deepEqual(decide("pull_request_target", prEvent("reopened"), CTX), []);
    assert.deepEqual(decide("pull_request_target", prEvent("synchronize"), CTX), []);
  });
});

describe("decide: manual", () => {
  test("the manual workflow forces the status it is given", () => {
    assert.deepEqual(decide("workflow_dispatch", { inputs: { number: "424", status: "In review" } }, CTX), [
      { number: 424, status: "In review", force: true },
    ]);
  });

  test("without a number it does nothing", () => {
    assert.deepEqual(decide("workflow_dispatch", { inputs: { status: "Done" } }, CTX), []);
  });
});

// Comments and PR bodies are written by anyone on a public repository, and
// GitHub allows 65,536 characters. No pattern may backtrack into a stall.
describe("crafted input parses in linear time", () => {
  const within = (fn) => {
    const start = performance.now();
    fn();
    return performance.now() - start < 500;
  };

  test("a first line of 60,000 symbols or escapes", () => {
    for (const filler of ["!", "\\", "\\u", "\\u1F50E"]) {
      const body = `## ${filler.repeat(60000)} QB Review`;
      assert.ok(within(() => isQaReview(comment(1, body, { login: "sure-gatekeeper" }), CTX.gatekeepers)), filler);
    }
  });

  test("long PR bodies", () => {
    const body = "Closes jaysbeekay/sure# upstream PR we-promise/sure# ".repeat(2000);
    assert.ok(within(() => linkedIssues(body, REPO)));
    assert.ok(within(() => upstreamPr(body, "we-promise/sure")));
    assert.ok(within(() => citedIds(body)));
  });
});

describe("other repositories are not this one", () => {
  test("a keyword link to another repository is not a fork issue", () => {
    assert.deepEqual(linkedIssues("Closes other/sure#12\nFixes https://github.com/other/sure/issues/13", REPO), []);
  });

  test("repository names match case-insensitively", () => {
    assert.deepEqual(linkedIssues("Closes JaysBeeKay/Sure#12", REPO), [12]);
  });

  test("an upstream PR line naming another repository is not the upstream PR", () => {
    assert.equal(upstreamPr("Upstream PR: other/sure#4174", "we-promise/sure"), null);
  });
});

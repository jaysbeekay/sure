// Which project Status an event moves an issue or PR to. Pure: no network,
// so every rule is tested against real comment text (test/logic.test.mjs).
// See docs/project-status.md.

// The board's Status options, in the order work moves through them. Moves
// are forward-only, so a card someone has dragged further on stays there.
export const STATUSES = ["Triage", "Issue review", "Ready to build", "In progress", "In review", "Upstream", "Done"];

export function rank(status) {
  return STATUSES.findIndex((s) => s.toLowerCase() === String(status ?? "").toLowerCase());
}

// An empty or unrecognised current status always moves. A forced move (the
// manual workflow) sets the status whatever it was, backwards included.
export function shouldMove(current, target, { force = false } = {}) {
  if (!target) return false;
  if (force) return rank(current) !== rank(target);
  return rank(target) > rank(current);
}

// Gatekeeper's issue review. The heading must be the comment's first line, so
// a reply quoting it further down is not mistaken for one. The emoji may be
// posted as the character or as its escape text ("✅").
const QA_HEADING = /^#{1,3}\s*(?:(?:[^\w\s#*]|\\u[0-9a-fA-F]{4,6})+\s+)?QA Review\b/iu;

function firstLine(body) {
  return (body ?? "").replace(/^\s*(?:<!--[\s\S]*?-->\s*)*/, "").split("\n", 1)[0];
}

export function isQaReview(comment, gatekeepers) {
  return gatekeepers.includes(comment.user?.login) && QA_HEADING.test(firstLine(comment.body));
}

// "**Decision:** READY" and its variants. Upper case only, so prose such as
// "the decision: we wait" is not read as one.
export function verdict(body) {
  return (body ?? "").match(/(?:^|[^\w])(?:[Dd]ecision|[Vv]erdict)\*{0,2}[ \t]*:[ \t]*(?:\*{1,2}[ \t]*)?`?([A-Z][A-Z_]{2,})\b/)?.[1] ?? null;
}

// A reply names a review by its comment id (ten digits) or node id (IC_...).
export function citedIds(body) {
  const text = body ?? "";
  return new Set([
    ...[...text.matchAll(/(?<![\d#\w])(\d{8,12})(?!\d)/g)].map((m) => m[1]),
    ...[...text.matchAll(/\b(IC_[A-Za-z0-9_-]{10,})/g)].map((m) => m[1]),
  ]);
}

const TRUSTED = ["OWNER", "MEMBER", "COLLABORATOR"];

// The owner asking Gatekeeper for a review: the same test main.yml applies.
export function isCodebotRequest(comment) {
  return (comment.body ?? "").trimStart().startsWith("@codebot") && comment.author_association === "OWNER";
}

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&");
}

// Fork issues a PR answers: "Closes #N", "Fixes #N", "Resolves #N",
// "Part of #N". A bare mention ("Fork-main fix: #432") is not a link, and an
// upstream reference ("Fixes we-promise/sure#3383") is not a fork issue.
export function linkedIssues(body, repo) {
  const R = escapeRe(repo);
  const re = new RegExp(
    String.raw`\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|part of)\s+(?:https://github\.com/${R}/issues/|${R}#|#)(\d+)\b`,
    "gi",
  );
  return [...new Set([...(body ?? "").matchAll(re)].map((m) => Number(m[1])))];
}

// "Upstream PR: we-promise/sure#4174", or "Upstream draft PR:", or a link.
export function upstreamPr(body, upstreamRepo) {
  const U = escapeRe(upstreamRepo);
  const re = new RegExp(String.raw`upstream (?:draft )?(?:PR|pull request)\W{0,12}?(?:https://github\.com/${U}/pull/|${U}#)(\d+)`, "i");
  return Number((body ?? "").match(re)?.[1] ?? NaN) || null;
}

// The moves an event asks for, as [{ number, status, force }]. The caller
// still checks each item (open, not an epic) and its current status.
//
// ctx: { repo, upstreamRepo, mirrorBase, gatekeepers, comments }
//   comments: the issue's comments, oldest first, needed only when the event
//   is a comment that may be a reply to a review.
export function decide(eventName, event, ctx) {
  if (eventName === "workflow_dispatch") {
    const number = Number(event.inputs?.number);
    return number && event.inputs?.status ? [{ number, status: event.inputs.status, force: true }] : [];
  }

  if (eventName === "issue_comment") {
    if (event.action !== "created" || event.issue.pull_request) return [];
    const number = event.issue.number;
    const comment = event.comment;

    // The owner asked for the review, or the review has landed.
    if (isCodebotRequest(comment) || isQaReview(comment, ctx.gatekeepers)) return [{ number, status: "Issue review" }];

    // A reply that cites a READY review settles the plan.
    if (!TRUSTED.includes(comment.author_association)) return [];
    const cited = citedIds(comment.body);
    if (!cited.size) return [];
    const at = Date.parse(comment.created_at);
    const settles = (ctx.comments ?? []).some(
      (c) =>
        isQaReview(c, ctx.gatekeepers) &&
        Date.parse(c.created_at) < at &&
        (cited.has(String(c.id)) || (c.node_id && cited.has(c.node_id))) &&
        verdict(c.body) === "READY",
    );
    return settles ? [{ number, status: "Ready to build" }] : [];
  }

  if (eventName === "pull_request_target") {
    if (!["opened", "reopened", "edited", "ready_for_review"].includes(event.action)) return [];
    const pr = event.pull_request;
    if (pr.state !== "open") return [];

    let status = pr.draft ? "In progress" : "In review";
    // A pre-flight whose upstream PR is named has moved on to upstream.
    if (pr.base?.ref === ctx.mirrorBase && upstreamPr(pr.body, ctx.upstreamRepo)) status = "Upstream";

    return [{ number: pr.number, status }, ...linkedIssues(pr.body, ctx.repo).map((number) => ({ number, status }))];
  }

  return [];
}

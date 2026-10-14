// The stage machine. Pure: it takes facts gathered by sync.mjs and returns
// where an item stands, who acts next, and what they need to do.
//
// It encodes the owner's sequence (CLAUDE.md, "Issue and pull request
// sequence"), in particular rule 7: nothing is handed to the author until the
// review for the current step has landed AND every check has finished.

import { STAGES, UPSTREAM_ORDER } from "./config.mjs";
import { isPassing } from "./parse.mjs";

const STAGE_INDEX = new Map(STAGES.map((s, i) => [s.name, i]));

const UPSTREAM_BY_STATE = {
  draft: "Upstream draft",
  open: "Upstream ready",
  merged: "Landed upstream",
  closed: "Closed unmerged",
};

const REVIEW_LABEL = {
  issue: "Issue review",
  light: "Light review",
  full: "Full review",
  nightly: "Nightly review",
  sweep: "Daily sweep",
};

const REQUEST_REVIEW = "The owner can request it with an @codebot comment.";

function after(a, b) {
  return Date.parse(a) >= Date.parse(b ?? 0);
}

export function describeLatest(reviews) {
  const r = reviews.at(-1);
  if (!r) return "";
  const parts = [`${REVIEW_LABEL[r.kind] ?? r.kind}: ${r.verdict ?? "no verdict"}`];
  if (r.risk) parts.push(`Risk ${r.risk}`);
  if (r.head) parts.push(r.head.slice(0, 7));
  if (!r.answered) parts.push("unanswered");
  return parts.join(" · ");
}

function replyTo(r) {
  return `Reply to the ${(REVIEW_LABEL[r.kind] ?? r.kind).toLowerCase()} ${r.id}, citing its id (rule 9).`;
}

function ciWaiting(ci) {
  if (ci.state === "None") return ["No checks have reported on the head commit yet."];
  return [`Checks still running: ${ci.pending.join(", ")}.`];
}

function outstanding(f, unanswered) {
  const todo = unanswered.map(replyTo);
  if (f.ci.state === "Red") todo.push(`Fix the failing checks: ${f.ci.failing.join(", ")}.`);
  if (f.unresolvedThreads > 0) todo.push(`Resolve or answer ${f.unresolvedThreads} open review thread(s).`);
  return todo;
}

function ciUnfinished(ci) {
  return ci.state === "Pending" || ci.state === "None";
}

export function computePr(f, config) {
  const unanswered = f.reviews.filter((r) => !r.answered);
  const preflight = f.kind === "Pre-flight PR";
  const upstreamState = f.upstreamPr ? UPSTREAM_BY_STATE[f.upstreamPr.state] : null;
  const upstream = preflight ? (upstreamState ?? "Pre-flight open") : null;
  const base = { unanswered: unanswered.length, upstream, lastReview: describeLatest(f.reviews), active: true };
  const result = (stage, waitingOn, next) => ({ ...base, stage, waitingOn, next });
  const upstreamRef = f.upstreamPr ? `we-promise/sure#${f.upstreamPr.number}` : null;

  if (f.state === "closed") {
    // A pre-flight can be closed, or merged into the mirror, while its
    // upstream PR is still open: it is followed until upstream decides.
    if (preflight && f.upstreamPr && (f.upstreamPr.state === "draft" || f.upstreamPr.state === "open")) {
      return result("Upstream PR", "Upstream", [`${upstreamRef} is still open upstream.`]);
    }
    return { ...result("Done", "Nobody", []), active: false };
  }

  const todo = outstanding(f, unanswered);

  if (f.draft) {
    const light = f.reviews.filter((r) => r.kind === "light" && after(r.createdAt, f.createdAt));
    if (!light.length) return result("Draft PR", "Gatekeeper", [`The light Gatekeeper review has not landed. ${REQUEST_REVIEW}`]);
    if (ciUnfinished(f.ci)) return result("Draft PR", "CI", ciWaiting(f.ci));
    if (todo.length) return result("Address draft feedback", "Author", todo);
    return result("Mark ready", "Author", ["CI is green and every review is answered: mark the PR ready for review."]);
  }

  const readyAt = f.readyAt ?? f.createdAt;
  const full = f.reviews.filter((r) => r.kind === "full" && after(r.createdAt, readyAt));
  if (!full.length) return result("Full review", "Gatekeeper", [`The full Gatekeeper review has not landed since the PR went ready. ${REQUEST_REVIEW}`]);
  if (ciUnfinished(f.ci)) return result("Full review", "CI", ciWaiting(f.ci));
  if (config.coderabbitRequiredOnReady && f.coderabbit !== "reviewed") {
    const why =
      f.coderabbit === "skipped"
        ? "CodeRabbit does not review this repository automatically (under 10 stars): tick 'Trigger review' in its summary comment."
        : "CodeRabbit has not reviewed since the PR went ready.";
    return result("Full review", "CodeRabbit", [why]);
  }
  if (todo.length) return result("Address full review", "Author", todo);

  const latestFull = full.at(-1);
  if (!isPassing(latestFull)) {
    return result("Full review", "Gatekeeper", [
      `The full review's verdict is ${latestFull.verdict ?? "unreadable"} and it has been answered: request a re-review. ${REQUEST_REVIEW}`,
    ]);
  }

  if (!preflight) {
    const next = ["Merging needs the owner's approval in their own words (rule 7)."];
    if (f.kind === "Stacked PR") next.unshift(`Stacked on ${f.base ?? "another branch"}: it lands after its parent.`);
    return result("Owner approval", "Owner", next);
  }

  if (!f.upstreamIssue) {
    return result("Upstream PR", "Author", ["Link the upstream issue on the fork issue before the upstream PR is opened (rule 10)."]);
  }
  if (!f.upstreamPr) {
    return result("Upstream PR", "Author", [
      `Open the upstream draft: ../sure/bin/upstream-pr upstream --title "..." --fixes ${f.upstreamIssue}. Then add "Upstream PR: we-promise/sure#N" to this PR's body.`,
    ]);
  }
  if (f.upstreamPr.state === "unknown") {
    return result("Upstream PR", "Author", [`${upstreamRef} could not be read upstream: check the number in this PR's body.`]);
  }
  if (!f.upstreamPr.backlinked) {
    return result("Upstream PR", "Author", [`${upstreamRef} does not name #${f.number}: add the fork pre-flight link to its body (rule 8).`]);
  }
  switch (f.upstreamPr.state) {
    case "draft":
      return result("Upstream PR", "Author", [
        `${upstreamRef} is a draft: fill in demo data, screenshots and verification, then mark it ready (docs/llm-guides/upstream-delivery.md).`,
      ]);
    case "merged":
      return result("Upstream PR", "Author", [`${upstreamRef} landed upstream: close this pre-flight.`]);
    case "closed":
      return result("Upstream PR", "Owner", [`${upstreamRef} was closed unmerged upstream: decide what happens to this pre-flight.`]);
    default:
      return result("Upstream PR", "Upstream", [`${upstreamRef} is open upstream, waiting on its maintainers.`]);
  }
}

function issueUpstream(f) {
  const pre = f.prs.filter((p) => p.kind === "Pre-flight PR" && p.upstream);
  const rank = (p) => UPSTREAM_ORDER.indexOf(p.upstream);
  const activePre = pre.filter((p) => p.active).sort((a, b) => rank(a) - rank(b));
  if (activePre.length) return activePre[0].upstream;
  if (pre.length) return [...pre].sort((a, b) => rank(b) - rank(a))[0].upstream;
  if (f.upstreamIssue && !f.upstreamIssue.isPr) return "Upstream issue linked";
  if (f.upstreamCandidate) return "Needs upstream issue";
  return "Fork only";
}

export function computeIssue(f, config) {
  void config;
  const unanswered = f.reviews.filter((r) => !r.answered);
  const base = { unanswered: unanswered.length, upstream: issueUpstream(f), lastReview: describeLatest(f.reviews), active: f.state !== "closed" };
  const result = (stage, waitingOn, next) => ({ ...base, stage, waitingOn, next });

  if (f.epic) return { ...result(f.state === "closed" ? "Done" : null, null, ["An epic: its progress comes from its sub-issues."]), upstream: null };
  if (f.state === "closed") return result("Done", "Nobody", []);
  if (!f.hasTriagePlan) return result("Triage plan", "Author", ["Add the '## Triage Plan' section to the issue body (step 1)."]);
  if (f.upstreamIssue?.isPr) {
    return result("Triage plan", "Author", [`we-promise/sure#${f.upstreamIssue.number} is a pull request, not an issue: link the upstream issue (rule 8).`]);
  }

  const qa = f.reviews.filter((r) => r.kind === "issue");
  if (!qa.length) return result("Issue review", "Gatekeeper", [`The issue Gatekeeper review has not landed. ${REQUEST_REVIEW}`]);
  if (unanswered.length) return result("Address issue review", "Author", unanswered.map(replyTo));

  const latest = qa.at(-1);
  if (!isPassing(latest)) {
    return result("Issue review", "Gatekeeper", [
      `Decision ${latest.verdict ?? "unreadable"} has been answered: revise the plan in the body, then request a re-review. ${REQUEST_REVIEW}`,
    ]);
  }

  const active = f.prs.filter((p) => p.active).sort((a, b) => STAGE_INDEX.get(a.stage) - STAGE_INDEX.get(b.stage));
  if (!active.length) {
    if (f.prs.length) return result("Owner approval", "Owner", ["Every linked PR is finished: close the issue, or open the next PR."]);
    return result("Ready to build", "Author", [`Plan settled: open the draft PR with "Closes #${f.number}" or "Part of #${f.number}" in its body.`]);
  }

  const lead = active[0];
  return result(
    lead.stage,
    lead.waitingOn,
    active.flatMap((p) => p.next.map((s) => `#${p.number}: ${s}`)),
  );
}

// The gate check never fails a PR: it is neutral while a review, CI or the
// author still owes something, and success once the PR can move on.
export function gateConclusion({ stage }) {
  return ["Mark ready", "Upstream PR", "Owner approval", "Done"].includes(stage) ? "success" : "neutral";
}

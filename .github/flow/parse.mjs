// Pure parsers over GitHub data. No network access here, so every rule the
// flow depends on can be tested against real comment text (test/fixtures.mjs).

// --- Reviews ---------------------------------------------------------------

// A review is recognised by its first line, so a reply that quotes a heading
// further down is never mistaken for one. The patterns cover every format
// Gatekeeper and the nightly job have used on items #300-#455.
// An emoji before the title, as a character or, as Hermes sometimes posts it,
// as escape text ("\u2705", #451). Words are not allowed, so a reply headed
// "## Re QA Review" is never read as a review.
const EMOJI = String.raw`(?:[^\w\s#*]|\\u[0-9a-fA-F]{4,6})+\s+`;
const headingRe = (title) => new RegExp(String.raw`^#{1,3}\s*(?:${EMOJI})?${title}`, "iu");

const REVIEW_HEADINGS = [
  ["issue", headingRe(String.raw`QA Review\b`)],
  ["issue", /^\*\*QA (?:re-?)?review\b/iu],
  ["light", headingRe(String.raw`PR Review\s*[-–—:]\s*Light\b`)],
  ["full", headingRe(String.raw`PR Review\s*[-–—:]\s*Full\b`)],
  ["nightly", /^#{1,3}\s*NIGHTLY REVIEW\b/iu],
  ["sweep", /^#{1,3}\s*(?:PR DAILY SWEEP|DAILY PR SWEEP)\b/iu],
];

// "(1/2)", "(part 2 of 4)", "(continued)": one review split over comments.
// Returns the part's position, or null for a review in one comment. Only a
// later part (2 and on) joins the review before it: a "part 1" always starts
// a new one, such as a forced re-review.
function partIndex(firstLine) {
  const paren = firstLine.match(/\(([^)]*)\)/)?.[1] ?? "";
  if (/\bcontinued\b/i.test(paren)) return 2;
  const n = paren.match(/\bpart\s*(\d+)\s*of\s*\d+/i)?.[1] ?? paren.match(/(?:^|\D)(\d+)\s*\/\s*\d+/)?.[1];
  return n ? Number(n) : null;
}

// Optional and forward-compatible: a reviewer can state its result exactly,
// e.g. <!-- flow-review kind=full verdict=APPROVE head=3b26ce7 -->, and the
// headings are then not read at all.
const MARKER = /<!--\s*flow-review\b([^>]*?)-->/;

// Verdicts seen: issue READY / NEEDS_CLARIFICATION (older: PASS, APPROVED);
// light DRAFT_ON_TRACK / DRAFT_CONCERNS; full APPROVE / CHANGES_REQUESTED /
// WAITING_FOR_CHECKS / NEEDS_CLARIFICATION; nightly READY TO MERGE / READY WITH
// CONDITIONS / NOT READY TO MERGE / INSUFFICIENT EVIDENCE.
const PASSING = {
  issue: /^(?:READY|PASS|APPROVED?)$/,
  light: /ON_TRACK|APPROVE|READY/,
  full: /^APPROVED?$/,
  nightly: /^READY/,
};

function firstLineOf(text) {
  return text.replace(/^\s*(?:<!--[\s\S]*?-->\s*)*/, "").split("\n", 1)[0];
}

export function classifyReview(body) {
  const text = body ?? "";

  const marker = text.match(MARKER);
  if (marker) {
    const attrs = Object.fromEntries([...marker[1].matchAll(/(\w+)=("[^"]*"|\S+)/g)].map(([, k, v]) => [k, v.replace(/^"|"$/g, "")]));
    if (attrs.kind) {
      return { kind: attrs.kind, verdict: attrs.verdict ?? null, risk: attrs.risk ?? null, head: attrs.head ?? null };
    }
  }

  const firstLine = firstLineOf(text);
  const heading = REVIEW_HEADINGS.find(([, re]) => re.test(firstLine));
  if (!heading) return null;
  const kind = heading[0];

  // "**Verdict:** APPROVE", "Decision: READY", "**Verdict: PASS**", and the
  // older "**QA review — #424 — READY**" first line. Upper case only, so prose
  // such as "the verdict: the plan is sound" is never read as one.
  let verdict =
    text.match(/(?:^|[^\w])(?:[Dd]ecision|[Vv]erdict)\*{0,2}[ \t]*:[ \t]*(?:\*{1,2}[ \t]*)?`?([A-Z][A-Z_]{2,})\b/)?.[1] ??
    firstLine.match(/—\s*\*{0,2}([A-Z][A-Z_]{2,})\*{0,2}\s*(?:\(|$)/)?.[1] ??
    null;
  if (kind === "nightly") {
    verdict = text.match(/Production Readiness[ \t]*\n+[ \t]*(?:[^\sA-Za-z0-9]+[ \t]*)?([A-Z][A-Z _]*[A-Z])/u)?.[1] ?? null;
  }

  return {
    kind,
    verdict,
    risk: text.match(/\*\*Risk:\*\*\s*([A-Z]+)/)?.[1] ?? null,
    head: text.match(/Reviewed (?:HEAD|commit)\W*?([0-9a-f]{7,40})\b/i)?.[1] ?? null,
  };
}

export function isPassing(review) {
  const re = PASSING[review.kind];
  if (!re) return true;
  return re.test(review.verdict ?? "");
}

// Replies cite a review by its numeric id (ten digits today; issue and PR
// numbers and short shas never reach eight) or by its node id (IC_...).
export function citedIds(body) {
  const text = body ?? "";
  return new Set([
    ...[...text.matchAll(/(?<![\d#\w])(\d{8,12})(?!\d)/g)].map((m) => m[1]),
    ...[...text.matchAll(/\b(IC_[A-Za-z0-9_-]{10,})/g)].map((m) => m[1]),
  ]);
}

function isTrusted(c, config) {
  return config.reviewerLogins.includes(c.user?.login) || config.trustedAssociations.includes(c.author_association);
}

function byTime(a, b) {
  return Date.parse(a.created_at) - Date.parse(b.created_at) || a.id - b.id;
}

// Every review on an item, in order, each marked answered when a later
// trusted comment that is not itself a review cites it (CLAUDE.md rule 9).
// A review posted in parts is one review: its verdict is whichever part
// carries one, and citing any part answers it.
export function extractReviews(comments, config) {
  const sorted = [...comments].sort(byTime);
  const classified = sorted.map((c) => ({ c, review: config.reviewerLogins.includes(c.user?.login) ? classifyReview(c.body) : null }));
  const replies = classified.filter(({ c, review }) => !review && isTrusted(c, config)).map(({ c }) => ({ at: Date.parse(c.created_at), cited: citedIds(c.body) }));

  const reviews = [];
  for (const { c, review } of classified) {
    if (!review) continue;
    const prior = reviews.at(-1);
    const part = partIndex(firstLineOf(c.body));
    if (part > 1 && prior?.kind === review.kind && !(prior.verdict && review.verdict)) {
      prior.keys.push(String(c.id), c.node_id);
      prior.verdict ??= review.verdict;
      prior.risk ??= review.risk;
      prior.head ??= review.head;
      continue;
    }
    reviews.push({ id: c.id, url: c.html_url, createdAt: c.created_at, ...review, keys: [String(c.id), c.node_id] });
  }

  return reviews.map(({ keys, ...r }) => {
    const at = Date.parse(r.createdAt);
    const answered = replies.some((reply) => reply.at > at && keys.some((k) => k && reply.cited.has(k)));
    return { ...r, answered, passing: isPassing(r) };
  });
}

// --- Links -----------------------------------------------------------------

const KEYWORD = String.raw`(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|part of)`;

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&");
}

function unique(numbers) {
  return [...new Set(numbers)];
}

// What a body links to. A fork issue counts only behind a closing keyword or
// "Part of" (CLAUDE.md rule 10), never as a bare mention: "Fork-main fix: #432"
// names a PR, not the issue being answered. Upstream references are read from
// labelled lines ("Upstream issue:", "Upstream PR:") because a bare
// we-promise/sure#N can be an issue or a PR (rule 8).
export function parseLinks(body, repo, upstreamRepo) {
  const text = body ?? "";
  const R = escapeRe(repo);
  const U = escapeRe(upstreamRepo);

  const forkRe = new RegExp(String.raw`\b${KEYWORD}\s+(?:https://github\.com/${R}/issues/|${R}#|#)(\d+)\b`, "gi");
  const forkIssues = unique([...text.matchAll(forkRe)].map((m) => Number(m[1])));

  const upstreamIssueLabelled = new RegExp(String.raw`upstream issue\W{0,12}?(?:https://github\.com/${U}/issues/|${U}#)(\d+)`, "i");
  const upstreamIssueKeyword = new RegExp(String.raw`\b${KEYWORD}\s+(?:https://github\.com/${U}/issues/|${U}#)(\d+)`, "i");
  const upstreamIssue = Number(text.match(upstreamIssueLabelled)?.[1] ?? text.match(upstreamIssueKeyword)?.[1] ?? NaN) || null;

  const upstreamPrLabelled = new RegExp(String.raw`upstream (?:draft )?(?:PR|pull request)\W{0,12}?(?:https://github\.com/${U}/pull/|${U}#)(\d+)`, "i");
  const upstreamPr = Number(text.match(upstreamPrLabelled)?.[1] ?? NaN) || null;

  // No two quantifiers here can match the same characters: overlapping ones
  // (as in \s*\n+\s*) backtrack polynomially on a run of blank lines.
  const upstreamDeclaredNone = /^#{2,3}[ \t]*Upstream issue[ \t]*\r?\n(?:[ \t]*\r?\n)*[ \t]*(?:none|n\/a|no|-)[ \t]*\r?$/im.test(text);

  return { forkIssues, upstreamIssue, upstreamDeclaredNone, upstreamPr };
}

// Does a body name this pull request? Used to check that an upstream PR links
// back to its fork pre-flight. The number must be the PR's (rule 8): a link to
// the fork's issue of the same repository does not count.
export function namesPullRequest(body, repo, number) {
  const R = escapeRe(repo);
  return new RegExp(String.raw`(?:${R}#|github\.com/${R}/pull/)${number}(?!\d)`).test(body ?? "");
}

// --- Issue body ------------------------------------------------------------

export function triagePlanPresent(body) {
  const text = body ?? "";
  const heading = text.match(/^(#{2,3})[ \t]*Triage Plan\b.*$/im);
  if (!heading) return false;

  const level = heading[1].length;
  const rest = text.slice(heading.index + heading[0].length);
  const end = rest.search(new RegExp(String.raw`^#{1,${level}}\s`, "m"));
  const section = (end === -1 ? rest : rest.slice(0, end)).replace(/_No response_/g, "").replace(/\s+/g, " ").trim();
  return section.length >= 40;
}

// --- Pull requests ---------------------------------------------------------

export function prKind(pr, config) {
  const base = pr.base?.ref;
  if (base === config.mirrorBase) return "Pre-flight PR";
  if (base === config.defaultBase) return "Fork PR";
  return "Stacked PR";
}

const RED_CONCLUSIONS = new Set(["failure", "timed_out", "cancelled", "startup_failure", "stale"]);

// CI over the head commit's check runs and commit statuses. The gate's own
// check and CodeRabbit are left out: CodeRabbit is waited on separately, and
// only once a PR is ready.
export function summariseChecks({ checkRuns, statuses, gateCheckName = "Flow gate" }) {
  const isCodeRabbit = (name, slug) => /coderabbit/i.test(name ?? "") || /coderabbit/i.test(slug ?? "");

  const latest = new Map();
  for (const run of checkRuns) {
    if (run.name === gateCheckName || isCodeRabbit(run.name, run.app?.slug)) continue;
    const prior = latest.get(run.name);
    const key = (r) => [Date.parse(r.started_at ?? 0) || 0, r.id ?? 0];
    if (!prior || key(run)[0] > key(prior)[0] || (key(run)[0] === key(prior)[0] && key(run)[1] > key(prior)[1])) {
      latest.set(run.name, run);
    }
  }

  const failing = [];
  const pending = [];
  for (const run of latest.values()) {
    if (run.status !== "completed" || run.conclusion === "action_required") pending.push(run.name);
    else if (RED_CONCLUSIONS.has(run.conclusion)) failing.push(run.name);
  }
  for (const s of statuses) {
    if (isCodeRabbit(s.context)) continue;
    if (s.state === "pending") pending.push(s.context);
    else if (s.state === "failure" || s.state === "error") failing.push(s.context);
  }

  const total = latest.size + statuses.filter((s) => !isCodeRabbit(s.context)).length;
  let state = "Green";
  if (total === 0) state = "None";
  else if (failing.length) state = "Red";
  else if (pending.length) state = "Pending";
  return { state, failing, pending };
}

export function coderabbitState({ reviews, comments, readyAt, login }) {
  const since = Date.parse(readyAt ?? 0) || 0;
  const after = (t) => Date.parse(t ?? 0) >= since;
  const own = (x) => x.user?.login === login;

  if (reviews.some((r) => own(r) && after(r.submitted_at))) return "reviewed";
  if (comments.some((c) => own(c) && after(c.updated_at ?? c.created_at) && /Actionable comments posted|No actionable comments/i.test(c.body ?? ""))) {
    return "reviewed";
  }
  if (comments.some((c) => own(c) && /does not receive automatic reviews/i.test(c.body ?? ""))) return "skipped";
  return "missing";
}

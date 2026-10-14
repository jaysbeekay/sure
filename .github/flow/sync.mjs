#!/usr/bin/env node
// Sync the delivery flow for the items an event touched, or for every tracked
// item. See docs/flow/README.md.
//
// It only reads the repository, plus we-promise/sure, which is public. It writes
// exactly two things: project field values (PROJECT_TOKEN) and the "Flow gate"
// check run on a PR's head commit (the Actions token). It never comments,
// labels or pushes, so it cannot set off Gatekeeper (.github/workflows/main.yml)
// or any other workflow.
//
// Local use, read-only:
//   GH_TOKEN=... node .github/flow/sync.mjs --issue 424 --dry-run --ignore-opt-in

import fs from "node:fs";

import { CONFIG, FIELDS } from "./config.mjs";
import { createClient } from "./github.mjs";
import {
  coderabbitState,
  extractReviews,
  namesPullRequest,
  parseLinks,
  prKind,
  summariseChecks,
  triagePlanPresent,
} from "./parse.mjs";
import { addItem, loadItem, loadProject, writeFields } from "./project.mjs";
import { computeIssue, computePr, gateConclusion } from "./stage.mjs";

const env = process.env;
const argv = process.argv.slice(2);
const flag = (name) => argv.includes(name);
const option = (name) => {
  const i = argv.indexOf(name);
  return i === -1 ? null : argv[i + 1];
};

const repoFull = env.GITHUB_REPOSITORY || "jaysbeekay/sure";
const [owner] = repoFull.split("/");
const R = `/repos/${repoFull}`;
const U = `/repos/${CONFIG.upstreamRepo}`;

const inActions = env.GITHUB_ACTIONS === "true";
const dryRun = flag("--dry-run") || env.FLOW_DRY_RUN === "1";
const ignoreOptIn = flag("--ignore-opt-in");
const projectNumber = Number(env.FLOW_PROJECT_NUMBER) || null;
const configured = Boolean(env.PROJECT_TOKEN && projectNumber);

// Reads go through the project token when there is one: it carries the user's
// 5,000-an-hour allowance rather than the Actions token's 1,000.
const read = createClient(env.PROJECT_TOKEN || env.GITHUB_TOKEN || env.GH_TOKEN || null);
const projectClient = env.PROJECT_TOKEN ? createClient(env.PROJECT_TOKEN) : null;
const checksClient = inActions && env.GITHUB_TOKEN ? createClient(env.GITHUB_TOKEN) : null;

function log(line) {
  console.log(line);
}

// --- Gathering facts -------------------------------------------------------

const cache = { issues: new Map(), prs: new Map(), upstreamPrs: new Map(), upstreamIssues: new Map() };

async function getIssue(number) {
  if (!cache.issues.has(number)) cache.issues.set(number, await read.rest("GET", `${R}/issues/${number}`));
  return cache.issues.get(number);
}

async function getPr(number) {
  if (!cache.prs.has(number)) cache.prs.set(number, await read.rest("GET", `${R}/pulls/${number}`));
  return cache.prs.get(number);
}

function isEpic(issue) {
  return (issue.labels ?? []).some((l) => (l.name ?? l) === CONFIG.epicLabel);
}

function tracked(issueOrPr) {
  return ignoreOptIn || (issueOrPr.labels ?? []).some((l) => (l.name ?? l) === CONFIG.optInLabel);
}

async function upstreamIssue(number) {
  if (!cache.upstreamIssues.has(number)) {
    try {
      const i = await read.rest("GET", `${U}/issues/${number}`);
      cache.upstreamIssues.set(number, { number, isPr: Boolean(i.pull_request), state: i.state });
    } catch (error) {
      log(`  ! we-promise/sure#${number}: ${error.message}`);
      cache.upstreamIssues.set(number, { number, isPr: false, state: "unknown" });
    }
  }
  return cache.upstreamIssues.get(number);
}

async function upstreamPr(number, preflightNumber) {
  const key = `${number}:${preflightNumber}`;
  if (!cache.upstreamPrs.has(key)) {
    try {
      const p = await read.rest("GET", `${U}/pulls/${number}`);
      const state = p.merged_at ? "merged" : p.state === "closed" ? "closed" : p.draft ? "draft" : "open";
      cache.upstreamPrs.set(key, { number, state, backlinked: namesPullRequest(p.body, repoFull, preflightNumber) });
    } catch (error) {
      log(`  ! we-promise/sure#${number}: ${error.message}`);
      cache.upstreamPrs.set(key, { number, state: "unknown", backlinked: false });
    }
  }
  return cache.upstreamPrs.get(key);
}

// PRs in this repository whose body links the issue. The timeline's
// cross-references find pre-flights too, which GitHub's own "linked pull
// requests" leaves out because they do not target the default branch.
async function linkedPrNumbers(issueNumber) {
  const timeline = await read.paginate(`${R}/issues/${issueNumber}/timeline`);
  const candidates = new Set(
    timeline
      .filter((e) => e.event === "cross-referenced" && e.source?.issue?.pull_request && e.source.issue.repository?.full_name === repoFull)
      .map((e) => e.source.issue.number),
  );
  const linked = [];
  for (const n of candidates) {
    const pr = await getPr(n);
    if (parseLinks(pr.body, repoFull, CONFIG.upstreamRepo).forkIssues.includes(issueNumber)) linked.push(n);
  }
  return linked.sort((a, b) => a - b);
}

// A closed PR needs only its links: the stage machine reads nothing else for
// it, and a long-lived issue can name many closed PRs.
async function closedPrFacts(pr, context) {
  const links = parseLinks(pr.body, repoFull, CONFIG.upstreamRepo);
  const kind = prKind(pr, CONFIG);
  return {
    number: pr.number,
    state: "closed",
    merged: Boolean(pr.merged_at),
    draft: pr.draft,
    kind,
    base: pr.base.ref,
    head: pr.head.sha,
    createdAt: pr.created_at,
    readyAt: null,
    reviews: [],
    ci: { state: "None", failing: [], pending: [] },
    unresolvedThreads: 0,
    coderabbit: "missing",
    upstreamIssue: links.upstreamIssue ?? context.upstreamIssue ?? null,
    upstreamPr: kind === "Pre-flight PR" && links.upstreamPr ? await upstreamPr(links.upstreamPr, pr.number) : null,
    forkIssues: links.forkIssues,
    url: pr.html_url,
    nodeId: pr.node_id,
  };
}

async function prFacts(number, context = {}) {
  const pr = await getPr(number);
  if (pr.state === "closed") return closedPrFacts(pr, context);
  const sha = pr.head.sha;
  const [comments, reviews, events, checkRuns, status, threads] = await Promise.all([
    read.paginate(`${R}/issues/${number}/comments`),
    read.paginate(`${R}/pulls/${number}/reviews`),
    read.paginate(`${R}/issues/${number}/events`),
    read.paginate(`${R}/commits/${sha}/check-runs`),
    read.rest("GET", `${R}/commits/${sha}/status`),
    // Review threads are GraphQL-only. A failure here is reported as
    // "unknown" rather than failing the sync.
    read
      .graphql(
        `query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) { pullRequest(number: $number) { reviewThreads(first: 100) { nodes { isResolved } } } }
        }`,
        { owner, name: repoFull.split("/")[1], number },
      )
      .catch((error) => {
        log(`  ! PR #${number} review threads: ${error.message.slice(0, 120)}`);
        return null;
      }),
  ]);

  const links = parseLinks(pr.body, repoFull, CONFIG.upstreamRepo);
  const readyAt = events.filter((e) => e.event === "ready_for_review").at(-1)?.created_at ?? null;
  const kind = prKind(pr, CONFIG);

  const facts = {
    number,
    state: pr.state,
    merged: Boolean(pr.merged_at),
    draft: pr.draft,
    kind,
    base: pr.base.ref,
    head: sha,
    createdAt: pr.created_at,
    readyAt,
    reviews: extractReviews(comments, CONFIG),
    ci: summariseChecks({ checkRuns, statuses: status.statuses ?? [], gateCheckName: CONFIG.gateCheckName }),
    unresolvedThreads: threads ? threads.repository.pullRequest.reviewThreads.nodes.filter((t) => !t.isResolved).length : null,
    coderabbit: coderabbitState({ reviews, comments, readyAt: readyAt ?? pr.created_at, login: CONFIG.coderabbitLogin }),
    upstreamIssue: links.upstreamIssue ?? context.upstreamIssue ?? null,
    upstreamPr: kind === "Pre-flight PR" && links.upstreamPr ? await upstreamPr(links.upstreamPr, number) : null,
    forkIssues: links.forkIssues,
    url: pr.html_url,
    nodeId: pr.node_id,
  };
  return facts;
}

// --- Writing ---------------------------------------------------------------

let project = null;

async function ensureProject() {
  if (!configured) return null;
  if (!project) {
    project = await loadProject(projectClient, owner, projectNumber);
    if (!project) throw new Error(`No project #${projectNumber} owned by ${owner}. Check vars.FLOW_PROJECT_NUMBER.`);
  }
  return project;
}

// A finished item is updated if it is already on the project, but never added:
// migrating an issue should not fill the project with its closed PRs.
async function writeItem(nodeId, values, label, { addIfMissing = true } = {}) {
  const p = await ensureProject();
  if (!p) return;
  let item = await loadItem(projectClient, p, nodeId);
  if (!item && !addIfMissing) return;
  if (!item) {
    if (dryRun) {
      log(`  ${label}: would add to the project`);
      item = { itemId: null, values: new Map() };
    } else {
      item = await addItem(projectClient, p, nodeId);
    }
  }
  const changed = await writeFields(projectClient, p, item, values, { dryRun, log });
  if (changed.length) log(`  ${label}: ${dryRun ? "would set" : "set"} ${changed.join(", ")}`);
}

function gateSummary(facts, result) {
  const lines = [
    `| | |`,
    `|---|---|`,
    `| Stage | ${result.stage} |`,
    `| Waiting on | ${result.waitingOn} |`,
    `| CI | ${facts.ci.state}${facts.ci.failing.length ? ` (failing: ${facts.ci.failing.join(", ")})` : ""}${facts.ci.pending.length ? ` (running: ${facts.ci.pending.join(", ")})` : ""} |`,
    `| CodeRabbit | ${facts.draft ? "not expected on a draft" : facts.coderabbit} |`,
    `| Open review threads | ${facts.unresolvedThreads ?? "unknown (could not be read)"} |`,
  ];
  if (result.upstream) lines.push(`| Upstream | ${result.upstream}${facts.upstreamPr ? ` (we-promise/sure#${facts.upstreamPr.number})` : ""} |`);
  lines.push("", "**Reviews**", "");
  if (!facts.reviews.length) lines.push("None yet.");
  for (const r of facts.reviews) {
    lines.push(`- [${r.kind} ${r.id}](${r.url}): ${r.verdict ?? "no verdict"}${r.risk ? `, risk ${r.risk}` : ""}. ${r.answered ? "Answered." : "**Not answered.**"}`);
  }
  lines.push("", "**Next**", "", ...(result.next.length ? result.next.map((s) => `- ${s}`) : ["Nothing."]));
  lines.push("", "_Computed by `.github/flow` (docs/flow/README.md). This check is never a failure and never blocks a merge._");
  return lines.join("\n");
}

async function writeGate(facts, result) {
  if (!checksClient || !configured || facts.state !== "open") return;
  const conclusion = gateConclusion(result);
  const output = { title: `${result.stage}: waiting on ${result.waitingOn}`, summary: gateSummary(facts, result) };
  if (dryRun) {
    log(`  #${facts.number}: would write ${CONFIG.gateCheckName} ${conclusion}`);
    return;
  }
  const existing = await checksClient.rest(
    "GET",
    `${R}/commits/${facts.head}/check-runs?check_name=${encodeURIComponent(CONFIG.gateCheckName)}&filter=latest`,
  );
  const mine = existing.check_runs.find((c) => c.app?.slug === "github-actions");
  if (mine) {
    await checksClient.rest("PATCH", `${R}/check-runs/${mine.id}`, { status: "completed", conclusion, output });
  } else {
    await checksClient.rest("POST", `${R}/check-runs`, {
      name: CONFIG.gateCheckName,
      head_sha: facts.head,
      status: "completed",
      conclusion,
      output,
    });
  }
}

function prValues(facts, result) {
  return {
    [FIELDS.stage.name]: result.stage,
    [FIELDS.waitingOn.name]: result.waitingOn,
    [FIELDS.upstream.name]: result.upstream,
    [FIELDS.ci.name]: facts.state === "open" ? facts.ci.state : null,
    [FIELDS.kind.name]: facts.kind,
    [FIELDS.unanswered.name]: result.unanswered,
    [FIELDS.nextStep.name]: result.next.join(" · "),
    [FIELDS.lastReview.name]: result.lastReview,
    [FIELDS.forkIssue.name]: facts.forkIssues.map((n) => `#${n}`).join(", "),
    [FIELDS.upstreamIssue.name]: facts.upstreamIssue ? `we-promise/sure#${facts.upstreamIssue}` : null,
    [FIELDS.upstreamPr.name]: facts.upstreamPr ? `we-promise/sure#${facts.upstreamPr.number} (${facts.upstreamPr.state})` : null,
  };
}

// --- Syncing ---------------------------------------------------------------

const done = { issues: new Set(), prs: new Map() };
const report = [];

async function syncPr(number, context) {
  if (done.prs.has(number)) return done.prs.get(number);
  const facts = await prFacts(number, context);
  const result = { number, kind: facts.kind, ...computePr(facts, CONFIG) };
  done.prs.set(number, result);

  log(`PR #${number} [${facts.kind}] ${result.stage} | waiting on ${result.waitingOn}${result.next[0] ? ` | ${result.next[0]}` : ""}`);
  report.push({ type: "pr", number, ...result, facts: { ci: facts.ci, coderabbit: facts.coderabbit, unresolvedThreads: facts.unresolvedThreads } });

  await writeItem(facts.nodeId, prValues(facts, result), `PR #${number}`, { addIfMissing: result.active });
  await writeGate(facts, result);
  return result;
}

async function syncIssue(number) {
  if (done.issues.has(number)) return;
  done.issues.add(number);

  const issue = await getIssue(number);
  if (issue.pull_request) return;
  if (!tracked(issue)) {
    log(`Issue #${number}: not labelled ${CONFIG.optInLabel}, skipped`);
    return;
  }

  const links = parseLinks(issue.body, repoFull, CONFIG.upstreamRepo);
  const epic = isEpic(issue);
  // An epic's PRs are synced through their own issues, or on their own: its
  // timeline can hold hundreds of cross-references.
  const [comments, prNumbers, upstream] = await Promise.all([
    read.paginate(`${R}/issues/${number}/comments`),
    epic ? [] : linkedPrNumbers(number),
    links.upstreamIssue ? upstreamIssue(links.upstreamIssue) : null,
  ]);

  const prs = [];
  for (const n of prNumbers) prs.push(await syncPr(n, { upstreamIssue: links.upstreamIssue }));

  const facts = {
    number,
    state: issue.state,
    hasTriagePlan: triagePlanPresent(issue.body),
    upstreamIssue: upstream,
    upstreamDeclaredNone: links.upstreamDeclaredNone,
    upstreamCandidate: issue.labels.some((l) => l.name === "upstream:candidate"),
    epic,
    reviews: extractReviews(comments, CONFIG),
    prs,
  };
  const result = computeIssue(facts, CONFIG);

  log(`Issue #${number} ${result.stage ?? "(epic)"} | waiting on ${result.waitingOn ?? "-"}${result.next[0] ? ` | ${result.next[0]}` : ""}`);
  report.push({ type: "issue", number, ...result, prs: prNumbers });

  await writeItem(issue.node_id, {
    [FIELDS.stage.name]: result.stage,
    [FIELDS.waitingOn.name]: result.waitingOn,
    [FIELDS.upstream.name]: result.upstream,
    [FIELDS.ci.name]: null,
    [FIELDS.kind.name]: facts.epic ? "Epic" : "Issue",
    [FIELDS.unanswered.name]: result.unanswered,
    [FIELDS.nextStep.name]: result.next.join(" · "),
    [FIELDS.lastReview.name]: result.lastReview,
    [FIELDS.forkIssue.name]: null,
    [FIELDS.upstreamIssue.name]: upstream ? `we-promise/sure#${upstream.number}` : null,
    [FIELDS.upstreamPr.name]: null,
  }, `Issue #${number}`, { addIfMissing: issue.state === "open" });
}

// A PR is synced through the tracked issues it names. A PR whose only tracked
// link is an epic, or that is labelled flow:v2 itself, is synced on its own.
async function syncFromPr(number) {
  const pr = await getPr(number);
  const issues = parseLinks(pr.body, repoFull, CONFIG.upstreamRepo).forkIssues;
  let viaIssue = false;
  let epicLinked = false;
  for (const n of issues) {
    const issue = await getIssue(n).catch(() => null);
    if (!issue || issue.pull_request || !tracked(issue)) continue;
    await syncIssue(n);
    if (isEpic(issue)) epicLinked = true;
    else viaIssue = true;
  }
  if (viaIssue) return;
  if (epicLinked || tracked(pr)) await syncPr(number, {});
  else log(`PR #${number}: no tracked issue and not labelled ${CONFIG.optInLabel}, skipped`);
}

async function targetsFromEvent() {
  const name = env.GITHUB_EVENT_NAME;
  const event = env.GITHUB_EVENT_PATH ? JSON.parse(fs.readFileSync(env.GITHUB_EVENT_PATH, "utf8")) : {};
  const t = { issues: [], prs: [], all: false };

  const cliIssue = option("--issue");
  const cliPr = option("--pr");
  const number = Number(cliIssue ?? cliPr ?? env.FLOW_NUMBER) || null;
  if (cliIssue) t.issues.push(Number(cliIssue));
  if (cliPr) t.prs.push(Number(cliPr));
  if (cliIssue || cliPr) return t;
  if (flag("--all")) return { ...t, all: true };

  switch (name) {
    case "issues":
      t.issues.push(event.issue.number);
      break;
    case "issue_comment":
      (event.issue.pull_request ? t.prs : t.issues).push(event.issue.number);
      break;
    case "pull_request_target":
    case "pull_request_review":
      t.prs.push(event.pull_request.number);
      break;
    case "workflow_run": {
      const run = event.workflow_run;
      let prs = (run.pull_requests ?? []).map((p) => p.number);
      if (!prs.length) prs = (await read.rest("GET", `${R}/commits/${run.head_sha}/pulls`).catch(() => [])).map((p) => p.number);
      t.prs.push(...prs);
      break;
    }
    case "workflow_dispatch":
      if (number) {
        const item = await getIssue(number);
        (item.pull_request ? t.prs : t.issues).push(number);
      } else {
        t.all = true;
      }
      break;
    default:
      t.all = true;
  }
  return t;
}

async function main() {
  if (!configured) {
    log(
      `Not configured (needs secrets.PROJECT_TOKEN and vars.FLOW_PROJECT_NUMBER): computing only, nothing is written. See docs/flow/README.md.`,
    );
  }
  if (dryRun) log("Dry run: nothing is written.");

  const targets = await targetsFromEvent();
  const failures = [];
  const attempt = async (label, fn) => {
    try {
      await fn();
    } catch (error) {
      failures.push(label);
      console.error(`${label}: ${error.stack ?? error.message}`);
    }
  };

  if (targets.all) {
    const issues = await read.paginate(`${R}/issues?state=open&labels=${encodeURIComponent(CONFIG.optInLabel)}`);
    for (const i of issues) {
      if (i.pull_request) targets.prs.push(i.number);
      else targets.issues.push(i.number);
    }
  }

  for (const n of targets.issues) await attempt(`Issue #${n}`, () => syncIssue(n));
  for (const n of targets.prs) await attempt(`PR #${n}`, () => syncFromPr(n));

  if (flag("--json")) console.log(JSON.stringify(report, null, 2));
  if (failures.length) {
    console.error(`Failed: ${failures.join(", ")}`);
    process.exitCode = 1;
  }
}

await main();

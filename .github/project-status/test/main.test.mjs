// main.mjs end to end against a fake GitHub: which calls it makes, with which
// token, and what the board holds afterwards. Nothing reaches the network.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { beforeEach, describe, test } from "node:test";

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "project-status-"));
const OPTIONS = ["Triage", "Issue review", "Ready to build", "In progress", "In review", "Upstream", "Done"].map((name, i) => ({ id: `OPT${i}`, name }));
const REVIEW = { id: 6167015210, node_id: "IC_review", body: "## 🔎 QA Review\n\n**Decision:** READY", user: { login: "jaysbeekay" }, author_association: "OWNER", created_at: "2026-10-14T11:11:18Z" };

let github;

// One fake repository and board per test. `items` is the repository's
// issues and PRs; `status` is each one's card on the board.
// `pulls` is what the open-PR listing serves, filtered by its state parameter
// as GitHub does (no parameter means open).
function fakeGitHub({ items, status = {}, options = OPTIONS, link = null, pulls = [] }) {
  const calls = [];
  const ok = (data, headers = {}) => ({ ok: true, status: 200, json: async () => data, text: async () => JSON.stringify(data), headers: { get: (h) => headers[h] ?? null } });
  const numberOf = (itemId) => Object.keys(items).find((n) => `ITEM_${items[n].node_id}` === itemId);

  globalThis.fetch = async (url, init) => {
    const body = init.body ? JSON.parse(init.body) : null;
    const token = init.headers.authorization.replace("Bearer ", "");
    calls.push({ method: init.method, url, token, query: body?.query });
    if (!url.startsWith("https://api.github.com/")) throw new Error(`fake GitHub reached ${url}`);

    if (url.endsWith("/graphql")) {
      const { query, variables } = body;
      if (query.includes("projectV2(number")) return ok({ data: { repositoryOwner: { projectV2: { id: "P1", title: "Sure delivery", field: { id: "F1", options } } } } });
      if (query.includes("addProjectV2ItemById")) return ok({ data: { addProjectV2ItemById: { item: { id: `ITEM_${variables.content}` } } } });
      if (query.includes("fieldValueByName")) {
        const name = status[numberOf(variables.id)];
        return ok({ data: { node: { fieldValueByName: name ? { name } : null } } });
      }
      if (query.includes("updateProjectV2ItemFieldValue")) {
        status[numberOf(variables.item)] = options.find((o) => o.id === variables.option).name;
        return ok({ data: { updateProjectV2ItemFieldValue: { projectV2Item: { id: variables.item } } } });
      }
    }
    const list = url.match(/\/repos\/jaysbeekay\/sure\/pulls\?(.*)$/);
    if (list) {
      const state = new URLSearchParams(list[1]).get("state") ?? "open";
      return ok(pulls.filter((p) => state === "all" || p.state === state));
    }
    const m = url.match(/\/repos\/jaysbeekay\/sure\/issues\/(\d+)(\/comments)?/);
    if (m?.[2]) return ok([REVIEW], link ? { link } : {});
    if (m && items[m[1]]) return ok({ number: Number(m[1]), state: "open", labels: [], ...items[m[1]] });
    throw new Error(`fake GitHub has no ${init.method} ${url}`);
  };
  return { calls, status };
}

// Runs main.mjs once for an event. A fresh query string makes Node evaluate
// the module again, as each workflow run does.
let run = 0;
async function runMain(eventName, event, env = {}, args = []) {
  const eventPath = path.join(dir, `event-${++run}.json`);
  fs.writeFileSync(eventPath, JSON.stringify(event));
  Object.assign(process.env, {
    GITHUB_REPOSITORY: "jaysbeekay/sure",
    GITHUB_EVENT_NAME: eventName,
    GITHUB_EVENT_PATH: eventPath,
    GITHUB_STEP_SUMMARY: "",
    GITHUB_TOKEN: "actions-token",
    PROJECT_TOKEN: "project-token",
    PROJECT_NUMBER: "3",
    GATEKEEPER_LOGINS: "",
    INPUT_NUMBER: "",
    INPUT_STATUS: "",
    ...env,
  });
  const lines = [];
  const log = console.log;
  const argv = process.argv;
  console.log = (line) => lines.push(line);
  process.argv = [...argv.slice(0, 2), ...args];
  process.exitCode = 0;
  try {
    await import(`../main.mjs?run=${run}`);
    return { lines, exitCode: process.exitCode };
  } finally {
    console.log = log;
    process.argv = argv;
    process.exitCode = 0;
  }
}

const sweep = () => runMain("schedule", { schedule: "0 * * * *" }, {}, ["--sweep"]);
const writes = () => github.calls.filter((c) => c.query?.includes("updateProjectV2ItemFieldValue")).length;
const pull = (number, { draft = false, state = "open", base = "main", body = "", association = "OWNER" } = {}) => ({ number, draft, state, body, base: { ref: base }, author_association: association });

const draftPr = (body) => ({ action: "opened", pull_request: { number: 432, draft: true, state: "open", body, base: { ref: "main" }, author_association: "OWNER" } });

describe("main.mjs against a fake GitHub", () => {
  beforeEach(() => {
    github = null;
  });

  test("a draft PR moves itself and its issue, skips the epic, and writes only with the project token", async () => {
    github = fakeGitHub({
      items: { 432: { node_id: "PR_432" }, 424: { node_id: "I_424" }, 118: { node_id: "I_118", labels: [{ name: "type:epic" }] } },
      status: { 424: "Ready to build", 118: "In progress" },
    });
    const { exitCode } = await runMain("pull_request_target", draftPr("Closes #424\nPart of #118"));

    assert.equal(exitCode, 0);
    assert.deepEqual(github.status, { 432: "In progress", 424: "In progress", 118: "In progress" });
    for (const call of github.calls) {
      assert.equal(call.token, call.url.endsWith("/graphql") ? "project-token" : "actions-token", call.url);
    }
    const added = github.calls.filter((c) => c.query?.includes("addProjectV2ItemById")).length;
    assert.equal(added, 2, "the epic is never added or moved");
  });

  test("a card already further on is not moved back", async () => {
    github = fakeGitHub({ items: { 432: { node_id: "PR_432" }, 424: { node_id: "I_424" } }, status: { 432: "In review", 424: "Upstream" } });
    await runMain("pull_request_target", draftPr("Closes #424"));
    assert.deepEqual(github.status, { 432: "In review", 424: "Upstream" });
    assert.equal(github.calls.filter((c) => c.query?.includes("updateProjectV2ItemFieldValue")).length, 0);
  });

  // Behind the card's status, so only the closed check holds it there.
  test("a closed issue is left where it is", async () => {
    github = fakeGitHub({ items: { 432: { node_id: "PR_432" }, 424: { node_id: "I_424", state: "closed" } }, status: { 424: "Ready to build" } });
    await runMain("pull_request_target", draftPr("Closes #424"));
    assert.deepEqual(github.status, { 432: "In progress", 424: "Ready to build" });
  });

  test("a reply citing a READY review reads the comments and moves the issue to Ready to build", async () => {
    github = fakeGitHub({ items: { 455: { node_id: "I_455" } }, status: { 455: "Issue review" } });
    const reply = { id: 6168876231, body: "Re QA review 6167015210 (READY).", user: { login: "jaysbeekay" }, author_association: "OWNER", created_at: "2026-10-14T12:57:43Z" };
    await runMain("issue_comment", { action: "created", issue: { number: 455 }, comment: reply });

    assert.deepEqual(github.status, { 455: "Ready to build" });
    const read = github.calls.find((c) => c.url.includes("/issues/455/comments"));
    assert.equal(read.token, "actions-token");
  });

  test("a manual run forces the status, backwards included", async () => {
    github = fakeGitHub({ items: { 424: { node_id: "I_424" } }, status: { 424: "In review" } });
    await runMain("workflow_dispatch", {}, { INPUT_NUMBER: "424", INPUT_STATUS: "Triage" });
    assert.deepEqual(github.status, { 424: "Triage" });
  });

  test("a missing Status option fails the run and names the options the board has", async () => {
    github = fakeGitHub({ items: { 432: { node_id: "PR_432" } }, options: OPTIONS.filter((o) => o.name !== "In progress") });
    const { lines, exitCode } = await runMain("pull_request_target", draftPr(""));
    assert.equal(exitCode, 1);
    assert.match(lines.join("\n"), /no Status option "In progress"\. Its options: Triage, Issue review/);
    assert.deepEqual(github.status, {});
  });

  test("without the project token it calls nothing", async () => {
    github = fakeGitHub({ items: {} });
    const { lines } = await runMain("pull_request_target", draftPr("Closes #424"), { PROJECT_TOKEN: "" });
    assert.deepEqual(github.calls, []);
    assert.match(lines[0], /^Not configured/);
  });

  test("a paging link to another host never receives a token", async () => {
    github = fakeGitHub({ items: {}, link: '<https://elsewhere.example/next?page=2>; rel="next"' });
    const reply = { id: 1, body: "Re 6167015210", user: { login: "jaysbeekay" }, author_association: "OWNER", created_at: "2026-10-14T12:57:43Z" };
    await assert.rejects(runMain("issue_comment", { action: "created", issue: { number: 455 }, comment: reply }), /Refusing to send a token to https:\/\/elsewhere\.example/);
    assert.deepEqual(github.calls.map((c) => new URL(c.url).host), ["api.github.com"]);
  });
});

// The hourly sweep reads every open PR as if it had just been edited. It is
// the only path for pre-flights (their up/* heads lack this workflow), PRs
// with a merge conflict and PRs from forks (no secrets on pull_request).
describe("main.mjs --sweep", () => {
  test("moves draft, ready and upstream-named pre-flights, a conflicted PR into main and an outside PR's own card", async () => {
    github = fakeGitHub({
      pulls: [
        pull(701, { draft: true, base: "mirror/upstream-main", body: "Closes #601" }),
        pull(702, { base: "mirror/upstream-main", body: "Closes #602" }),
        pull(703, { base: "mirror/upstream-main", body: "Closes #603\nUpstream PR: we-promise/sure#5196" }),
        pull(704, { body: "Fixes #604" }),
        pull(705, { body: "Closes #605", association: "NONE" }),
      ],
      items: Object.fromEntries([601, 602, 603, 604, 605, 701, 702, 703, 704, 705].map((n) => [n, { node_id: `N_${n}` }])),
      status: { 601: "Ready to build", 602: "In progress", 603: "In review", 604: "In progress", 605: "Ready to build", 704: "In progress" },
    });
    const { exitCode } = await sweep();

    assert.equal(exitCode, 0);
    assert.deepEqual(github.status, {
      701: "In progress", 601: "In progress",
      702: "In review", 602: "In review",
      703: "Upstream", 603: "Upstream",
      704: "In review", 604: "In review",
      705: "In review", 605: "Ready to build",
    });
    const listing = github.calls.find((c) => c.url.includes("/pulls?"));
    assert.equal(listing.token, "actions-token");
    assert.equal(new URL(listing.url).searchParams.get("state"), "open");
  });

  test("never moves a card backwards", async () => {
    github = fakeGitHub({
      pulls: [pull(701, { draft: true, body: "Closes #601" })],
      items: { 601: { node_id: "N_601" }, 701: { node_id: "N_701" } },
      status: { 601: "Upstream", 701: "In review" },
    });
    await sweep();
    assert.deepEqual(github.status, { 601: "Upstream", 701: "In review" });
    assert.equal(writes(), 0);
  });

  test("skips closed PRs", async () => {
    github = fakeGitHub({
      pulls: [pull(706, { state: "closed", body: "Closes #606" })],
      items: { 606: { node_id: "N_606" }, 706: { node_id: "N_706", state: "closed" } },
      status: { 606: "In progress", 706: "In progress" },
    });
    const { lines } = await sweep();
    assert.deepEqual(github.status, { 606: "In progress", 706: "In progress" });
    assert.match(lines.join("\n"), /Nothing to move/);
  });

  test("a second sweep makes zero status writes", async () => {
    const pulls = [pull(702, { base: "mirror/upstream-main", body: "Closes #602" }), pull(704, { body: "Fixes #604" })];
    const items = Object.fromEntries([602, 604, 702, 704].map((n) => [n, { node_id: `N_${n}` }]));
    github = fakeGitHub({ pulls, items, status: {} });
    await sweep();
    assert.equal(writes(), 4);
    github = fakeGitHub({ pulls, items, status: github.status });
    await sweep();
    assert.equal(writes(), 0);
  });

  test("an issue named by several PRs is moved once, to the furthest status", async () => {
    github = fakeGitHub({
      pulls: [pull(708, { body: "Part of #607" }), pull(707, { draft: true, body: "Part of #607" })],
      items: Object.fromEntries([607, 707, 708].map((n) => [n, { node_id: `N_${n}` }])),
      status: { 607: "Ready to build" },
    });
    await sweep();
    assert.equal(github.status[607], "In review");
    assert.equal(github.calls.filter((c) => c.url.endsWith("/issues/607")).length, 1);
  });
});

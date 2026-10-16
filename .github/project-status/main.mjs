#!/usr/bin/env node
// Moves cards on the project board for the event that started this run.
// Decisions are in logic.mjs; this file only reads GitHub and writes the
// board. See docs/project-status.md.
//
// Writes go through PROJECT_TOKEN: the Actions token cannot write to a
// user-owned project. Setting a project field triggers no workflow, and this
// script never comments, labels or pushes, so it cannot start Gatekeeper
// (main.yml) or itself.

import fs from "node:fs";

import { STATUSES, citedIds, decide, shouldMove } from "./logic.mjs";

const env = process.env;
const API = "https://api.github.com";
const repo = env.GITHUB_REPOSITORY;
const owner = repo.split("/")[0];
const EPIC_LABEL = "type:epic";

const summary = [];
function log(line) {
  console.log(line);
  summary.push(line);
}

// Only ever api.github.com: the tokens must not go anywhere else, whatever
// URL a paging header or a future caller supplies.
async function call(token, method, path, body) {
  const url = path.startsWith("http") ? path : `${API}${path}`;
  if (!url.startsWith(`${API}/`)) throw new Error(`Refusing to send a token to ${url}`);
  const res = await fetch(url, {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      accept: "application/vnd.github+json",
      "x-github-api-version": "2022-11-28",
      ...(body ? { "content-type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status}: ${(await res.text()).slice(0, 300)}`);
  return { data: await res.json(), link: res.headers.get("link") };
}

const read = async (path) => (await call(env.GITHUB_TOKEN, "GET", path)).data;

async function readAll(path) {
  const out = [];
  let url = `${path}${path.includes("?") ? "&" : "?"}per_page=100`;
  while (url) {
    const { data, link } = await call(env.GITHUB_TOKEN, "GET", url);
    out.push(...data);
    url = link?.split(",").find((p) => p.includes('rel="next"'))?.match(/<([^>]+)>/)?.[1] ?? null;
  }
  return out;
}

async function gql(query, variables) {
  const { data } = await call(env.PROJECT_TOKEN, "POST", "/graphql", { query, variables });
  if (data.errors?.length) throw new Error(`GraphQL: ${data.errors.map((e) => e.message).join("; ")}`);
  return data.data;
}

async function loadBoard() {
  const data = await gql(
    `query($login: String!, $number: Int!) {
      repositoryOwner(login: $login) {
        ... on ProjectV2Owner {
          projectV2(number: $number) {
            id
            title
            field(name: "Status") { ... on ProjectV2SingleSelectField { id options { id name } } }
          }
        }
      }
    }`,
    { login: owner, number: Number(env.PROJECT_NUMBER) },
  );
  const board = data.repositoryOwner?.projectV2;
  if (!board) throw new Error(`No project #${env.PROJECT_NUMBER} owned by ${owner}. Check vars.PROJECT_NUMBER.`);
  if (!board.field?.id) throw new Error(`Project "${board.title}" has no single-select field named "Status".`);
  return board;
}

// The item for a piece of content, added to the board if it is not on it
// yet (adding an item that is already there returns the existing one).
async function itemFor(board, contentId) {
  const added = await gql(
    `mutation($project: ID!, $content: ID!) {
      addProjectV2ItemById(input: { projectId: $project, contentId: $content }) { item { id } }
    }`,
    { project: board.id, content: contentId },
  );
  const id = added.addProjectV2ItemById.item.id;
  const current = await gql(
    `query($id: ID!) {
      node(id: $id) {
        ... on ProjectV2Item { fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } }
      }
    }`,
    { id },
  );
  return { id, status: current.node?.fieldValueByName?.name ?? null };
}

async function setStatus(board, itemId, optionId) {
  await gql(
    `mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $project, itemId: $item, fieldId: $field, value: { singleSelectOptionId: $option }
      }) { projectV2Item { id } }
    }`,
    { project: board.id, item: itemId, field: board.field.id, option: optionId },
  );
}

async function main() {
  if (!env.PROJECT_TOKEN || !env.PROJECT_NUMBER) {
    log("Not configured: set secrets.PROJECT_TOKEN and vars.PROJECT_NUMBER (docs/project-status.md). Nothing moved.");
    return;
  }

  const eventName = env.GITHUB_EVENT_NAME;
  const event = JSON.parse(fs.readFileSync(env.GITHUB_EVENT_PATH, "utf8"));
  const ctx = {
    repo,
    upstreamRepo: "we-promise/sure",
    mirrorBase: "mirror/upstream-main",
    // Until GATEKEEPER_LOGINS is set, Gatekeeper is taken to post as the
    // repository owner, as it does today.
    gatekeepers: (env.GATEKEEPER_LOGINS || owner).split(/[\s,]+/).filter(Boolean),
  };
  if (eventName === "workflow_dispatch") event.inputs = { number: env.INPUT_NUMBER, status: env.INPUT_STATUS };

  // A reply to a review needs the issue's earlier comments; nothing else does.
  if (eventName === "issue_comment" && !event.issue.pull_request && citedIds(event.comment.body).size) {
    ctx.comments = await readAll(`/repos/${repo}/issues/${event.issue.number}/comments`);
  }

  const moves = decide(eventName, event, ctx);
  if (!moves.length) {
    log("Nothing to move for this event.");
    return;
  }

  const board = await loadBoard();
  let failed = false;
  for (const { number, status, force = false } of moves) {
    try {
      const option = board.field.options.find((o) => o.name.toLowerCase() === status.toLowerCase());
      if (!option) {
        throw new Error(`"${board.title}" has no Status option "${status}". Its options: ${board.field.options.map((o) => o.name).join(", ")}. Expected: ${STATUSES.join(", ")}.`);
      }

      const item = await read(`/repos/${repo}/issues/${number}`);
      const labels = item.labels.map((l) => l.name);
      if (!force && item.state !== "open") {
        log(`#${number}: closed, left as it is.`);
        continue;
      }
      if (!force && labels.includes(EPIC_LABEL)) {
        log(`#${number}: an epic, left as it is (its progress comes from its sub-issues).`);
        continue;
      }

      const card = await itemFor(board, item.node_id);
      if (!shouldMove(card.status, option.name, { force })) {
        log(`#${number}: already at ${card.status}, not moved back to ${option.name}.`);
        continue;
      }
      await setStatus(board, card.id, option.id);
      log(`#${number}: ${card.status ?? "no status"} → ${option.name}.`);
    } catch (error) {
      failed = true;
      log(`#${number}: failed, ${error.message}`);
    }
  }
  if (failed) process.exitCode = 1;
}

try {
  await main();
} finally {
  if (env.GITHUB_STEP_SUMMARY && summary.length) fs.appendFileSync(env.GITHUB_STEP_SUMMARY, `${summary.join("\n\n")}\n`);
}

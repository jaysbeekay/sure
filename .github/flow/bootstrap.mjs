#!/usr/bin/env node
// One-off, re-runnable setup for the delivery flow (docs/flow/README.md):
//   - the flow:v2 opt-in label (Actions token);
//   - the "Sure delivery" project, linked to this repository (PROJECT_TOKEN);
//   - every field in config.mjs, with its options.
//
// It creates what is missing and reports what differs. It never deletes a
// field or rewrites an existing field's options, because that can drop values
// people have already set.

import fs from "node:fs";

import { CONFIG, FIELDS } from "./config.mjs";
import { createClient } from "./github.mjs";
import { findProjectByTitle, loadProject } from "./project.mjs";

const env = process.env;
const repoFull = env.GITHUB_REPOSITORY || "jaysbeekay/sure";
const [owner, repoName] = repoFull.split("/");
const dryRun = env.FLOW_DRY_RUN === "1";
const title = env.FLOW_PROJECT_TITLE || CONFIG.projectTitle;
const makePublic = env.FLOW_PROJECT_PUBLIC === "true";

if (!env.PROJECT_TOKEN) {
  console.error("PROJECT_TOKEN is not set. Create the token and the repository secret first (docs/flow/README.md, step 1).");
  process.exit(1);
}

const project = createClient(env.PROJECT_TOKEN);
const repo = createClient(env.GITHUB_TOKEN || env.PROJECT_TOKEN);
const summary = [];
const note = (line) => {
  console.log(line);
  summary.push(line);
};

async function ensureLabel() {
  try {
    await repo.rest("GET", `/repos/${repoFull}/labels/${encodeURIComponent(CONFIG.optInLabel)}`);
    note(`- Label \`${CONFIG.optInLabel}\` exists.`);
  } catch (error) {
    if (error.status !== 404) throw error;
    if (!dryRun) {
      await repo.rest("POST", `/repos/${repoFull}/labels`, {
        name: CONFIG.optInLabel,
        color: "5319E7",
        description: "Tracked by the delivery flow project (docs/flow/README.md)",
      });
    }
    note(`- Label \`${CONFIG.optInLabel}\` ${dryRun ? "would be created" : "created"}.`);
  }
}

async function ensureProject() {
  const number = Number(env.FLOW_PROJECT_NUMBER) || null;
  if (number) {
    const existing = await loadProject(project, owner, number);
    if (!existing) throw new Error(`No project #${number} owned by ${owner}.`);
    note(`- Using project #${existing.number}, "${existing.title}": ${existing.url}`);
    return existing;
  }

  const { ownerId, project: found } = await findProjectByTitle(project, owner, title);
  if (found) {
    note(`- Found project #${found.number}, "${found.title}": ${found.url}`);
    return found;
  }
  if (dryRun) {
    note(`- Project "${title}" would be created.`);
    return null;
  }

  const { repository } = await project.graphql(`query($o: String!, $n: String!) { repository(owner: $o, name: $n) { id } }`, { o: owner, n: repoName });
  const created = await project.graphql(
    `mutation($owner: ID!, $title: String!, $repo: ID!) {
      createProjectV2(input: { ownerId: $owner, title: $title, repositoryId: $repo }) { projectV2 { number } }
    }`,
    { owner: ownerId, title, repo: repository.id },
  );
  const fresh = await loadProject(project, owner, created.createProjectV2.projectV2.number);
  note(`- Created project #${fresh.number}, "${fresh.title}", linked to ${repoFull}: ${fresh.url}`);
  return fresh;
}

async function ensureFields(p) {
  for (const def of Object.values(FIELDS)) {
    const existing = p.fields.get(def.name);
    if (existing) {
      if (existing.dataType !== def.type) {
        note(`- ! Field "${def.name}" is ${existing.dataType}, expected ${def.type}. Rename or delete it in the project, then re-run.`);
        continue;
      }
      if (def.type === "SINGLE_SELECT") {
        const missing = def.options.map((o) => o.name).filter((n) => !existing.options.has(n));
        if (missing.length) note(`- ! Field "${def.name}" lacks options: ${missing.join(", ")}. Add them in the project's field settings.`);
        else note(`- Field "${def.name}" is complete.`);
      } else {
        note(`- Field "${def.name}" exists.`);
      }
      continue;
    }

    if (dryRun) {
      note(`- Field "${def.name}" would be created.`);
      continue;
    }
    const input = { projectId: p.id, dataType: def.type, name: def.name };
    if (def.type === "SINGLE_SELECT") {
      input.singleSelectOptions = def.options.map((o) => ({ name: o.name, color: o.color, description: o.description }));
    }
    await project.graphql(
      `mutation($input: CreateProjectV2FieldInput!) { createProjectV2Field(input: $input) { projectV2Field { ... on ProjectV2FieldCommon { id } } } }`,
      { input },
    );
    note(`- Field "${def.name}" created (${def.owner === "human" ? "set by people" : "set by the sync"}).`);
  }
}

async function finish(p) {
  if (!p || dryRun) return;
  const input = {
    projectId: p.id,
    shortDescription: `Delivery flow for ${repoFull}: issue → Gatekeeper → draft → ready → upstream. Items join when labelled ${CONFIG.optInLabel}.`,
  };
  if (makePublic) input.public = true;
  await project.graphql(`mutation($input: UpdateProjectV2Input!) { updateProjectV2(input: $input) { projectV2 { id } } }`, { input });
  if (makePublic) note("- Project made public.");

  note("");
  note("**Next**");
  note(`1. Set the repository variable \`FLOW_PROJECT_NUMBER\` to \`${p.number}\` (Settings → Secrets and variables → Actions → Variables).`);
  note("2. Create the views listed in docs/flow/README.md (the API cannot create views).");
  note(`3. Pilot: add the \`${CONFIG.optInLabel}\` label to one issue and watch the Flow sync run.`);
}

await ensureLabel();
const p = await ensureProject();
if (p) await ensureFields(p);
await finish(p);

if (env.GITHUB_STEP_SUMMARY) fs.appendFileSync(env.GITHUB_STEP_SUMMARY, `## Flow bootstrap${dryRun ? " (dry run)" : ""}\n\n${summary.join("\n")}\n`);

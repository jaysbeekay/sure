// Project (v2) reads and writes. Everything here needs PROJECT_TOKEN: the
// Actions token cannot write to a user-owned project.

const FIELD_FRAGMENT = `
  fields(first: 50) {
    nodes {
      ... on ProjectV2FieldCommon { id name dataType }
      ... on ProjectV2SingleSelectField { options { id name } }
    }
  }`;

function toProject(node) {
  if (!node) return null;
  const fields = new Map();
  for (const f of node.fields.nodes) {
    if (!f?.name) continue;
    fields.set(f.name, { id: f.id, dataType: f.dataType, options: new Map((f.options ?? []).map((o) => [o.name, o.id])) });
  }
  return { id: node.id, number: node.number, title: node.title, url: node.url, fields };
}

export async function loadProject(gh, ownerLogin, number) {
  const data = await gh.graphql(
    `query($login: String!, $number: Int!) {
      repositoryOwner(login: $login) {
        ... on ProjectV2Owner { projectV2(number: $number) { id number title url ${FIELD_FRAGMENT} } }
      }
    }`,
    { login: ownerLogin, number },
  );
  return toProject(data.repositoryOwner?.projectV2);
}

export async function findProjectByTitle(gh, ownerLogin, title) {
  const data = await gh.graphql(
    `query($login: String!, $query: String!) {
      repositoryOwner(login: $login) {
        id
        ... on ProjectV2Owner { projectsV2(first: 20, query: $query) { nodes { id number title url ${FIELD_FRAGMENT} } } }
      }
    }`,
    { login: ownerLogin, query: title },
  );
  const owner = data.repositoryOwner;
  const match = owner?.projectsV2?.nodes.find((p) => p.title === title);
  return { ownerId: owner?.id, project: toProject(match) };
}

// The item for a piece of content in this project, with its current values,
// or null when the content is not on the project yet.
export async function loadItem(gh, project, contentId) {
  const data = await gh.graphql(
    `query($id: ID!) {
      node(id: $id) {
        ... on Issue { projectItems(first: 20) { nodes { ...item } } }
        ... on PullRequest { projectItems(first: 20) { nodes { ...item } } }
      }
    }
    fragment item on ProjectV2Item {
      id
      project { id }
      fieldValues(first: 40) {
        nodes {
          ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2FieldCommon { name } } }
          ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { name } } }
          ... on ProjectV2ItemFieldNumberValue { number field { ... on ProjectV2FieldCommon { name } } }
        }
      }
    }`,
    { id: contentId },
  );
  const node = data.node?.projectItems?.nodes.find((i) => i.project.id === project.id);
  if (!node) return null;
  const values = new Map();
  for (const v of node.fieldValues.nodes) {
    if (!v?.field?.name) continue;
    values.set(v.field.name, v.name ?? v.text ?? v.number ?? null);
  }
  return { itemId: node.id, values };
}

export async function addItem(gh, project, contentId) {
  const data = await gh.graphql(
    `mutation($project: ID!, $content: ID!) {
      addProjectV2ItemById(input: { projectId: $project, contentId: $content }) { item { id } }
    }`,
    { project: project.id, content: contentId },
  );
  return { itemId: data.addProjectV2ItemById.item.id, values: new Map() };
}

function same(current, desired) {
  if (current == null || current === "") return desired == null || desired === "";
  return String(current) === String(desired);
}

// Writes only the fields whose value changes, and only automation-owned
// fields: the caller never passes Priority, Severity or Size.
export async function writeFields(gh, project, item, desired, { dryRun = false, log = console.log } = {}) {
  const changes = [];
  for (const [name, raw] of Object.entries(desired)) {
    const field = project.fields.get(name);
    if (!field) {
      log(`  ! project has no "${name}" field; run the Flow bootstrap workflow`);
      continue;
    }
    // Text is stored truncated, so it is compared truncated: otherwise a long
    // value would differ from what was stored and be rewritten on every run.
    const value = field.dataType === "TEXT" && raw != null ? String(raw).slice(0, 1000) : raw;
    if (same(item.values.get(name), value)) continue;
    changes.push(name);
    if (dryRun) continue;

    if (value == null || value === "") {
      await gh.graphql(
        `mutation($project: ID!, $item: ID!, $field: ID!) {
          clearProjectV2ItemFieldValue(input: { projectId: $project, itemId: $item, fieldId: $field }) { projectV2Item { id } }
        }`,
        { project: project.id, item: item.itemId, field: field.id },
      );
      continue;
    }

    let input;
    if (field.dataType === "SINGLE_SELECT") {
      const option = field.options.get(String(value));
      if (!option) {
        log(`  ! "${name}" has no option "${value}"; run the Flow bootstrap workflow`);
        continue;
      }
      input = { singleSelectOptionId: option };
    } else if (field.dataType === "NUMBER") {
      input = { number: Number(value) };
    } else {
      input = { text: value };
    }
    await gh.graphql(
      `mutation($project: ID!, $item: ID!, $field: ID!, $value: ProjectV2FieldValue!) {
        updateProjectV2ItemFieldValue(input: { projectId: $project, itemId: $item, fieldId: $field, value: $value }) { projectV2Item { id } }
      }`,
      { project: project.id, item: item.itemId, field: field.id, value: input },
    );
  }
  return changes;
}

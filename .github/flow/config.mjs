// Configuration for the delivery flow automation (docs/flow/README.md).
//
// Everything here is fork process. None of it is part of the application, and
// none of it travels upstream: up/* branches are cut from upstream main.

export const CONFIG = {
  // Only issues carrying this label, and the pull requests that name them, are
  // tracked. It is how the new flow runs beside the current one: an item moves
  // across when the label is added, and nothing else is touched.
  optInLabel: "flow:v2",

  upstreamRepo: "we-promise/sure",
  mirrorBase: "mirror/upstream-main",
  defaultBase: "main",

  // Gatekeeper (Hermes, via .github/workflows/main.yml) and the nightly Codex
  // review both post as the owner. A review heading is only trusted from these
  // logins, because anyone can comment on a public repository.
  reviewerLogins: ["jaysbeekay"],

  // A reply only answers a review when its author is trusted in the same way.
  trustedAssociations: ["OWNER", "MEMBER", "COLLABORATOR"],

  coderabbitLogin: "coderabbitai[bot]",
  // CodeRabbit reviews ready pull requests only (CLAUDE.md rule 4), so it is
  // waited on after a PR leaves draft and never before.
  coderabbitRequiredOnReady: true,

  // Epics are tracked through their sub-issues, not through the stage machine.
  epicLabel: "type:epic",

  gateCheckName: "Flow gate",
  projectTitle: "Sure delivery",
};

// The order is the order of the work. It decides board column order and which
// pull request an issue reports when it has several (the least advanced).
export const STAGES = [
  { name: "Triage plan", color: "GRAY", description: "The issue needs its triage plan or its upstream link" },
  { name: "Issue review", color: "PURPLE", description: "Waiting on the Gatekeeper issue review" },
  { name: "Address issue review", color: "ORANGE", description: "Gatekeeper reviewed the plan: validate and reply" },
  { name: "Ready to build", color: "BLUE", description: "Plan settled: open the draft PR" },
  { name: "Draft PR", color: "PURPLE", description: "Waiting on the light Gatekeeper review and CI" },
  { name: "Address draft feedback", color: "ORANGE", description: "Light review and CI are in: fix or reply" },
  { name: "Mark ready", color: "BLUE", description: "CI green and every review answered: mark the PR ready" },
  { name: "Full review", color: "PURPLE", description: "Waiting on the full Gatekeeper review, CI and CodeRabbit" },
  { name: "Address full review", color: "ORANGE", description: "Full review, CodeRabbit and CI are in: fix or reply" },
  { name: "Upstream PR", color: "GREEN", description: "Open the upstream draft PR, then follow it upstream" },
  { name: "Owner approval", color: "YELLOW", description: "Waiting on the owner's decision" },
  { name: "Done", color: "GRAY", description: "Finished" },
];

export const STAGE = Object.fromEntries(STAGES.map((s) => [s.name, s.name]));

export const WAITING_ON = [
  { name: "Author", color: "ORANGE", description: "Whoever is doing the work acts next" },
  { name: "Gatekeeper", color: "PURPLE", description: "A Gatekeeper review has not landed" },
  { name: "CI", color: "BLUE", description: "Checks are still running" },
  { name: "CodeRabbit", color: "PINK", description: "CodeRabbit has not reviewed the ready PR" },
  { name: "Owner", color: "YELLOW", description: "The owner decides" },
  { name: "Upstream", color: "GREEN", description: "we-promise/sure maintainers" },
  { name: "Nobody", color: "GRAY", description: "Done" },
];

export const UPSTREAM = [
  { name: "Fork only", color: "GRAY", description: "Not going upstream" },
  { name: "Needs upstream issue", color: "RED", description: "Upstream-bound, but no upstream issue is linked" },
  { name: "Upstream issue linked", color: "BLUE", description: "The fork issue names its upstream issue" },
  { name: "Pre-flight open", color: "PURPLE", description: "Fork PR against mirror/upstream-main, upstream PR not named yet" },
  { name: "Upstream draft", color: "YELLOW", description: "The upstream PR is a draft" },
  { name: "Upstream ready", color: "ORANGE", description: "The upstream PR is ready for review" },
  { name: "Landed upstream", color: "GREEN", description: "Merged into we-promise/sure" },
  { name: "Closed unmerged", color: "RED", description: "The upstream PR was closed without merging" },
];

export const UPSTREAM_ORDER = UPSTREAM.map((u) => u.name);

export const CI_STATES = [
  { name: "Pending", color: "YELLOW", description: "At least one check has not finished" },
  { name: "Green", color: "GREEN", description: "Every check finished and passed" },
  { name: "Red", color: "RED", description: "At least one check failed" },
  { name: "None", color: "GRAY", description: "No checks on the head commit" },
];

export const KINDS = [
  { name: "Epic", color: "PINK", description: "Tracked through its sub-issues" },
  { name: "Issue", color: "GRAY", description: "A fork issue" },
  { name: "Pre-flight PR", color: "PURPLE", description: "Against mirror/upstream-main, ahead of an upstream PR" },
  { name: "Fork PR", color: "BLUE", description: "Into fork main" },
  { name: "Stacked PR", color: "ORANGE", description: "Based on another feature branch" },
];

// `owner: "automation"` fields are rewritten on every sync. `owner: "human"`
// fields are created by the bootstrap and never written by the sync.
// Names are one word where they are filtered on, so a view can say
// `waiting:Owner` or `unanswered:>0`.
export const FIELDS = {
  stage: { name: "Stage", type: "SINGLE_SELECT", owner: "automation", options: STAGES },
  waitingOn: { name: "Waiting", type: "SINGLE_SELECT", owner: "automation", options: WAITING_ON },
  upstream: { name: "Upstream", type: "SINGLE_SELECT", owner: "automation", options: UPSTREAM },
  ci: { name: "CI", type: "SINGLE_SELECT", owner: "automation", options: CI_STATES },
  kind: { name: "Kind", type: "SINGLE_SELECT", owner: "automation", options: KINDS },
  unanswered: { name: "Unanswered", type: "NUMBER", owner: "automation" },
  nextStep: { name: "Next step", type: "TEXT", owner: "automation" },
  lastReview: { name: "Last review", type: "TEXT", owner: "automation" },
  forkIssue: { name: "Fork issue", type: "TEXT", owner: "automation" },
  upstreamIssue: { name: "Upstream issue", type: "TEXT", owner: "automation" },
  upstreamPr: { name: "Upstream PR", type: "TEXT", owner: "automation" },
  priority: {
    name: "Priority",
    type: "SINGLE_SELECT",
    owner: "human",
    options: [
      { name: "P0", color: "RED", description: "Drop everything" },
      { name: "P1", color: "ORANGE", description: "Next" },
      { name: "P2", color: "YELLOW", description: "Planned" },
      { name: "P3", color: "GRAY", description: "Someday" },
    ],
  },
  severity: {
    name: "Severity",
    type: "SINGLE_SELECT",
    owner: "human",
    options: [
      { name: "S1", color: "RED", description: "Money wrong, data lost, or a security or privacy leak" },
      { name: "S2", color: "ORANGE", description: "A wrong figure or a broken flow" },
      { name: "S3", color: "YELLOW", description: "Broken, with a workaround" },
      { name: "S4", color: "GRAY", description: "Cosmetic, or a missing test" },
    ],
  },
  size: {
    name: "Size",
    type: "SINGLE_SELECT",
    owner: "human",
    options: [
      { name: "S", color: "GREEN", description: "1-2 days" },
      { name: "M", color: "YELLOW", description: "3-5 days" },
      { name: "L", color: "ORANGE", description: "1-2 weeks" },
      { name: "XL", color: "RED", description: "Split it" },
    ],
  },
};

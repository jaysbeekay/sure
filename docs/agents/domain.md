# Domain Docs

How the engineering skills should consume this repository's domain documentation.

## Before exploring, read these

- `GLOSSARY.md` at the repository root.
- `docs/adr/`: read ADRs that touch the area being changed.

If these files do not exist, proceed silently. Do not flag their absence or create them speculatively. Domain-modeling skills create them when terminology or decisions are actually resolved.

## File structure

This repository uses a single-context layout:

```
/
├── GLOSSARY.md
├── docs/adr/
└── src/
```

## Use the glossary's vocabulary

When output names a domain concept—in an issue title, proposal, hypothesis, or test—use the term defined in `GLOSSARY.md`. Avoid synonyms the glossary explicitly rejects.

If a needed concept is missing, reconsider whether the language already exists in the codebase or note the gap for domain modeling.

## Flag ADR conflicts

If proposed work contradicts an existing ADR, surface the conflict explicitly instead of silently overriding the recorded decision.

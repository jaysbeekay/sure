## Summary

<!-- Two or three sentences: what a user gets, and the one design choice a maintainer should know about. -->

{{FIXES}}

## What changed

{{COMMITS}}

{{FILES}}

## Demo data

<!-- What Demo::Generator now produces for this feature, or "no demo data needed: <why>". Maintainers ask for this before review. -->

## Screenshots

<!-- Light and dark theme for anything visual, taken from the demo data. Delete the section for a change with no UI. -->

## Migration notes

<!-- Columns added, defaults, whether existing rows are rewritten, anything to run after deploy. Or "no migration". -->

## Verification

- `bin/rails test <paths>`:
- `bin/rubocop`, `bundle exec erb_lint`, `npm run lint`, `bin/brakeman`: clean

## Blast radius

<!-- Every shared code path this touches beyond the feature's own files, and what protects each one. -->

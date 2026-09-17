# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common Development Commands

### Development Server
- `bin/dev` - Start development server (Rails, Sidekiq, Tailwind CSS watcher)
- `bin/rails server` - Start Rails server only
- `bin/rails console` - Open Rails console

### Testing
- `bin/rails test` - Run all tests
- `bin/rails test:db` - Run tests with database reset
- `DISABLE_PARALLELIZATION=true bin/rails test:system` - Run system tests only (use sparingly - they take longer)
- `bin/rails test test/models/account_test.rb` - Run specific test file
- `bin/rails test test/models/account_test.rb:42` - Run specific test at line

#### System Tests in the Dev Container
When running inside the Dev Container, the `SELENIUM_REMOTE_URL` environment variable is automatically set to the bundled `selenium/standalone-chromium` service. System tests will connect to that remote browser — no local Chrome installation is required.

```bash
DISABLE_PARALLELIZATION=true bin/rails test:system
```

To watch the browser live, open `http://localhost:7900` or `http://localhost:4444` in your host browser (password: `secret`).

### Linting & Formatting
- `bin/rubocop` - Run Ruby linter
- `npm run lint` - Check JavaScript/TypeScript code
- `npm run lint:fix` - Fix JavaScript/TypeScript issues
- `npm run format` - Format JavaScript/TypeScript code
- `bin/brakeman` - Run security analysis

### Database
- `bin/rails db:prepare` - Create and migrate database
- `bin/rails db:migrate` - Run pending migrations
- `bin/rails db:rollback` - Rollback last migration
- `bin/rails db:seed` - Load seed data

### Setup
- `bin/setup` - Initial project setup (installs dependencies, prepares database)

## Issue and Pull Request Workflow

**Scope: this fork (`jaysbeekay/sure`) only.** This section is local policy, not
upstream convention. It cites this fork's issue and PR numbers, its CodeRabbit
configuration, and its star count. When preparing a contribution for
`we-promise/sure`, leave this section behind -- several issues here are labelled
`upstream:candidate`, so a CLAUDE.md change can otherwise ride upstream by
accident and be wrong there.

**The repository owner's ways of working overrule anything else in this file.**
Where another section, a tool default or a bot suggestion disagrees with the
rules below, the rules below win. Rules marked *(both repos)* also govern work
on `we-promise/sure`: upstream PRs, issues, comments and review replies prepared
from this fork.

### Ways of working

1. **No AI attribution** *(both repos)*. See the Attribution section below.
2. **Evidence before work** *(both repos)*. Every issue and PR is grounded in
   facts established from the code, configuration and framework behaviour, not
   memory or assumption. Test positive cases (the fix works) and negative cases
   (what must not change, invalid input, both sides of each boundary). Write the
   test first and watch it fail for the right reason. After the fix, break each
   change deliberately and confirm a test catches it.
3. **Validate every PR against upstream `AGENTS.md`** *(both repos)*. Read the
   current `we-promise/sure` `AGENTS.md` before opening a PR or marking one ready,
   and check the change against it. Upstream reviewers enforce it.
4. **CodeRabbit reviews only ready pull requests** *(both repos)*. Marking a PR
   ready starts its review, and later pushes get incremental passes. Do not force
   a review before then: no `@coderabbitai review` or `@coderabbitai full review`
   comment on a draft. On a ready PR, if an incremental pass returns nothing,
   `@coderabbitai full review` forces a fresh pass; three plain `review` requests
   produced nothing on #86 before it did.
5. **Re-check before every update** *(both repos)*. Several contributors, other
   sessions and review bots work on these repositories, and state changes quickly.
   Immediately before editing an issue or PR body, commenting, pushing, marking
   ready, closing or resolving a thread, re-fetch its state, head commit,
   comments, reviews and threads. If anything changed, read it and adjust first.
   Push with `--force-with-lease` or after a fast-forward check.
6. **If unsure, stop** *(both repos)*. Do not guess, and do not paper over a gap
   with speculative reasoning. State exactly what is unknown and ask the owner.
7. **Gatekeeper reviews gate the work** *(this fork)*. Raising an issue starts a
   Gatekeeper review; a draft PR gets a light-touch Gatekeeper review; a ready PR
   gets a full Gatekeeper review. Each gate below waits for its review to land and
   for every finding to be validated: checked against the current code and head
   commit, then fixed or declined with evidence.
8. **Upstream PRs open as drafts and link both ways** *(both repos)*. A PR raised
   on `we-promise/sure` opens as a **draft**, and its description carries **two
   separate links**: the upstream issue it answers (or the coordination issue for
   programme work), and its **fork pre-flight PR**. The fork PR links back to the
   upstream one. These are two obligations, not one -- satisfying the issue link
   does not satisfy the fork link, and on 2026-09-17 every upstream PR linked an
   issue while **none** linked its fork PR, with two fork PRs missing the reverse
   link as well. The issue link shows a maintainer which programme a slice belongs
   to; the fork link shows where its CI, Gatekeeper and CodeRabbit history lives,
   which is most of the review evidence and is invisible from upstream otherwise.
   Check both directions by grepping (`jaysbeekay/sure#` in upstream bodies,
   `we-promise/sure#` in fork bodies) rather than from memory -- a PR reads as
   correctly linked when the reverse link is missing. Where the two share a
   branch, say "same branch, same commit"; where the fork pre-flight is a
   cherry-pick onto the mirror, say that instead.

### Issue and pull request sequence (this fork)

Follow this sequence for any issue-driven change. Do not skip or reorder steps.

1. **Raise the issue and wait for its Gatekeeper review.** Do not edit the issue
   or start a PR until the review has landed and been validated.
2. **Re-read the issue.** Fetch it fresh, including every comment. Requirements
   and decisions are frequently added in comments after the body was written.
3. **Post a detailed triage plan as a comment under that issue** before any PR
   work. Every issue gets its own plan. It must state:
   - **What the issue actually is** -- the defect or requirement in terms of
     observed behaviour, not a restatement of the title.
   - **What the PR will touch** -- files, classes and methods, and the blast
     radius: who else hits this line, and what do they pass? See the section
     below.
   - **What the fix looks like**, and what it deliberately leaves out.
   - **How it will be tested** -- the named positive and negative tests, and the
     assertion that would fail if the fix were absent. "Tests pass" is not a
     test plan.
   - **The evidence required** -- what will demonstrate that it fixes the issue,
     and that it will not introduce future defects: neighbouring callers,
     regression coverage and a full-suite run.
4. **Open the change as a DRAFT pull request** following that plan. Wait for the
   light-touch Gatekeeper review. Do not work on fixes until it has landed and its
   feedback has been validated.
5. **Mark it ready for review** only once every CI check is green, all validated
   feedback is addressed, and the change has been checked against upstream
   `AGENTS.md`.
6. **Wait for the full Gatekeeper review and CodeRabbit's review**, then validate
   and address both. Do not merge until the full Gatekeeper review has landed and
   its feedback has been validated.
7. **Merge only after the repository owner has given approval in their own
   words.** A green PR is not an approved one.

### Before writing any fix: state the blast radius

Write one sentence before changing code:

> **Who else hits this line, and what do they pass?**

This is not optional and it is not a formality. Two defects on this repository
came from checking a fix against *the bug as described* rather than against the
boundary of the code it touched:

- A callback was moved from `before_save` to `validate` so it would actually
  block a save. Correct for the reported case; it then rejected every ordinary
  edit of a loan that already had an offset account, because the form
  resubmits the ids it already holds. The blast-radius sentence contains that
  bug outright.
- A reference date was pinned at the view layer. The component it was passed to
  then handed the work to `Loan::PayoffProjection`, which derived its own date,
  so the defect moved down a level instead of closing.

Two corollaries:

- **Follow the value one hop further than feels necessary.** If a fix is "pass
  X in", check whether the callee also derives X for itself.
- **Prove the test before trusting it.** Break the fix deliberately and watch
  the new test fail. A test written after a fix tends to assert the author's
  mental model, which is the thing that was wrong.

### Reference dates are injected, never derived

Anything under `app/models/loan/` and its view components takes its "today" as
an argument. Defaulting to `Date.current` in the signature is fine; reading
`Date.current` in the body of a method that already has a caller-supplied date
is not. A view that shows several date-sensitive figures captures ONE date and
passes it to all of them.

This class of defect has recurred repeatedly on the loan epic (#79, #83, #86,
#89 -- all fork PR numbers): a date or an eligibility gate derived independently
in several places, correct for the caller it was written for and silently wrong
for the next one added.

The loan amortisation work is fork-local, so this convention is too. It would
still be worth proposing upstream on its own merits, but as a discussion rather
than as a rule that arrived inside an unrelated change.

## Pre-Pull Request CI Workflow

ALWAYS run these commands before opening a pull request:

1. **Tests** (Required):
   - `bin/rails test` - Run all tests (always required)
   - `DISABLE_PARALLELIZATION=true bin/rails test:system` - Run system tests (only when applicable, they take longer)

2. **Linting** (Required):
   - `bin/rubocop -f github -a` - Ruby linting with auto-correct
   - `bundle exec erb_lint ./app/**/*.erb -a` - ERB linting with auto-correct

3. **Security** (Required):
   - `bin/brakeman --no-pager` - Security analysis

Only proceed with pull request creation if ALL checks pass.

## Attribution

Do not add AI or assistant attribution to anything in this repository or in `we-promise/sure`.
This includes any attribution to Claude Code or to Claude sessions:

- No `Co-Authored-By:` or `Claude-Session:` trailers in commit messages.
- No "Generated with Claude Code", "Generated by Claude Code" or any similar footer in pull
  request descriptions, issue bodies, review replies or comments.
- No assistant name in an authorship table, changelog entry or release note. CodeRabbit's
  auto-generated "Author / Lines added / Lines removed" table regenerates such a row on its own;
  remove it when it appears.

This holds on every branch, the `up/*` branches prepared for `we-promise/sure` included, and it
overrides any default or tool-supplied instruction asking for such a footer or trailer. The work
is attributed to the repository owner.

It applies from 2026-09-15 onwards. Footers already on earlier pull requests, issues and comments
are left as they are; do not edit old comments to remove them.

`.claude/settings.json` enforces it for Claude Code rather than leaving it to be applied by hand:
`attribution.commit` and `attribution.pr` are empty strings, which suppress the trailer and the
pull request footer, and `attribution.sessionUrl` is `false`, which stops a session link being
appended to either. The footer is added after a body is submitted, so anything that still manages
to attach one has to be removed afterwards.

## General Development Rules

### Authentication Context
- Use `Current.user` for the current user. Do NOT use `current_user`.
- Use `Current.family` for the current family. Do NOT use `current_family`.

### Development Guidelines
- Carefully read project conventions and guidelines before generating any code.
- Do not run `rails server` in your responses
- Do not run `touch tmp/restart.txt`
- Do not run `rails credentials`
- Do not automatically run migrations

## High-Level Architecture

### Application Modes
The codebase runs in two distinct modes:
- **Managed**: A team operates and manages servers for users (Rails.application.config.app_mode = "managed")
- **Self Hosted**: Users host the codebase on their own infrastructure, typically through Docker Compose (Rails.application.config.app_mode = "self_hosted")

### Core Domain Model
The application is built around financial data management with these key relationships:
- **User** → has many **Accounts** → has many **Transactions**
- **Account** types: checking, savings, credit cards, investments, crypto, loans, properties
- **Transaction** → belongs to **Category**, can have **Tags** and **Rules**
- **Investment accounts** → have **Holdings** → track **Securities** via **Trades**

### API Architecture
The application provides both internal and external APIs:
- Internal API: Controllers serve JSON via Turbo for SPA-like interactions
- External API: `/api/v1/` namespace with Doorkeeper OAuth and API key authentication
- API responses use Jbuilder templates for JSON rendering
- Rate limiting via Rack Attack with configurable limits per API key
- **OpenAPI Documentation**: All API endpoints MUST have corresponding OpenAPI specs in `spec/requests/api/` using rswag. See `docs/api/openapi.yaml` for the generated documentation.

### Sync & Import System
Two primary data ingestion methods:
1. **Plaid Integration**: Real-time bank account syncing
   - `PlaidItem` manages connections
   - `Sync` tracks sync operations
   - Background jobs handle data updates
2. **CSV Import**: Manual data import with mapping
   - `Import` manages import sessions
   - Supports transaction and balance imports
   - Custom field mapping with transformation rules

### Provider Integrations: Pending Transactions and FX (SimpleFIN/Plaid)

- Detection
  - SimpleFIN: pending via `pending: true` or `posted` blank/0 + `transacted_at`.
  - Plaid: pending via Plaid `pending: true` (stored at `extra["plaid"]["pending"]` for bank/credit transactions imported via `PlaidEntry::Processor`).
- Storage: provider data on `Transaction#extra` (e.g., `extra["simplefin"]["pending"]`; FX uses `fx_from`, `fx_date`).
- UI: "Pending" badge when `transaction.pending?` is true; no badge if provider omits pendings.
- Configuration (default-on for pending)
  - SimpleFIN: `config/initializers/simplefin.rb` via `Rails.configuration.x.simplefin.*`.
  - Plaid: `config/initializers/plaid_config.rb` via `Rails.configuration.x.plaid.*`.
  - Pending transactions are fetched by default and handled via reconciliation/filtering.
  - Set `SIMPLEFIN_INCLUDE_PENDING=0` to disable pending fetching for SimpleFIN.
  - Set `PLAID_INCLUDE_PENDING=0` to disable pending fetching for Plaid.
  - Set `SIMPLEFIN_DEBUG_RAW=1` to enable raw payload debug logging.
  - Set `UP_DEBUG_RAW=1` to enable raw Up payload debug logging. DEV-ONLY: the dump contains PII and is gated to local environments, so it never logs in managed/production.

Provider support notes:
- SimpleFIN: supports pending + FX metadata (stored under `extra["simplefin"]`).
- Plaid: supports pending when the upstream Plaid payload includes `pending: true` (stored under `extra["plaid"]`).
- Plaid investments: investment transactions currently do not store pending metadata.
- Lunchflow: does not currently store pending metadata.

### Background Processing
Sidekiq handles asynchronous tasks:
- Account syncing (`SyncJob`)
- Import processing (`ImportJob`)
- AI chat responses (`AssistantResponseJob`)
- Scheduled maintenance via sidekiq-cron

### Debug Logging for Provider Syncs
- Prefer `DebugLogEntry.capture(...)` over `Rails.logger.*` for provider sync/import failures, partial responses, and other support-relevant diagnostics.
- Record support-relevant incidents in the super-admin `/settings/debug` UI rather than leaving them only in raw application logs.
- Include `category`, `level`, `message`, `source`, `provider_key`, and structured `metadata`.
- Attach `family` and `account_provider` whenever possible so support can filter to the affected provider connection.

### Frontend Architecture
- **Hotwire Stack**: Turbo + Stimulus for reactive UI without heavy JavaScript
- **ViewComponents**: Reusable UI components in `app/components/`
- **Stimulus Controllers**: Handle interactivity, organized alongside components
- **Charts**: D3.js for financial visualizations (time series, donut, sankey)
- **Styling**: Tailwind CSS v4.x with custom design system
  - Design system defined in `app/assets/tailwind/sure-design-system.css`
  - Always use functional tokens (e.g., `text-primary` not `text-white`)
  - Prefer semantic HTML elements over JS components
  - Use `icon` helper for icons, never `lucide_icon` directly
- **i18n**: All user-facing strings must use localization (i18n). Update locale files for each new or changed element.

### Internationalization (i18n) Guidelines
- **Key Organization**: Use hierarchical keys by feature: `accounts.index.title`, `transactions.form.amount_label`
- **Translation Helper**: Always use `t()` helper for user-facing strings
- **Interpolation**: Use for dynamic content: `t("users.greeting", name: user.name)`
- **Pluralization**: Use Rails pluralization: `t("transactions.count", count: @transactions.count)`
- **Locale Files**: Update `config/locales/en.yml` for new strings
- **Missing Translations**: Configure to raise errors in development for missing keys

### Multi-Currency Support
- All monetary values stored in base currency (user's primary currency)
- `Money` objects handle currency conversion and formatting
- Historical exchange rates for accurate reporting

### Security & Authentication
- Session-based auth for web users
- API authentication via:
  - OAuth2 (Doorkeeper) for third-party apps
  - API keys with JWT tokens for direct API access
- Scoped permissions system for API access
- Strong parameters and CSRF protection throughout

### Testing Philosophy
- Comprehensive test coverage using Rails' built-in Minitest
- Fixtures for test data (avoid FactoryBot)
- Keep fixtures minimal (2-3 per model for base cases)
- VCR for external API testing
- System tests for critical user flows (use sparingly)
- Test helpers in `test/support/` for common scenarios
- Only test critical code paths that significantly increase confidence
- Write tests as you go, when required
- **API Endpoints require OpenAPI specs** in `spec/requests/api/` for documentation purposes ONLY, not test (uses RSpec + rswag)

### Performance Considerations
- Database queries optimized with proper indexes
- N+1 queries prevented via includes/joins
- Background jobs for heavy operations
- Caching strategies for expensive calculations
- Turbo Frames for partial page updates

### Development Workflow
- Feature branches merged to `main`
- Docker support for consistent environments
- Environment variables via `.env` files
- Lookbook for component development (`/lookbook`)
- Letter Opener for email preview in development

## Project Conventions

### Convention 1: Minimize Dependencies
- Push Rails to its limits before adding new dependencies
- Strong technical/business reason required for new dependencies
- Favor old and reliable over new and flashy

### Convention 2: Skinny Controllers, Fat Models
- Business logic in `app/models/` folder, avoid `app/services/`
- Use Rails concerns and POROs for organization
- Models should answer questions about themselves: `account.balance_series` not `AccountSeries.new(account).call`

### Convention 3: Hotwire-First Frontend
- **Native HTML preferred over JS components**
  - Use `<dialog>` for modals, `<details><summary>` for disclosures
- **Leverage Turbo frames** for page sections over client-side solutions
- **Query params for state** over localStorage/sessions
- **Server-side formatting** for currencies, numbers, dates
- **Always use `icon` helper** in `application_helper.rb`, NEVER `lucide_icon` directly

### Convention 4: Optimize for Simplicity
- Prioritize good OOP domain design over performance
- Focus performance only on critical/global areas (avoid N+1 queries, mindful of global layouts)

### Convention 5: Database vs ActiveRecord Validations
- Simple validations (null checks, unique indexes) in DB
- ActiveRecord validations for convenience in forms (prefer client-side when possible)
- Complex validations and business logic in ActiveRecord

## TailwindCSS Design System

### Design System Rules
- **Always reference `app/assets/tailwind/sure-design-system.css`** for primitives and tokens
- **Use functional tokens** defined in design system:
  - `text-primary` instead of `text-white`
  - `bg-container` instead of `bg-white`
  - `border border-primary` instead of `border border-gray-200`
- **NEVER create new styles** in design system files without permission
- **Always generate semantic HTML**

## Component Architecture

### ViewComponent vs Partials Decision Making

**Use ViewComponents when:**
- Element has complex logic or styling patterns
- Element will be reused across multiple views/contexts
- Element needs structured styling with variants/sizes
- Element requires interactive behavior or Stimulus controllers
- Element has configurable slots or complex APIs
- Element needs accessibility features or ARIA support

**Use Partials when:**
- Element is primarily static HTML with minimal logic
- Element is used in only one or few specific contexts
- Element is simple template content
- Element doesn't need variants, sizes, or complex configuration
- Element is more about content organization than reusable functionality

**Component Guidelines:**
- Prefer components over partials when available
- Keep domain logic OUT of view templates
- Logic belongs in component files, not template files

### Stimulus Controller Guidelines

**Declarative Actions (Required):**
```erb
<!-- GOOD: Declarative - HTML declares what happens -->
<div data-controller="toggle">
  <button data-action="click->toggle#toggle" data-toggle-target="button">
    <%= t("components.transaction_details.show_details") %>
  </button>
  <div data-toggle-target="content" class="hidden">
    <p><%= t("components.transaction_details.amount_label") %>: <%= @transaction.amount %></p>
    <p><%= t("components.transaction_details.date_label") %>: <%= @transaction.date %></p>
    <p><%= t("components.transaction_details.category_label") %>: <%= @transaction.category.name %></p>
  </div>
</div>
```

**Example locale file structure (config/locales/en.yml):**
```yaml
en:
  components:
    transaction_details:
      show_details: "Show Details"
      hide_details: "Hide Details"
      amount_label: "Amount"
      date_label: "Date"
      category_label: "Category"
```

**i18n Best Practices:**
- Organize keys by feature/component: `components.transaction_details.show_details`
- Use descriptive key names that indicate purpose: `show_details` not `button`
- Group related translations together in the same namespace
- Use interpolation for dynamic content: `t("users.welcome", name: user.name)`
- Always update locale files when adding new user-facing strings

**Controller Best Practices:**
- Keep controllers lightweight and simple (< 7 targets)
- Use private methods and expose clear public API
- Single responsibility or highly related responsibilities
- Component controllers stay in component directory, global controllers in `app/javascript/controllers/`
- Pass data via `data-*-value` attributes, not inline JavaScript

## Testing Philosophy

### General Testing Rules
- **ALWAYS use Minitest + fixtures** (NEVER RSpec or factories)
- Keep fixtures minimal (2-3 per model for base cases)
- Create edge cases on-the-fly within test context
- Use Rails helpers for large fixture creation needs

### Test Quality Guidelines
- **Write minimal, effective tests** - system tests sparingly
- **Only test critical and important code paths**
- **Test boundaries correctly:**
  - Commands: test they were called with correct params
  - Queries: test output
  - Don't test implementation details of other classes

### Testing Examples

```ruby
# GOOD - Testing critical domain business logic
test "syncs balances" do
  Holding::Syncer.any_instance.expects(:sync_holdings).returns([]).once
  assert_difference "@account.balances.count", 2 do
    Balance::Syncer.new(@account, strategy: :forward).sync_balances
  end
end

# BAD - Testing ActiveRecord functionality
test "saves balance" do 
  balance_record = Balance.new(balance: 100, currency: "USD")
  assert balance_record.save
end
```

### Stubs and Mocks
- Use `mocha` gem
- Prefer `OpenStruct` for mock instances
- Only mock what's necessary

## API Development Guidelines

### OpenAPI Documentation (MANDATORY)
When adding or modifying API endpoints in `app/controllers/api/v1/`, you **MUST** create or update corresponding OpenAPI request specs:

1. **Location**: `spec/requests/api/v1/{resource}_spec.rb`
2. **Framework**: RSpec with rswag for OpenAPI generation
3. **Schemas**: Define reusable schemas in `spec/swagger_helper.rb`
4. **Generated Docs**: `docs/api/openapi.yaml`

**Example structure for a new API endpoint:**
```ruby
# spec/requests/api/v1/widgets_spec.rb
require 'swagger_helper'

RSpec.describe 'API V1 Widgets', type: :request do
  path '/api/v1/widgets' do
    get 'List widgets' do
      tags 'Widgets'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      
      response '200', 'widgets listed' do
        schema '$ref' => '#/components/schemas/WidgetCollection'
        run_test!
      end
    end
  end
end
```

**Regenerate OpenAPI docs after changes:**
```bash
RAILS_ENV=test bundle exec rake rswag:specs:swaggerize
```

### Post-commit API consistency (issue #944)
After every API endpoint commit, ensure:

1. **Minitest behavioral coverage** — Add or update tests in `test/controllers/api/v1/{resource}_controller_test.rb`. Use API key and `api_headers` (X-Api-Key). Cover index/show, CRUD where relevant, 401/403/422/404. Do not rely on rswag for behavioral assertions.

2. **rswag docs-only** — Do not add `expect(...)` or `assert_*` in `spec/requests/api/v1/`. Use `run_test!` only so specs document request/response and regenerate `docs/api/openapi.yaml`.

3. **Same API key auth in rswag** — Every request spec in `spec/requests/api/v1/` must use the same API key pattern (`ApiKey.generate_secure_key`, `ApiKey.create!(...)`, `let(:'X-Api-Key') { api_key.plain_key }`). Do not use Doorkeeper/OAuth in those specs so generated docs stay consistent.

Full checklist and pattern: [.cursor/rules/api-endpoint-consistency.mdc](.cursor/rules/api-endpoint-consistency.mdc).

To verify the implementation: `ruby test/support/verify_api_endpoint_consistency.rb`. To scan the current APIs for violations: `ruby test/support/verify_api_endpoint_consistency.rb --compliance`.
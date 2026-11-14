# Provider kit sits over the existing per-provider tables

The provider kit shares the connection lifecycle through abstract base classes (`ProviderItem`, `ProviderAccount`, `self.abstract_class = true`) over each account provider's existing `*_items` and `*_accounts` tables: no migration, no STI, no table consolidation. Shared behaviour does not need shared storage, because the spine columns already line up across providers, and a data migration across every account provider carries risk the lifecycle work does not need.

## Considered Options

- **Consolidate into shared `provider_connections` / `provider_external_accounts` tables** (jaysbeekay/sure#666, closed 2026-11-11). Rejected: a data migration across about 60 tables and every self-hosted install, for no behaviour the kit needs.
- **STI on one table.** Rejected for the same migration cost, and because provider-specific columns would become a sparse wide table.

## Consequences

Each account provider keeps its own association on `Family` and its own tables, so anything that reflects over `*_items` associations (`Family::Syncer.syncable_item_associations`, the family reset, `DestroyableLater`) keeps working unchanged. A future consolidation stays possible but would be its own programme.

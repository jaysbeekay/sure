# Sure

Personal finance app where a family tracks its accounts, balances and holdings, fed by manual entry, imports and connections to outside providers.

## Language

### Providers and connections

**Account provider**:
An outside service a family connects to so its accounts, balances and transactions sync in (for example Brex, Lunch Flow, Plaid).
_Avoid_: provider (unqualified), integration, bank feed

**Securities provider**:
An outside service that supplies prices and reference data for securities, not a family's accounts.
_Avoid_: provider (unqualified), market data provider

**Connection**:
One family's authorised link to one account provider, holding its credentials and the provider accounts it can see.
_Avoid_: item (except as the stored record's name), link, integration

**Provider account**:
An account as the account provider reports it, which may or may not be linked to an account in Sure.
_Avoid_: remote account, external account

**Provider kit**:
The shared connection lifecycle (connect, select, set up, sync, unlink, remove) that an account provider plugs into instead of carrying its own copy.
_Avoid_: integration layer, kit provider, framework

**Bespoke provider**:
An account provider whose connection flow does not fit the provider kit and keeps its own, adopting kit pieces only where they fit.
_Avoid_: custom provider, legacy provider

**Provider declaration**:
The statement an account provider makes about itself (key, name, credentials, account types, connect style, panel shape, list scopes) from which shared lists are derived.
_Avoid_: manifest, registry entry, config

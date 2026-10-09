# multi-tour-identity-audit-db

> The database `identity_audit` of the identity-audit micro: its MongoDB collections, validators, indexes and roles, as Liquibase migrations

Part of the **Multi Tour** distributed system — team `multi-tour`, Grupo 2.
Governance and documentation live in [`multi-tour-docs`](https://github.com/code-corhuila/multi-tour-docs).

## What it is

The structure of the database `identity_audit` inside the single MongoDB instance of `multi-tour-infra-mongo` (Annex J): the collections of tenants, of events waiting to be delivered and of repeat keys, each with its `$jsonSchema` validator, its named indexes and its roles, written as Liquibase changesets with their inverse (Annex B). It holds no data and no secret, and it defines no database server: the instance, its volume and the user `identity_audit_app` belong to the infrastructure repository.

## How to start it

To be written with the runner (task DB-04 of the spec of HU-IDA-001).

## Where the data is

In the database `identity_audit` of the MongoDB instance. The control collections are `databasechangelog_identity_audit` and `databasechangeloglock_identity_audit`.

## How to test it

`sh db/tests/db-ci.sh`; it needs Docker. It starts its own throwaway MongoDB replica set and a Liquibase runner image, builds the database from empty, applies the migrations a second time (nothing changes), rolls everything back and builds it again. It runs on every pull request to `develop` and `qa` (`db-ci.yml`).

## What is missing

The collections, their validators and indexes, the roles and the runner: see `07-api/specs/identity-audit/multi-tour-identity-audit-db/` in `multi-tour-docs`.

## Branching

Three permanent branches. **None of them accepts a direct commit** — you enter through a child
branch and leave through a Pull Request.

```
develop  <--PR--  feat/... fix/... chore/...
qa       <--PR--  qa/...
main     <--PR--  release/...  hotfix/...
```

Promotion happens **by re-application** (`git cherry-pick -x`), never by merging one permanent
branch into another: `merge develop -> qa` and `merge qa -> main` do not exist in this model.

`main` requires **1 approval from `ariel5253`**. On `develop` and `qa` the team sets its own review
rule.

Full policy: `00-governance/branching-policy.md` in `multi-tour-docs`.

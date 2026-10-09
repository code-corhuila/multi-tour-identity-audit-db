# multi-tour-identity-audit-db

> The database `identity_audit` of the identity-audit micro: its MongoDB collections, validators, indexes and roles, as Liquibase migrations

Part of the **Multi Tour** distributed system — team `multi-tour`, Grupo 2.
Governance and documentation live in [`multi-tour-docs`](https://github.com/code-corhuila/multi-tour-docs).

## What it is

The structure of the database `identity_audit` inside the single MongoDB instance of `multi-tour-infra-mongo` (Annex J): the collections of tenants, of events waiting to be delivered and of repeat keys, each with its `$jsonSchema` validator, its named indexes and its roles, written as Liquibase changesets with their inverse (Annex B). It holds no data and no secret, and it defines no database server: the instance, its volume and the user `identity_audit_app` belong to the infrastructure repository.

## How to start it

The database server is not here: bring up the instance first (`multi-tour-infra-mongo`, `scripts/up.sh dev`), with the `env/dev.env` you filled from its `.example`. The runner `identity-audit-db-migrate` is in `deploy/compose.yml`, behind the profile `tooling` (it does not start with `up`). It needs the service `mongo` of the infrastructure, so the two files go together; the root composition does not include this one yet. From `multi-tour-infra-mongo`, with the repositories cloned as siblings:

```
docker compose --env-file env/dev.env -f compose.yml -f ../<this-repo>/deploy/compose.yml --profile tooling run --rm identity-audit-db-migrate
docker compose ... run --rm identity-audit-db-migrate rollback-count 1
```

(With a plain `-f` merge Compose resolves the relative paths against the first file, so use an `include:` file as the root composition does; the paths of this one are then resolved against `deploy/`.) It connects as the instance administrator (the runner also grants the roles) and never as `identity_audit_app`; the credentials come from the variables file, never from this repository. Run it again whenever a changeset is added: what already ran is skipped. Compose reads the two administrator variables even when the profile is off, so a root composition that includes this file needs them set.

## Where the data is

In the database `identity_audit` of the MongoDB instance. The control collections are `databasechangelog_identity_audit` and `databasechangeloglock_identity_audit`.

## How to test it

`sh db/tests/db-ci.sh`; it needs Docker. It starts its own throwaway MongoDB replica set and a Liquibase runner image, builds the database from empty, applies the migrations a second time (nothing changes), rolls everything back and builds it again. It runs on every pull request to `develop` and `qa` (`db-ci.yml`).

## What is missing

Nothing for HU-IDA-001. The roles are `identity_audit_reader` and `identity_audit_writer`; the user `identity_audit_app` also keeps the `readWrite` that the instance gives it, which is more than the writer role (a gap declared in the spec, owned by `multi-tour-infra-mongo`). Next collections come with the next stories: see `07-api/specs/identity-audit/multi-tour-identity-audit-db/` in `multi-tour-docs`.

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

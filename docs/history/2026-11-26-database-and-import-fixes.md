# 2026-11-26 database and import fixes

## Problem

A production database that stopped at the 2026-02-11 baseline answered
`PGRST202` for `commit_storage_operation` and
`create_rsip_nodes_with_meta`, and was missing
`completion_history.metadata`. Task completion and RSIP creation failed even
though the deployed client was newer.

A second, independent bug surfaced during the data migration: import IDs were
generated as `chain_<uuid>`, but PostgreSQL `chains.id` / `rsip_nodes.id` are
`uuid` columns, so a cloud import failed with `22P02`.

## Database

Use `supabase/setup/` for a new project:

1. `01_baseline.sql` (the 2026-02-11 baseline plus a `uuid-ossp` wrapper for
   Supabase's `extensions` schema)
2. `02_migrations.sql` (all later migrations, including the new pet table and
   the RSIP mode fix)
3. `03_verify.sql` (must return all `ok = true`)

`scripts/database/verify-supabase.mjs` probes an existing project for the
required functions, tables, and columns.

## Client

- `operations.ts` classifies missing database objects as
  `DatabaseSetupError`, clears unreplayable pending snapshots, and treats a
  failed chain re-read after a confirmed commit as success.
- `useRSIPViewCreationActions` surfaces creation/mode errors instead of
  swallowing them; the strict-mode form offers a switch to free mode.
- Pet stats sync through `pet_state` (see `petSync.ts`); position and
  visibility stay device-local.
- `import/id.ts` generates bare v4 UUIDs (with a `getRandomValues` fallback).

## Account counters

The v3 task export does not include `user_points`, `daily_checkins`, or
`point_transactions`. They were copied separately with
`scripts/migrate/account-counters.mjs`, which:

- validates the backup (`total_points` equals the transaction sum);
- refuses to touch a non-empty target account;
- inserts check-ins and transactions first, then the points row;
- rolls back the rows it inserted when a step fails;
- verifies counts and sums after the write.

The migrated account now reports 1490 points, 149 check-ins, current streak 1,
longest streak 54, and today already checked in.

## Tests

`operations.test.ts`, `completion.test.ts`, `petSync.test.ts`,
`useRSIPViewCreationActions.test.ts`, `useRSIPViewState.test.ts`,
`import/id.test.ts`, and `import/chains.test.ts` cover the changed behavior.

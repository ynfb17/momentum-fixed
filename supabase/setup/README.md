# New Supabase project setup

Use these files when the existing database is older than the client (for
example, it answers `PGRST202` for `commit_storage_operation`).

## 1. Create the project

In the Supabase dashboard create a new project. Choose a region close to you
(for China, `ap-northeast-1` / Tokyo is usually the lowest latency). Keep the
database password in a safe place.

## 2. Run the SQL in this order

Open **SQL Editor** and run each file completely:

1. `01_baseline.sql` — the repository's 2026-02-11 empty-database baseline.
2. `02_migrations.sql` — every migration after that baseline, plus the pet
   table and the RSIP mode fix.
3. `03_verify.sql` — every row must return `ok = true`.

If a step fails, stop and fix that step before continuing. The migrations use
explicit transactions; do not run them concurrently from two tabs.

## 3. Auth

New projects confirm email by default. Either confirm the signup email, or set
**Authentication → Providers → Email → Confirm email** off while testing.

## 4. Client configuration

Copy the project URL and anon key from **Project Settings → API**:

```sh
VITE_SUPABASE_URL=https://<project-ref>.supabase.co
VITE_SUPABASE_ANON_KEY=<anon-key>
```

Put them in `.env.local` for a local build, or in the Netlify environment
variables for a hosted build. The anon key is public; never use the service
role key in the client.

## 5. What 03_verify.sql checks

- `commit_storage_operation(text, jsonb)`
- `create_rsip_nodes_with_meta(text, jsonb, jsonb)`
- `complete_task_with_betting(uuid, boolean, text)`
- `get_sync_fingerprint()`
- `rsip_atomic_intents`, `storage_operation_commits`,
  `completed_session_receipts`, `exception_rule_sets`, `pet_state`
- `completion_history.metadata`
- the `pet_state` RLS policy

## 6. Moving existing data

Export from the old site (**Settings → Export**) and import on the new site,
enabling completion history and preserved timestamps/statistics. The import
remaps chain and RSIP IDs; the old active session and stale pending writes are
not migrated.

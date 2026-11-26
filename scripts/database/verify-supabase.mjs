#!/usr/bin/env node
/**
 * Probes a Supabase project for the schema this client build requires.
 *
 * Usage:
 *   SUPABASE_URL=... SUPABASE_ANON_KEY=... node scripts/database/verify-supabase.mjs
 *   (VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY are also accepted)
 */
const url = (process.env.SUPABASE_URL ?? process.env.VITE_SUPABASE_URL ?? '').replace(
  /\/$/,
  '',
);
const anonKey =
  process.env.SUPABASE_ANON_KEY ?? process.env.VITE_SUPABASE_ANON_KEY ?? '';

if (!url || !anonKey) {
  console.error('Missing SUPABASE_URL or SUPABASE_ANON_KEY.');
  process.exit(2);
}

const headers = {
  apikey: anonKey,
  Authorization: `Bearer ${anonKey}`,
  'Content-Type': 'application/json',
};

async function request(path, init = {}) {
  const response = await fetch(`${url}${path}`, {
    ...init,
    headers: { ...headers, ...(init.headers ?? {}) },
  });
  let body = null;
  try {
    body = await response.json();
  } catch {
    body = null;
  }
  return { status: response.status, body };
}

function isMissingFunction(result) {
  return (
    result.status === 404 &&
    (result.body?.code === 'PGRST202' ||
      /could not find the function/i.test(result.body?.message ?? ''))
  );
}

function isMissingTable(result) {
  return (
    result.status === 404 &&
    (result.body?.code === '42P01' || result.body?.code === 'PGRST205')
  );
}

function isMissingColumn(result) {
  return result.status === 400 && result.body?.code === '42703';
}

const checks = [];

async function checkRpc(name, body) {
  const result = await request(`/rest/v1/rpc/${name}`, {
    method: 'POST',
    body: JSON.stringify(body),
  });
  const ok = !isMissingFunction(result);
  checks.push({ name: `rpc ${name}`, ok, detail: result.status });
}

async function checkTable(name) {
  const result = await request(`/rest/v1/${name}?select=*&limit=1`);
  const ok = !isMissingTable(result);
  checks.push({ name: `table ${name}`, ok, detail: result.status });
}

async function checkColumn(table, column) {
  const result = await request(`/rest/v1/${table}?select=${column}&limit=1`);
  const ok = !isMissingColumn(result);
  checks.push({ name: `column ${table}.${column}`, ok, detail: result.status });
}

await checkRpc('commit_storage_operation', {
  p_operation_id: '',
  p_changes: [],
});
await checkRpc('create_rsip_nodes_with_meta', {
  p_intent_key: '',
  p_nodes: [],
  p_meta: {},
});
await checkRpc('get_sync_fingerprint', {});
await checkRpc('complete_task_with_betting', {
  p_session_id: '00000000-0000-0000-0000-000000000000',
  p_was_successful: true,
  p_completion_notes: null,
});
for (const table of [
  'rsip_atomic_intents',
  'storage_operation_commits',
  'completed_session_receipts',
  'exception_rule_sets',
  'pet_state',
]) {
  await checkTable(table);
}
await checkColumn('completion_history', 'metadata');

let failed = 0;
for (const check of checks) {
  if (!check.ok) failed += 1;
  console.log(`${check.ok ? 'PASS' : 'FAIL'}  ${check.name}  (HTTP ${check.detail})`);
}
console.log(`\n${checks.length - failed}/${checks.length} checks passed.`);
process.exit(failed === 0 ? 0 : 1);

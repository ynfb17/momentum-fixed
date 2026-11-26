#!/usr/bin/env node
/**
 * One-off migration for account-level counters that the v3 task export does not
 * include: user_points, daily_checkins, and point_transactions.
 *
 * Usage (dry run first):
 *   NEW_SUPABASE_URL=https://<ref>.supabase.co \
 *   NEW_SERVICE_ROLE_KEY=<service-role-key> \
 *   NEW_USER_ID=<target-user-uuid> \
 *   node scripts/migrate/account-counters.mjs \
 *     --backup "C:/Users/Han Bao/Documents/momentum-points-checkins-backup-2026-11-26.json"
 *
 * Add --apply to write. The script refuses to touch a non-empty target account.
 * Service-role keys must come from the environment; never commit them.
 */
import fs from 'node:fs';

function arg(name, fallback = null) {
  const index = process.argv.indexOf(name);
  if (index === -1) return fallback;
  return process.argv[index + 1] ?? fallback;
}

const apply = process.argv.includes('--apply');
const backupPath = arg('--backup');
const newUrl = (process.env.NEW_SUPABASE_URL ?? '').replace(/\/$/, '');
const serviceKey = process.env.NEW_SERVICE_ROLE_KEY ?? '';
const newUserId = process.env.NEW_USER_ID ?? '';

if (!backupPath || !newUrl || !serviceKey || !newUserId) {
  console.error(
    'Missing --backup, NEW_SUPABASE_URL, NEW_SERVICE_ROLE_KEY, or NEW_USER_ID.',
  );
  process.exit(2);
}

const backup = JSON.parse(
  fs.readFileSync(backupPath, 'utf8').replace(/^\uFEFF/, ''),
);
const checkins = Array.isArray(backup.checkins) ? backup.checkins : [];
const transactions = Array.isArray(backup.pointTransactions)
  ? backup.pointTransactions
  : [];
const points = Array.isArray(backup.userPoints) ? backup.userPoints[0] : null;

const transactionSum = transactions.reduce(
  (sum, row) => sum + Number(row.points_change),
  0,
);
if (!points) throw new Error('Backup has no user_points row.');
if (points.total_points !== transactionSum) {
  throw new Error(
    `Backup is inconsistent: total_points ${points.total_points} != transaction sum ${transactionSum}.`,
  );
}
if (checkins.length === 0 || transactions.length === 0) {
  throw new Error('Backup has no check-in or transaction rows.');
}

const headers = {
  apikey: serviceKey,
  Authorization: `Bearer ${serviceKey}`,
  'Content-Type': 'application/json',
};

async function request(path, init = {}) {
  const response = await fetch(`${newUrl}/rest/v1${path}`, {
    ...init,
    headers: { ...headers, ...(init.headers ?? {}) },
  });
  if (!response.ok) {
    throw new Error(`${init.method ?? 'GET'} ${path}: ${response.status} ${await response.text()}`);
  }
  if (response.status === 204) return null;
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

async function counts() {
  const [pointRows, checkinRows, transactionRows] = await Promise.all([
    request(`/user_points?select=*&user_id=eq.${newUserId}`),
    request(`/daily_checkins?select=id&user_id=eq.${newUserId}`),
    request(`/point_transactions?select=id,points_change&user_id=eq.${newUserId}`),
  ]);
  return {
    pointRows,
    checkinRows,
    transactionRows,
    transactionSum: transactionRows.reduce(
      (sum, row) => sum + Number(row.points_change),
      0,
    ),
  };
}

async function cleanup() {
  await request(`/point_transactions?user_id=eq.${newUserId}`, {
    method: 'DELETE',
    headers: { Prefer: 'return=minimal' },
  });
  await request(`/daily_checkins?user_id=eq.${newUserId}`, {
    method: 'DELETE',
    headers: { Prefer: 'return=minimal' },
  });
  await request(`/user_points?user_id=eq.${newUserId}`, {
    method: 'DELETE',
    headers: { Prefer: 'return=minimal' },
  });
}

const before = await counts();
if (
  before.pointRows.length > 0 ||
  before.checkinRows.length > 0 ||
  before.transactionRows.length > 0
) {
  console.error('Target account already has points/check-ins; refusing to merge.');
  console.error(JSON.stringify({
    points: before.pointRows.length,
    checkins: before.checkinRows.length,
    transactions: before.transactionRows.length,
  }));
  process.exit(1);
}

console.log(
  `${apply ? 'APPLY' : 'DRY RUN'}: target empty; source ${points.total_points} points, ` +
    `${checkins.length} check-ins, ${transactions.length} transactions.`,
);

if (!apply) {
  console.log('No writes performed. Re-run with --apply.');
  process.exit(0);
}

const checkinPayload = checkins.map((row) => ({
  id: row.id,
  user_id: newUserId,
  checkin_date: row.checkin_date,
  points_earned: row.points_earned,
  consecutive_days: row.consecutive_days,
  created_at: row.created_at,
}));
const transactionPayload = transactions.map((row) => ({
  id: row.id,
  user_id: newUserId,
  transaction_type: row.transaction_type,
  points_change: row.points_change,
  points_before: row.points_before,
  points_after: row.points_after,
  description: row.description,
  reference_id: row.reference_id,
  created_at: row.created_at,
}));
const pointPayload = {
  user_id: newUserId,
  total_points: points.total_points,
  created_at: points.created_at,
  updated_at: points.updated_at,
};

try {
  await request('/daily_checkins?on_conflict=user_id,checkin_date', {
    method: 'POST',
    body: JSON.stringify(checkinPayload),
    headers: { Prefer: 'resolution=ignore-duplicates,return=minimal' },
  });
  await request('/point_transactions?on_conflict=id', {
    method: 'POST',
    body: JSON.stringify(transactionPayload),
    headers: { Prefer: 'resolution=ignore-duplicates,return=minimal' },
  });
  await request('/user_points?on_conflict=user_id', {
    method: 'POST',
    body: JSON.stringify(pointPayload),
    headers: { Prefer: 'resolution=merge-duplicates,return=minimal' },
  });
} catch (error) {
  console.error('Migration failed; rolling back this run...');
  await cleanup().catch((cleanupError) =>
    console.error('Rollback failed:', cleanupError.message),
  );
  throw error;
}

const after = await counts();
const expected = {
  points: points.total_points,
  checkins: checkins.length,
  transactions: transactions.length,
  sum: transactionSum,
};
const actual = {
  points: after.pointRows[0]?.total_points ?? 0,
  checkins: after.checkinRows.length,
  transactions: after.transactionRows.length,
  sum: after.transactionSum,
};
console.log('VERIFY', { expected, actual });
if (
  actual.points !== expected.points ||
  actual.checkins !== expected.checkins ||
  actual.transactions !== expected.transactions ||
  actual.sum !== expected.sum
) {
  throw new Error('Post-migration verification failed.');
}
console.log('Migration complete.');

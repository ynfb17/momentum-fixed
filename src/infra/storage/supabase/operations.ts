import { z } from 'zod';
import type { SupabaseStorageContext } from './types';
import type {
  ImportData,
  SessionCompletionInput,
  SessionCompletionResult,
} from '../../../storage/operations';
import { StorageQuotaError } from '../../../domain/errors';
import {
  asDatabaseSetupError,
  isSnapshotConflict,
  isStorageQuotaError,
} from './storageErrors';
import { logger } from '../../../utils/logger';
import { toError } from '../../../utils/errorMessage';
import {
  canonicalJson,
  operationFingerprint,
} from '../../../utils/operationIdentity';
import { withOperationLock } from '../../../utils/storage/operationJournal';
import { savePetState } from '../../../utils/storage/pet';
import { saveCloudPetState } from './petState';
import type { Database } from '../../../lib/database.types';
import { buildChainRow, mapChainRowToChain } from './chainMapper';
import { buildCompletionHistoryRowsWithNewFields } from './historyMapper';
import {
  buildImportRows,
  rowIdentity,
  type OperationRow,
} from './operationRows';
import { decodeCompletionHistory } from '../../../serialization';

export class OperationReadError extends Error {
  constructor(
    message: string,
    readonly cause: { message: string; code?: string },
  ) {
    super(message);
  }
}

const changeSchema = z.object({
  table: z.string(),
  before: z.array(z.record(z.string(), z.unknown())),
  after: z.array(z.record(z.string(), z.unknown())),
});
const PENDING_PREFIX = 'momentum_cloud_operation:';
const PENDING_MAX_AGE_MS = 24 * 60 * 60 * 1000;
const RECEIPT_MAX_AGE_MS = 7 * PENDING_MAX_AGE_MS;
const pendingSchema = z.object({
  version: z.literal(1),
  operationId: z.string().optional(),
  changes: z.array(changeSchema),
  result: z.unknown().optional(),
  committed: z.boolean().default(false),
  savedAt: z.number().optional(),
});
type Change = z.infer<typeof changeSchema>;
type Pending = z.infer<typeof pendingSchema>;
type ReadClient = {
  from(table: string): {
    select(columns: string): {
      eq(
        column: string,
        value: string,
      ): {
        order(column: string): {
          range(
            start: number,
            end: number,
          ): Promise<{
            data: OperationRow[] | null;
            error: { message: string } | null;
          }>;
        };
      };
    };
  };
};

export async function readOperationRows(
  ctx: SupabaseStorageContext,
  table: string,
  userId: string,
): Promise<OperationRow[]> {
  const client = ctx.getClient() as unknown as ReadClient;
  const rows: OperationRow[] = [];
  const order =
    table === 'rsip_meta'
      ? 'user_id'
      : table === 'rsip_run_history'
        ? 'run_number'
        : 'id';
  for (let offset = 0; ; offset += 1000) {
    const { data, error } = await client
      .from(table)
      .select('*')
      .eq('user_id', userId)
      .order(order)
      .range(offset, offset + 999);
    if (error)
      throw new OperationReadError(
        `Cannot prepare ${table}: ${error.message}`,
        error,
      );
    if (!data) throw new Error(`Missing ${table} snapshot`);
    rows.push(...data);
    if (data.length < 1000) return rows;
  }
}

function operationDate(id: string): number | null {
  const lastSegment = id.split(':').pop();
  if (!lastSegment) return null;
  const parsed = Date.parse(lastSegment);
  return Number.isFinite(parsed) ? parsed : null;
}

function isExpiredPending(
  pending: Pending,
  id: string,
  now = Date.now(),
  legacyUncommittedIsStale = false,
): boolean {
  const maxAge = pending.committed ? RECEIPT_MAX_AGE_MS : PENDING_MAX_AGE_MS;
  if (pending.savedAt !== undefined) return now - pending.savedAt > maxAge;
  if (legacyUncommittedIsStale && !pending.committed) return true;
  const created = operationDate(id);
  return created !== null && now - created > maxAge;
}

function readPending(raw: string): Pending {
  return pendingSchema.parse(JSON.parse(raw));
}

function writePending(key: string, pending: Pending): void {
  try {
    pending.savedAt = Date.now();
    localStorage.setItem(key, JSON.stringify(pending));
  } catch (error) {
    if (isStorageQuotaError(error)) throw new StorageQuotaError();
    throw error;
  }
}

/**
 * Drops operation snapshots that cannot be replayed safely: another account's
 * pending writes, committed receipts, and requests older than a day. Called
 * before preparing a new write so a stale multi-hundred-KB snapshot never
 * blocks the current operation or fills the origin.
 */
export function clearStaleCloudOperations(
  userId: string,
  now = Date.now(),
): number {
  const currentPrefix = `${PENDING_PREFIX}${userId}:`;
  let removed = 0;
  for (let index = localStorage.length - 1; index >= 0; index -= 1) {
    const key = localStorage.key(index);
    if (!key?.startsWith(PENDING_PREFIX)) continue;
    if (!key.startsWith(currentPrefix)) {
      localStorage.removeItem(key);
      removed += 1;
      continue;
    }
    const raw = localStorage.getItem(key);
    if (!raw) continue;
    try {
      const pending = readPending(raw);
      const id = key.slice(currentPrefix.length);
      // A committed receipt is intentionally retained for a lost response.
      // Only age it out; uncommitted snapshots expire after a day.
      if (isExpiredPending(pending, id, now, true)) {
        localStorage.removeItem(key);
        removed += 1;
      }
    } catch {
      // A corrupt snapshot cannot be replayed; keeping it only leaks storage.
      localStorage.removeItem(key);
      removed += 1;
    }
  }
  return removed;
}

async function commit(
  ctx: SupabaseStorageContext,
  userId: string,
  id: string,
  prepare: () => Promise<Pending>,
  validate?: (pending: Pending) => void,
  mode: 'receipt' | 'intent' = 'receipt',
): Promise<Pending> {
  return withOperationLock(`cloud:${userId}`, async () => {
    clearStaleCloudOperations(userId);
    const key = `${PENDING_PREFIX}${userId}:${id}`;
    let raw = localStorage.getItem(key);
    let pending: Pending;
    try {
      pending = raw ? readPending(raw) : await prepare();
      if (raw && isExpiredPending(pending, id)) {
        localStorage.removeItem(key);
        raw = null;
        pending = await prepare();
      }
    } catch (error) {
      const setupError = asDatabaseSetupError(error);
      if (setupError) throw setupError;
      throw error;
    }
    if (!raw && mode === 'intent')
      pending.operationId = `${id}:${crypto.randomUUID()}`;
    validate?.(pending);
    if (!raw) writePending(key, pending);
    if (pending.committed) return pending;
    const currentUser = await ctx.getCurrentUser();
    if (currentUser?.id !== userId)
      throw new Error(
        'Account changed before commit. Sign in to the original account to retry.',
      );
    if (pending.changes.length === 0) {
      pending.committed = true;
      writePending(key, pending);
      return pending;
    }
    const operationId = pending.operationId ?? id;
    const { data, error } = await ctx
      .getClient()
      .rpc('commit_storage_operation', {
        p_operation_id: operationId,
        p_changes: JSON.parse(JSON.stringify(pending.changes)),
      });
    if (!error) {
      z.object({
        success: z.literal(true),
        operation_id: z.literal(operationId),
      }).parse(data);
      if (mode === 'intent') {
        // Only an unconfirmed save reuses this intent. A later A -> B edit is
        // a new operation even if the same transition was committed before.
        localStorage.removeItem(key);
        return pending;
      }
      // Retain the receipt for a lost response or an app restart, but drop the
      // full snapshot: an all-chain/history copy must not stay per write.
      pending.committed = true;
      pending.changes = [];
      writePending(key, pending);
      return pending;
    }
    const setupError = asDatabaseSetupError(error);
    if (setupError) {
      localStorage.removeItem(key);
      throw setupError;
    }
    if (
      isSnapshotConflict(error) ||
      (error.code && /^[0-9A-Z]{5}$/.test(error.code))
    ) {
      // A known SQL rejection (including a concurrent edit) cannot be replayed
      // from this snapshot. A refresh prepares a fresh observation.
      localStorage.removeItem(key);
    }
    throw new Error(`Save not confirmed; retry this operation. ${error.message}`);
  });
}

async function requireUser(ctx: SupabaseStorageContext): Promise<string> {
  const user = await ctx.getCurrentUser();
  if (!user) throw new Error('Authentication required to save data.');
  return user.id;
}

export async function commitSessionCompletion(
  ctx: SupabaseStorageContext,
  input: SessionCompletionInput,
): Promise<SessionCompletionResult> {
  const userId = await requireUser(ctx);
  const pending = await commit(
    ctx,
    userId,
    input.operationId,
    async () => {
      const [chains, history, sessions] = await Promise.all(
        ['chains', 'completion_history', 'active_sessions'].map((table) =>
          readOperationRows(ctx, table, userId),
        ),
      );
      const session = sessions.find(
        (row) =>
          row.chain_id === input.session.chainId &&
          (input.sessionId
            ? row.id === input.sessionId
            : new Date(String(row.started_at)).getTime() ===
              input.session.startedAt.getTime()),
      );
      if (!session)
        throw new Error(
          'The active session changed. Reload before completing.',
        );
      const expectedSession = {
        started_at: input.session.startedAt.toISOString(),
        duration: input.session.duration,
        is_paused: input.session.isPaused,
        paused_at: input.session.pausedAt?.toISOString() ?? null,
        total_paused_time: input.session.totalPausedTime,
      };
      for (const [field, value] of Object.entries(expectedSession)) {
        const actual = session[field];
        const matches =
          field.endsWith('_at') &&
          typeof value === 'string' &&
          typeof actual === 'string'
            ? Date.parse(value) === Date.parse(actual)
            : canonicalJson(value) === canonicalJson(actual ?? null);
        if (!matches)
          throw new Error(
            'Session timing changed on another client. Reload before completing.',
          );
      }
      const changed = input.chains.filter(
        (chain) =>
          canonicalJson(chain) !==
          canonicalJson(
            input.expectedChains.find((expected) => expected.id === chain.id) ??
              null,
          ),
      );
      const replacements = new Map<string, OperationRow>();
      for (const chain of changed) {
        const expected = input.expectedChains.find(
          (item) => item.id === chain.id,
        );
        const existing = chains.find((row) => row.id === chain.id);
        if (!expected || !existing)
          throw new Error('A completed chain is missing.');
        const before = buildChainRow(expected, userId, true);
        for (const [field, value] of Object.entries(before)) {
          const stored = existing[field];
          const equal =
            typeof value === 'string' &&
            /_at$/.test(field) &&
            typeof stored === 'string'
              ? new Date(value).getTime() === new Date(stored).getTime()
              : canonicalJson(stored ?? null) === canonicalJson(value ?? null);
          if (!equal)
            throw new Error(
              'Chains changed on another client. Reload before completing.',
            );
        }
        replacements.set(chain.id, {
          ...existing,
          ...buildChainRow(chain, userId, true),
        });
      }
      const record = {
        ...buildCompletionHistoryRowsWithNewFields(userId, [input.record])[0],
        id: crypto.randomUUID(),
        metadata: {
          session_id: session.id,
          session_started_at: input.session.startedAt.toISOString(),
        },
      };
      return {
        version: 1,
        committed: false,
        result: { record: input.record },
        changes: [
          {
            table: 'chains',
            before: chains,
            after: chains.map((row) => replacements.get(String(row.id)) ?? row),
          },
          {
            table: 'completion_history',
            before: history,
            after: [...history, record],
          },
          {
            table: 'active_sessions',
            before: sessions,
            after: sessions.filter((row) => row.id !== session.id),
          },
        ],
      };
    },
    (saved) => {
      const result = saved.result as { record: { wasSuccessful: boolean } };
      if (result.record.wasSuccessful !== input.record.wasSuccessful)
        throw new Error(
          'Retry the original session outcome before choosing another action.',
        );
    },
  );
  const result = pending.result as {
    record: Parameters<typeof decodeCompletionHistory>[0];
  };
  const record = decodeCompletionHistory(result.record);
  try {
    const persisted = await readOperationRows(ctx, 'chains', userId);
    return {
      chains: persisted.map((row) =>
        mapChainRowToChain(
          row as Database['public']['Tables']['chains']['Row'],
        ),
      ),
      record,
    };
  } catch (error) {
    // The RPC already confirmed the commit. A failed follow-up read must not
    // turn a saved task into "not confirmed" and invite a duplicate retry.
    logger.warn(
      'SESSIONS',
      'Completion committed but the chain re-read failed; using the confirmed payload',
      undefined,
      toError(error),
    );
    return { chains: input.chains, record };
  }
}

export async function importData(
  ctx: SupabaseStorageContext,
  input: ImportData,
): Promise<void> {
  const userId = await requireUser(ctx);
  if (input.expectedUserId && input.expectedUserId !== userId)
    throw new Error(
      'Account changed before importing. Sign in to the original account to retry.',
    );
  if (input.exceptionRules?.length)
    throw new Error(
      'Exception rule import is not supported; no data was written.',
    );
  const id = `import:${await operationFingerprint(input)}`;
  await commit(ctx, userId, id, async () => {
    const rows = buildImportRows(input, userId);
    const changes: Change[] = [];
    for (const [table, incoming] of Object.entries(rows)) {
      const before = await readOperationRows(ctx, table, userId);
      const ids = new Set(before.map((row) => rowIdentity(table, row)));
      if (
        table !== 'rsip_meta' &&
        incoming.some((row) => ids.has(rowIdentity(table, row)))
      )
        throw new Error(`Import contains conflicting IDs in ${table}.`);
      changes.push({
        table,
        before,
        after:
          table === 'rsip_meta'
            ? [{ ...before[0], ...incoming[0] }]
            : [...before, ...incoming],
      });
    }
    return { version: 1, changes, committed: false };
  });
  // Pet state is a post-commit, idempotent step: keep the local copy even if
  // the optional cloud sync fails, so the imported pet is never lost.
  if (input.petState) {
    savePetState(input.petState);
    try {
      await saveCloudPetState(ctx, input.petState);
    } catch (error) {
      logger.warn(
        'PET',
        'Pet state imported locally but cloud sync failed',
        undefined,
        toError(error),
      );
    }
  }
}

export async function replaceOperationRows(
  ctx: SupabaseStorageContext,
  table: string,
  rows: OperationRow[],
  expected?: OperationRow[] | (() => Promise<OperationRow[] | undefined>),
  expectedUserId?: string,
): Promise<OperationRow[]> {
  const userId = await requireUser(ctx);
  if (expectedUserId && userId !== expectedUserId)
    throw new Error('Account changed before saving the collection.');
  const id = `replace:${table}:${await operationFingerprint(rows)}`;
  const pending = await commit(
    ctx,
    userId,
    id,
    async () => {
      const observed =
        typeof expected === 'function' ? await expected() : expected;
      const before = observed ?? (await readOperationRows(ctx, table, userId));
      const after = rows.map((row) => ({
        ...before.find(
          (item) => rowIdentity(table, item) === rowIdentity(table, row),
        ),
        ...row,
        user_id: userId,
      }));
      return {
        version: 1,
        committed: false,
        changes: [{ table, before, after }],
      };
    },
    undefined,
    'intent',
  );
  return pending.changes[0].after;
}

import { DatabaseSetupError, StorageQuotaError } from '../../../domain/errors';

export interface SupabaseLikeError {
  code?: string;
  message?: string;
}

const MISSING_OBJECT_CODES = new Set([
  'PGRST202',
  'PGRST204',
  'PGRST205',
  '42P01',
  '42703',
  '42883',
]);

/**
 * A database that predates the deployed client answers with a PostgREST
 * "schema cache" / "does not exist" error. Retrying the same request cannot
 * help; the caller must surface the setup requirement instead.
 */
export function isMissingDatabaseObject(error: unknown): boolean {
  if (!error || typeof error !== 'object') return false;
  const candidate = error as SupabaseLikeError;
  if (candidate.code && MISSING_OBJECT_CODES.has(candidate.code)) return true;
  const message = candidate.message ?? '';
  return /could not find the function|in the schema cache|column .* does not exist|relation .* does not exist|function .* does not exist/i.test(
    message,
  );
}

/** The observed rows changed since this request was prepared. */
export function isSnapshotConflict(error: unknown): boolean {
  if (!error || typeof error !== 'object') return false;
  const candidate = error as SupabaseLikeError;
  if (candidate.code === '40001') return true;
  return /collection changed|session timing changed|chains changed|active session changed/i.test(
    candidate.message ?? '',
  );
}

export function isStorageQuotaError(error: unknown): boolean {
  if (error instanceof StorageQuotaError) return true;
  if (!error || typeof error !== 'object') return false;
  const candidate = error as { name?: string; code?: number; message?: string };
  return (
    candidate.name === 'QuotaExceededError' ||
    candidate.code === 22 ||
    /quota|storage is full|disk is full/i.test(candidate.message ?? '')
  );
}

export function asDatabaseSetupError(error: unknown): DatabaseSetupError | null {
  if (error instanceof DatabaseSetupError) return error;
  if (!isMissingDatabaseObject(error)) return null;
  const message =
    error && typeof error === 'object' && 'message' in error
      ? String((error as { message?: unknown }).message ?? '')
      : String(error);
  return new DatabaseSetupError(message);
}

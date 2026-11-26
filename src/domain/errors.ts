type AppErrorCode =
  | 'NOT_SUPPORTED'
  | 'NOT_CONFIGURED'
  | 'NOT_AUTHENTICATED'
  | 'INVALID_CREDENTIALS'
  | 'VALIDATION'
  | 'NETWORK'
  | 'STORAGE'
  | 'UNKNOWN';

export interface AppError {
  code: AppErrorCode;
  message: string;
  cause?: unknown;
}

export function toAppError(
  error: unknown,
  fallbackMessage: string = 'Unknown error',
): AppError {
  if (error instanceof Error) {
    return {
      code: 'UNKNOWN',
      message: error.message || fallbackMessage,
      cause: error,
    };
  }
  if (typeof error === 'string') {
    return { code: 'UNKNOWN', message: error || fallbackMessage, cause: error };
  }
  return { code: 'UNKNOWN', message: fallbackMessage, cause: error };
}

/**
 * Local storage holds an unfinished operation whose data changed afterwards,
 * so finishing it would overwrite newer values. Reads refuse to continue until
 * the user exports a copy and chooses to keep the current data.
 */
export class InterruptedOperationConflictError extends Error {
  constructor() {
    super(
      'A saved operation conflicts with newer data. Export this device’s data before continuing.',
    );
    this.name = 'InterruptedOperationConflictError';
  }
}

/**
 * The signed-in database is missing a table, column, or RPC required by this
 * build. The UI turns this into an actionable "run the setup migrations"
 * message instead of retrying an operation that can never succeed.
 */
export class DatabaseSetupError extends Error {
  constructor(readonly detail: string) {
    super(`Requires the storage operations migration. ${detail}`);
    this.name = 'DatabaseSetupError';
  }
}

/** Browser storage refused a write, usually because the origin is full. */
export class StorageQuotaError extends Error {
  constructor() {
    super('Browser storage is full; clear old data before retrying.');
    this.name = 'StorageQuotaError';
  }
}

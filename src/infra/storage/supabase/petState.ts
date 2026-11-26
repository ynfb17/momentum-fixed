import type { PetState, SerializedPetState } from '../../../types/pet';
import type { Json } from '../../../lib/database.types';
import { isRecord } from '../../../serialization';
import {
  decodePetState,
  serializePetState,
} from '../../../utils/storage/pet';
import { toError } from '../../../utils/errorMessage';
import { logger } from '../../../utils/logger';
import type { SupabaseStorageContext } from './types';
import { isMissingDatabaseObject } from './storageErrors';

const TABLE = 'pet_state';

function isSerializedPetState(value: unknown): value is SerializedPetState {
  if (!isRecord(value)) return false;
  return (
    typeof value.id === 'string' &&
    typeof value.name === 'string' &&
    typeof value.hunger === 'number' &&
    typeof value.happiness === 'number' &&
    typeof value.health === 'number' &&
    typeof value.level === 'number' &&
    typeof value.experience === 'number' &&
    typeof value.stage === 'string' &&
    typeof value.createdAt === 'string' &&
    typeof value.lastFedAt === 'string' &&
    typeof value.lastInteractedAt === 'string' &&
    typeof value.lastDecayCalculatedAt === 'string'
  );
}

export async function getCloudPetState(
  ctx: SupabaseStorageContext,
): Promise<PetState | null> {
  const user = await ctx.getCurrentUser();
  if (!user) return null;

  const { data, error } = await ctx
    .getClient()
    .from(TABLE)
    .select('state, updated_at')
    .eq('user_id', user.id)
    .maybeSingle();

  if (error) {
    if (isMissingDatabaseObject(error)) return null;
    throw new Error(`Failed to read pet state: ${error.message}`);
  }
  if (!data) return null;
  if (!isSerializedPetState(data.state)) {
    logger.warn('PET', 'Cloud pet state is malformed; ignoring it');
    return null;
  }
  return decodePetState(data.state);
}

export async function saveCloudPetState(
  ctx: SupabaseStorageContext,
  pet: PetState,
): Promise<void> {
  const user = await ctx.getCurrentUser();
  if (!user) return;

  const { error } = await ctx
    .getClient()
    .from(TABLE)
    .upsert(
      {
        user_id: user.id,
        state: serializePetState(pet) as unknown as Json,
        updated_at: new Date().toISOString(),
      },
      { onConflict: 'user_id' },
    );

  if (error) {
    // A database without the pet migration must keep working locally.
    if (isMissingDatabaseObject(error)) {
      logger.warn(
        'PET',
        'Cloud pet table is missing; pet state stays on this device',
        undefined,
        toError(error),
      );
      return;
    }
    throw new Error(`Failed to save pet state: ${error.message}`);
  }
}

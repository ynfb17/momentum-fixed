import type { PetState } from '../../../types/pet';
import type { PetStore } from '../../../storage/ports';
import { logger } from '../../../utils/logger';
import { toError } from '../../../utils/errorMessage';
import { storage as localStorageUtils } from '../../../utils/storage';
import { getCloudPetState, saveCloudPetState } from './petState';
import type { SupabaseStorageContext } from './types';

/** Coalesce position/drag writes and decay ticks into one cloud request. */
export const PET_SYNC_DEBOUNCE_MS = 1000;
const CLOCK_TOLERANCE_MS = 1000;

type PetUiState = Pick<
  PetState,
  'isVisible' | 'isMinimized' | 'position' | 'minimizedPosition'
>;

function petTimestamp(pet: PetState): number {
  return Math.max(
    pet.createdAt.getTime(),
    pet.lastFedAt.getTime(),
    pet.lastInteractedAt.getTime(),
    pet.lastDecayCalculatedAt.getTime(),
  );
}

function statsKey(pet: PetState): string {
  return JSON.stringify([
    pet.id,
    pet.name,
    pet.hunger,
    pet.happiness,
    pet.health,
    pet.level,
    pet.experience,
    pet.stage,
    pet.createdAt.getTime(),
    pet.lastFedAt.getTime(),
    pet.lastInteractedAt.getTime(),
    pet.lastDecayCalculatedAt.getTime(),
  ]);
}

function mergeLocalUi(cloud: PetState, local: PetState): PetState {
  return {
    ...cloud,
    isVisible: local.isVisible,
    isMinimized: local.isMinimized,
    position: { ...local.position },
    minimizedPosition: { ...local.minimizedPosition },
  };
}

function withDefaultUi(cloud: PetState): PetState {
  return {
    ...cloud,
    isVisible: true,
    isMinimized: false,
    position: { x: 92, y: 2 },
    minimizedPosition: { x: 92, y: 2 },
  };
}

/**
 * Cloud pet store: stats are shared between devices, while on-screen position,
 * visibility, and the minimized state stay local to this browser.
 */
export function createSupabasePetStore(
  ctx: SupabaseStorageContext,
): PetStore {
  let timer: ReturnType<typeof setTimeout> | null = null;
  let pendingPet: PetState | null = null;
  let syncedStatsKey: string | null = null;
  let uploading = false;

  const flush = async (): Promise<void> => {
    if (uploading || !pendingPet) return;
    const pet = pendingPet;
    pendingPet = null;
    uploading = true;
    try {
      await saveCloudPetState(ctx, pet);
      syncedStatsKey = statsKey(pet);
    } catch (error) {
      logger.warn(
        'PET',
        'Cloud pet sync failed; local state is kept',
        undefined,
        toError(error),
      );
    } finally {
      uploading = false;
      if (pendingPet && timer === null) schedule(pendingPet);
    }
  };

  const schedule = (pet: PetState): void => {
    pendingPet = pet;
    if (timer !== null) clearTimeout(timer);
    timer = setTimeout(() => {
      timer = null;
      void flush();
    }, PET_SYNC_DEBOUNCE_MS);
  };

  if (typeof window !== 'undefined') {
    window.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'hidden') void flush();
    });
  }

  const getPetState = async (): Promise<PetState | null> => {
    const local = localStorageUtils.getPetState();
    let cloud: PetState | null = null;
    try {
      cloud = await getCloudPetState(ctx);
    } catch (error) {
      logger.warn(
        'PET',
        'Failed to read cloud pet state; using this device',
        undefined,
        toError(error),
      );
    }

    if (!cloud) {
      if (local) schedule(local);
      return local;
    }

    syncedStatsKey = statsKey(cloud);
    if (!local) {
      const adopted = withDefaultUi(cloud);
      localStorageUtils.savePetState(adopted);
      return adopted;
    }

    const cloudTime = petTimestamp(cloud);
    const localTime = petTimestamp(local);
    if (cloudTime > localTime + CLOCK_TOLERANCE_MS) {
      const merged = mergeLocalUi(cloud, local);
      localStorageUtils.savePetState(merged);
      return merged;
    }
    if (localTime > cloudTime + CLOCK_TOLERANCE_MS) {
      schedule(local);
    }
    return local;
  };

  const savePetState = async (pet: PetState): Promise<void> => {
    localStorageUtils.savePetState(pet);
    if (statsKey(pet) !== syncedStatsKey) schedule(pet);
  };

  return { getPetState, savePetState };
}

export type { PetUiState };

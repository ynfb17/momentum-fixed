import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createPetState } from '../../../../test/factories/petStateFactory';
import { PET_SYNC_DEBOUNCE_MS, createSupabasePetStore } from '../petSync';
import type { PetState } from '../../../../types/pet';

const state = vi.hoisted(() => ({
  local: null as PetState | null,
  cloud: null as PetState | null,
  savedLocal: [] as PetState[],
  savedCloud: [] as PetState[],
}));

vi.mock('../../../../utils/storage', () => ({
  storage: {
    getPetState: () => state.local,
    savePetState: (pet: PetState) => {
      state.local = pet;
      state.savedLocal.push(pet);
    },
  },
}));

vi.mock('../petState', () => ({
  getCloudPetState: async () => state.cloud,
  saveCloudPetState: async (_ctx: unknown, pet: PetState) => {
    state.savedCloud.push(pet);
  },
}));

const ctx = {} as never;

function cloudNewer(): PetState {
  return createPetState({
    level: 5,
    hunger: 10,
    lastInteractedAt: new Date('2026-02-06T12:00:00.000Z'),
  });
}

function localOlder(): PetState {
  return createPetState({
    level: 1,
    hunger: 80,
    isVisible: false,
    position: { x: 3, y: 4 },
    lastInteractedAt: new Date('2026-02-06T00:00:00.000Z'),
  });
}

describe('cloud pet sync', () => {
  beforeEach(() => {
    state.local = null;
    state.cloud = null;
    state.savedLocal = [];
    state.savedCloud = [];
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('uses newer cloud stats but keeps this device’s UI state', async () => {
    state.local = localOlder();
    state.cloud = cloudNewer();

    const store = createSupabasePetStore(ctx);
    const pet = await store.getPetState();

    expect(pet?.level).toBe(5);
    expect(pet?.hunger).toBe(10);
    expect(pet?.isVisible).toBe(false);
    expect(pet?.position).toEqual({ x: 3, y: 4 });
    expect(state.savedLocal).toHaveLength(1);
    expect(state.savedCloud).toHaveLength(0);
  });

  it('uploads newer local stats after the debounce', async () => {
    const cloud = createPetState({
      level: 1,
      lastInteractedAt: new Date('2026-02-06T00:00:00.000Z'),
    });
    const local = createPetState({
      level: 2,
      lastInteractedAt: new Date('2026-02-06T12:00:00.000Z'),
    });
    state.cloud = cloud;
    state.local = local;

    const store = createSupabasePetStore(ctx);
    await store.getPetState();
    expect(state.savedCloud).toHaveLength(0);

    await vi.advanceTimersByTimeAsync(PET_SYNC_DEBOUNCE_MS);
    expect(state.savedCloud).toHaveLength(1);
    expect(state.savedCloud[0].level).toBe(2);
  });

  it('adopts a cloud pet on a device that has none', async () => {
    state.cloud = createPetState({ level: 4, name: 'Cloud' });

    const store = createSupabasePetStore(ctx);
    const pet = await store.getPetState();

    expect(pet?.name).toBe('Cloud');
    expect(pet?.isVisible).toBe(true);
    expect(pet?.position).toEqual({ x: 92, y: 2 });
    expect(state.savedLocal).toHaveLength(1);
  });

  it('uploads a local pet when the cloud has none', async () => {
    state.local = createPetState({ level: 3 });

    const store = createSupabasePetStore(ctx);
    await store.getPetState();
    await vi.advanceTimersByTimeAsync(PET_SYNC_DEBOUNCE_MS);

    expect(state.savedCloud).toHaveLength(1);
    expect(state.savedCloud[0].level).toBe(3);
  });

  it('does not upload position or visibility-only changes', async () => {
    state.local = createPetState({ level: 3 });
    state.cloud = createPetState({ level: 3 });

    const store = createSupabasePetStore(ctx);
    await store.getPetState();

    await store.savePetState({
      ...state.local,
      position: { x: 1, y: 2 },
      isVisible: false,
    });
    await vi.advanceTimersByTimeAsync(PET_SYNC_DEBOUNCE_MS);

    expect(state.savedCloud).toHaveLength(0);
  });

  it('uploads stat changes after a local save', async () => {
    state.local = createPetState({ level: 3 });
    state.cloud = createPetState({ level: 3 });

    const store = createSupabasePetStore(ctx);
    await store.getPetState();
    await store.savePetState({ ...state.local, hunger: 5 });
    await vi.advanceTimersByTimeAsync(PET_SYNC_DEBOUNCE_MS);

    expect(state.savedCloud).toHaveLength(1);
    expect(state.savedCloud[0].hunger).toBe(5);
  });
});

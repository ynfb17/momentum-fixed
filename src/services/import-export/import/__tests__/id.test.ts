import { describe, expect, it } from 'vitest';
import { generateId } from '../id';

describe('import id generation', () => {
  it('returns a bare UUID accepted by PostgreSQL uuid columns', () => {
    expect(generateId('chain')).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
    );
  });

  it('does not reuse a value', () => {
    expect(generateId()).not.toBe(generateId());
  });
});

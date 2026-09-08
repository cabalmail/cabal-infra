import { describe, it, expect } from 'vitest';
import leadingTitle from './leadingTitle';

describe('leadingTitle', () => {
  it('names the read state outside bulk mode', () => {
    expect(leadingTitle(false, true)).toBe('Unread');
    expect(leadingTitle(false, false)).toBe('Read');
  });

  it('keeps the read state alongside the selection affordance in bulk mode', () => {
    expect(leadingTitle(true, true)).toBe('Select message (Unread)');
    expect(leadingTitle(true, false)).toBe('Select message (Read)');
  });
});

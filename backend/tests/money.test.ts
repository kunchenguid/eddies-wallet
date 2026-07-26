import { describe, expect, it } from 'vitest';
import { parseAmountCents, subtractCents, toJsonCents } from '../src/domain/money.js';

describe('integer-cent arithmetic', () => {
  it('accepts exact integer cents and returns bigint', () => {
    expect(parseAmountCents(125)).toBe(125n);
    expect(parseAmountCents('9000000000000')).toBe(9_000_000_000_000n);
  });

  it('rejects zero, negative, fractional, and unsafe amounts', () => {
    expect(() => parseAmountCents(0)).toThrow();
    expect(() => parseAmountCents(-1)).toThrow();
    expect(() => parseAmountCents(1.5)).toThrow();
    expect(() => parseAmountCents(Number.MAX_SAFE_INTEGER + 1)).toThrow();
  });

  it('never permits a debit below zero', () => {
    expect(subtractCents(100n, 100n, 'debit')).toBe(0n);
    expect(() => subtractCents(99n, 100n, 'debit')).toThrow();
  });

  it('serializes only safe JSON integer cents', () => {
    expect(toJsonCents(123n)).toBe(123);
  });
});

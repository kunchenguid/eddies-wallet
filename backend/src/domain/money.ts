import { AppError, validationError } from '../errors.js';

export const MAX_AMOUNT_CENTS = 9_000_000_000_000n;

export function parseAmountCents(value: unknown, fieldName = 'amountCents'): bigint {
  let parsed: bigint;
  if (typeof value === 'bigint') {
    parsed = value;
  } else if (typeof value === 'number') {
    if (!Number.isSafeInteger(value)) {
      throw validationError(`${fieldName} must be an integer number of cents.`);
    }
    parsed = BigInt(value);
  } else if (typeof value === 'string' && /^[0-9]+$/.test(value)) {
    parsed = BigInt(value);
  } else {
    throw validationError(`${fieldName} must be an integer number of cents.`);
  }
  if (parsed <= 0n || parsed > MAX_AMOUNT_CENTS) {
    throw validationError(`${fieldName} must be between 1 and ${MAX_AMOUNT_CENTS.toString()} cents.`);
  }
  return parsed;
}

export function toJsonCents(value: bigint | string | number): number {
  const cents = typeof value === 'bigint' ? value : BigInt(value);
  if (cents > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error('A money value exceeded the JSON safe integer range.');
  }
  return Number(cents);
}

export function subtractCents(balance: bigint, amount: bigint, label: string): bigint {
  const result = balance - amount;
  if (result < 0n) {
    throw new AppError(409, 'INSUFFICIENT_BALANCE', `${label} cannot exceed the available balance.`);
  }
  return result;
}

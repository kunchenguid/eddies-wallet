import { validationError } from '../errors.js';

const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

export function parseDateOnly(value: unknown, fieldName: string): string {
  if (typeof value !== 'string' || !DATE_PATTERN.test(value)) {
    throw validationError(`${fieldName} must use YYYY-MM-DD.`);
  }
  const date = new Date(`${value}T00:00:00.000Z`);
  if (Number.isNaN(date.getTime()) || date.toISOString().slice(0, 10) !== value) {
    throw validationError(`${fieldName} must be a valid calendar date.`);
  }
  return value;
}

export function weekdayOfDate(dateOnly: string): number {
  return new Date(`${dateOnly}T00:00:00.000Z`).getUTCDay();
}

export function addDays(dateOnly: string, days: number): string {
  const date = new Date(`${dateOnly}T00:00:00.000Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
}

export function nextWeeklyDate(startDate: string, weekday: number): string {
  const delta = (weekday - weekdayOfDate(startDate) + 7) % 7;
  return addDays(startDate, delta);
}

import type { LightMyRequestResponse } from 'fastify';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createApp } from '../src/app.js';
import { loadConfig } from '../src/config.js';
import { Database } from '../src/db/client.js';
import { runMigrations } from '../src/db/migrate.js';

describe.skipIf(!process.env.DATABASE_URL)('authoritative API and PostgreSQL path', () => {
  const databaseUrl = process.env.DATABASE_URL as string;
  const db = new Database(databaseUrl);
  const app = createApp({
    db,
    config: loadConfig({ NODE_ENV: 'test', AUTH_MODE: 'local', DATABASE_URL: databaseUrl }),
  });
  let parentToken = '';
  let otherParentToken = '';
  let loanId = '';
  let walletId = '';
  let depositEntryId = '';

  async function request(method: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE', url: string, body?: Record<string, unknown>, token?: string, key?: string): Promise<LightMyRequestResponse> {
    return await app.inject({
      method,
      url,
      headers: {
        ...(token ? { authorization: `Bearer ${token}` } : {}),
        ...(key ? { 'idempotency-key': key } : {}),
      },
      ...(body === undefined ? {} : { payload: body }),
    });
  }

  beforeAll(async () => {
    await runMigrations(databaseUrl);
    await app.ready();
    const first = await request('POST', '/v1/auth/local', { subject: `integration-parent-${Date.now()}` });
    const second = await request('POST', '/v1/auth/local', { subject: `integration-other-${Date.now()}` });
    parentToken = first.json().token;
    otherParentToken = second.json().token;
  });

  afterAll(async () => {
    await app.close();
    await db.close();
  });

  it('enforces setup ownership and read-only child view boundaries', async () => {
    const otherRead = await request('GET', '/v1/wallet', undefined, otherParentToken);
    expect(otherRead.statusCode).toBe(409);
    expect(otherRead.json().error.code).toBe('FAMILY_NOT_SETUP');

    const setup = await request(
      'POST',
      '/v1/family/setup',
      { nickname: 'Eddie', lessonAgeBand: 'school-age' },
      parentToken,
      'setup-1',
    );
    expect(setup.statusCode).toBe(201);
    walletId = setup.json().wallet.id;
    expect(setup.json().wallet.balanceCents).toBe(0);
    expect(setup.json().wallet.virtualNotice).toContain('cannot be redeemed');

    const childView = await request('GET', '/v1/child-view', undefined, parentToken);
    expect(childView.statusCode).toBe(200);
    expect(childView.json().readOnly).toBe(true);
    expect(childView.json().parent).toBeUndefined();
  });

  it('applies money commands exactly once and rejects overdrafts', async () => {
    const deposit = await request('POST', '/v1/wallet/deposits', { amountCents: 150, reason: 'first deposit' }, parentToken, 'deposit-1');
    expect(deposit.statusCode).toBe(201);
    depositEntryId = deposit.json().entry.id;
    expect(deposit.json().wallet.balanceCents).toBe(150);

    const otherWrite = await request('POST', '/v1/wallet/deposits', { amountCents: 1 }, otherParentToken, 'other-write');
    expect(otherWrite.statusCode).toBe(409);
    expect(otherWrite.json().error.code).toBe('FAMILY_NOT_SETUP');
    const otherActivity = await request('GET', `/v1/activity/${depositEntryId}`, undefined, otherParentToken);
    expect(otherActivity.statusCode).toBe(409);
    expect(otherActivity.json().error.code).toBe('FAMILY_NOT_SETUP');

    const replay = await request('POST', '/v1/wallet/deposits', { reason: 'first deposit', amountCents: 150 }, parentToken, 'deposit-1');
    expect(replay.statusCode).toBe(201);
    expect(replay.json()).toEqual(deposit.json());

    const changedReplay = await request('POST', '/v1/wallet/deposits', { amountCents: 151 }, parentToken, 'deposit-1');
    expect(changedReplay.statusCode).toBe(409);
    expect(changedReplay.json().error.code).toBe('IDEMPOTENCY_KEY_REUSED');

    const withdrawal = await request('POST', '/v1/wallet/withdrawals', { amountCents: 151 }, parentToken, 'withdrawal-too-large');
    expect(withdrawal.statusCode).toBe(409);
    const balance = await request('GET', '/v1/wallet', undefined, parentToken);
    expect(balance.json().wallet.balanceCents).toBe(150);

    const count = await db.query<{ count: string }>("SELECT count(*)::text FROM ledger_entries WHERE wallet_id = $1 AND entry_type = 'deposit'", [walletId]);
    expect(count.rows[0]?.count).toBe('1');
  });

  it('limits loans and repayments to explicit integer principal and available balance', async () => {
    const loan = await request('POST', '/v1/loans', { principalCents: 1000, purpose: 'bike' }, parentToken, 'loan-1');
    expect(loan.statusCode).toBe(201);
    loanId = loan.json().loan.id;
    expect(loan.json().wallet.balanceCents).toBe(1150);

    const tooMuch = await request('POST', `/v1/loans/${loanId}/repayments`, { amountCents: 1001 }, parentToken, 'repay-too-large');
    expect(tooMuch.statusCode).toBe(409);
    expect(tooMuch.json().error.code).toBe('REPAYMENT_EXCEEDS_OUTSTANDING');

    const partial = await request('POST', `/v1/loans/${loanId}/repayments`, { amountCents: 500 }, parentToken, 'repay-1');
    expect(partial.statusCode).toBe(201);
    expect(partial.json().loan.outstandingCents).toBe(500);

    const full = await request('POST', `/v1/loans/${loanId}/repayments`, { amountCents: 500 }, parentToken, 'repay-2');
    expect(full.statusCode).toBe(201);
    expect(full.json().loan.status).toBe('paid');
    expect(full.json().wallet.balanceCents).toBe(150);
  });

  it('stores a weekly allowance rule and records a scheduled occurrence', async () => {
    const rule = await request(
      'PUT',
      '/v1/allowance-rule',
      { amountCents: 250, cadence: 'weekly', weekday: 5, startDate: '2099-01-01' },
      parentToken,
      'allowance-1',
    );
    expect(rule.statusCode).toBe(200);
    const allowance = rule.json().allowanceRule;
    expect(allowance.amountCents).toBe(250);
    expect(allowance.nextOccurrenceId).toBeTruthy();

    const occurrence = await request(
      'POST',
      `/v1/allowance-rule/${allowance.id}/occurrences/${allowance.nextOccurrenceId}/record`,
      {},
      parentToken,
      'allowance-occurrence-1',
    );
    expect(occurrence.statusCode).toBe(201);
    expect(occurrence.json().wallet.balanceCents).toBe(400);
  });

  it('protects accepted ledger entries from mutation', async () => {
    await expect(db.query("UPDATE ledger_entries SET reason = 'tampered'"),).rejects.toThrow();
    await expect(db.query('DELETE FROM ledger_entries'),).rejects.toThrow();
    await expect(db.query("UPDATE repayments SET amount_cents = 1"),).rejects.toThrow();
  });
});

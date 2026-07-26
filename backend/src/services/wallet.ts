import type { SqlClient, Database } from '../db/client.js';
import { addDays, nextWeeklyDate, parseDateOnly } from '../domain/dates.js';
import { MAX_AMOUNT_CENTS, parseAmountCents, subtractCents, toJsonCents } from '../domain/money.js';
import { AppError, validationError } from '../errors.js';
import { runIdempotent, type CommandResponse } from './idempotency.js';

export interface SetupInput {
  familyName?: string;
  nickname: string;
  avatarUrl?: string | null;
  lessonAgeBand: string;
}

export interface ProfilePatch {
  nickname?: string;
  avatarUrl?: string | null;
  lessonAgeBand?: string;
}

export interface AllowanceInput {
  amountCents: unknown;
  cadence: 'weekly';
  weekday: number;
  startDate: string;
  endDate?: string | null;
}

interface OwnedContext {
  familyId: string;
  familyName: string;
  childId: string;
  nickname: string;
  avatarUrl: string | null;
  lessonAgeBand: string;
  walletId: string;
  balanceCents: string;
}

interface LedgerRow {
  id: string;
  wallet_id: string;
  entry_type: string;
  direction: string;
  amount_cents: string;
  balance_before_cents: string;
  balance_after_cents: string;
  reason: string | null;
  loan_id: string | null;
  recorded_at: Date | string;
}

interface LoanRow {
  id: string;
  principal_cents: string;
  outstanding_cents: string;
  purpose: string | null;
  due_date: string | null;
  status: 'open' | 'paid';
  created_at: Date | string;
  paid_at: Date | string | null;
}

function isoTimestamp(value: Date | string): string {
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function text(value: unknown, fieldName: string, maxLength: number, required = false): string | null {
  if (value === undefined || value === null) {
    if (required) throw validationError(`${fieldName} is required.`);
    return null;
  }
  if (typeof value !== 'string') throw validationError(`${fieldName} must be a string.`);
  const trimmed = value.trim();
  if (required && trimmed.length === 0) throw validationError(`${fieldName} cannot be empty.`);
  if (trimmed.length > maxLength) throw validationError(`${fieldName} is too long.`);
  return trimmed || null;
}

function formatLedger(row: LedgerRow): Record<string, unknown> {
  return {
    id: row.id,
    type: row.entry_type,
    direction: row.direction,
    amountCents: toJsonCents(row.amount_cents),
    balanceBeforeCents: toJsonCents(row.balance_before_cents),
    balanceAfterCents: toJsonCents(row.balance_after_cents),
    reason: row.reason,
    loanId: row.loan_id,
    recordedBy: 'parent',
    recordedAt: isoTimestamp(row.recorded_at),
  };
}

function formatLoan(row: LoanRow): Record<string, unknown> {
  return {
    id: row.id,
    principalCents: toJsonCents(row.principal_cents),
    outstandingCents: toJsonCents(row.outstanding_cents),
    purpose: row.purpose,
    dueDate: row.due_date,
    status: row.status,
    createdAt: isoTimestamp(row.created_at),
    paidAt: row.paid_at ? isoTimestamp(row.paid_at) : null,
  };
}

async function ownedContext(client: SqlClient, identityId: string): Promise<OwnedContext> {
  const result = await client.query<OwnedContext>(
    `
      SELECT f.id AS "familyId", f.name AS "familyName",
             c.id AS "childId", c.nickname, c.avatar_url AS "avatarUrl", c.lesson_age_band AS "lessonAgeBand",
             w.id AS "walletId", w.balance_cents::text AS "balanceCents"
      FROM families f
      JOIN children c ON c.family_id = f.id
      JOIN wallets w ON w.child_id = c.id
      WHERE f.owner_identity_id = $1
    `,
    [identityId],
  );
  const context = result.rows[0];
  if (!context) throw new AppError(409, 'FAMILY_NOT_SETUP', 'Complete parent and Eddie setup before using the wallet.');
  return context;
}

async function ledgerEntry(client: SqlClient, walletId: string, entryId: string): Promise<LedgerRow> {
  const result = await client.query<LedgerRow>(
    `SELECT id, wallet_id, entry_type, direction, amount_cents::text, balance_before_cents::text,
            balance_after_cents::text, reason, loan_id, recorded_at
     FROM ledger_entries WHERE wallet_id = $1 AND id = $2`,
    [walletId, entryId],
  );
  const row = result.rows[0];
  if (!row) throw new AppError(404, 'ACTIVITY_NOT_FOUND', 'The activity entry was not found.');
  return row;
}

async function snapshot(client: SqlClient, identityId: string): Promise<Record<string, unknown>> {
  const context = await ownedContext(client, identityId);
  const loanResult = await client.query<LoanRow>(
    `SELECT id, principal_cents::text, outstanding_cents::text, purpose, due_date, status, created_at, paid_at
     FROM loans WHERE wallet_id = $1 ORDER BY created_at DESC LIMIT 1`,
    [context.walletId],
  );
  const allowanceResult = await client.query<{
    id: string;
    amount_cents: string;
    cadence: string;
    weekday: number;
    start_date: string;
    end_date: string | null;
    active: boolean;
    next_occurrence_id: string | null;
    next_due_on: string | null;
  }>(
    `
      SELECT r.id, r.amount_cents::text, r.cadence, r.weekday, r.start_date, r.end_date, r.active,
             (SELECT o.id FROM allowance_occurrences o
              WHERE o.rule_id = r.id AND o.status = 'scheduled'
              ORDER BY o.due_on LIMIT 1) AS next_occurrence_id,
             (SELECT o.due_on FROM allowance_occurrences o
              WHERE o.rule_id = r.id AND o.status = 'scheduled'
              ORDER BY o.due_on LIMIT 1) AS next_due_on
      FROM allowance_rules r WHERE r.wallet_id = $1
    `,
    [context.walletId],
  );
  const entriesResult = await client.query<LedgerRow>(
    `SELECT id, wallet_id, entry_type, direction, amount_cents::text, balance_before_cents::text,
            balance_after_cents::text, reason, loan_id, recorded_at
     FROM ledger_entries WHERE wallet_id = $1 ORDER BY recorded_at DESC, id DESC LIMIT 10`,
    [context.walletId],
  );
  const loan = loanResult.rows[0];
  const allowance = allowanceResult.rows[0];
  return {
    family: { id: context.familyId, name: context.familyName },
    child: {
      id: context.childId,
      nickname: context.nickname,
      avatarUrl: context.avatarUrl,
      lessonAgeBand: context.lessonAgeBand,
    },
    wallet: {
      id: context.walletId,
      currency: 'USD',
      balanceCents: toJsonCents(context.balanceCents),
      virtualNotice: 'Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money.',
    },
    allowanceRule: allowance
      ? {
          id: allowance.id,
          amountCents: toJsonCents(allowance.amount_cents),
          cadence: allowance.cadence,
          weekday: allowance.weekday,
          startDate: allowance.start_date,
          endDate: allowance.end_date,
          active: allowance.active,
          nextOccurrenceId: allowance.next_occurrence_id,
          nextDueDate: allowance.next_due_on,
        }
      : null,
    loan: loan ? formatLoan(loan) : null,
    recentActivity: entriesResult.rows.map(formatLedger),
  };
}

async function recordLedger(
  client: SqlClient,
  input: {
    walletId: string;
    actorIdentityId: string;
    type: 'deposit' | 'withdrawal' | 'allowance' | 'loan' | 'repayment';
    direction: 'credit' | 'debit';
    amountCents: bigint;
    reason: string | null;
    loanId?: string;
  },
): Promise<LedgerRow> {
  const wallet = await client.query<{ balance_cents: string }>(
    'SELECT balance_cents::text FROM wallets WHERE id = $1 FOR UPDATE',
    [input.walletId],
  );
  const walletRow = wallet.rows[0];
  if (!walletRow) throw new AppError(404, 'WALLET_NOT_FOUND', 'The wallet was not found.');
  const before = BigInt(walletRow.balance_cents);
  const after = input.direction === 'credit'
    ? before + input.amountCents
    : subtractCents(before, input.amountCents, 'The withdrawal or repayment');
  if (after > MAX_AMOUNT_CENTS) {
    throw new AppError(409, 'BALANCE_LIMIT_EXCEEDED', 'The resulting virtual balance exceeds the supported limit.');
  }

  const inserted = await client.query<{ id: string }>(
    `
      INSERT INTO ledger_entries
        (wallet_id, entry_type, direction, amount_cents, balance_before_cents, balance_after_cents,
         reason, loan_id, recorded_by_identity_id)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
      RETURNING id
    `,
    [
      input.walletId,
      input.type,
      input.direction,
      input.amountCents.toString(),
      before.toString(),
      after.toString(),
      input.reason,
      input.loanId ?? null,
      input.actorIdentityId,
    ],
  );
  const id = inserted.rows[0]?.id;
  if (!id) throw new Error('Ledger insert did not return an id.');
  await client.query("SELECT set_config('eddys_wallet.allow_balance_update', 'on', true)");
  await client.query('UPDATE wallets SET balance_cents = $1 WHERE id = $2', [after.toString(), input.walletId]);
  return ledgerEntry(client, input.walletId, id);
}

function command<T>(
  db: Database,
  identityId: string,
  idempotencyKey: string,
  requestHash: string,
  work: (client: SqlClient) => Promise<CommandResponse<T>>,
): Promise<CommandResponse<T>> {
  return runIdempotent(db, identityId, idempotencyKey, requestHash, work);
}

export class WalletService {
  constructor(private readonly db: Database) {}

  async family(identityId: string): Promise<Record<string, unknown>> {
    return snapshot(this.db, identityId);
  }

  async childView(identityId: string): Promise<Record<string, unknown>> {
    const result = await snapshot(this.db, identityId);
    return {
      wallet: result.wallet,
      child: result.child,
      allowanceRule: result.allowanceRule,
      loan: result.loan,
      recentActivity: result.recentActivity,
      readOnly: true,
    };
  }

  async activity(identityId: string, limit: number): Promise<Record<string, unknown>> {
    const context = await ownedContext(this.db, identityId);
    const result = await this.db.query<LedgerRow>(
      `SELECT id, wallet_id, entry_type, direction, amount_cents::text, balance_before_cents::text,
              balance_after_cents::text, reason, loan_id, recorded_at
       FROM ledger_entries WHERE wallet_id = $1 ORDER BY recorded_at DESC, id DESC LIMIT $2`,
      [context.walletId, limit],
    );
    return { entries: result.rows.map(formatLedger), virtualNotice: 'Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money.' };
  }

  async activityDetail(identityId: string, entryId: string): Promise<Record<string, unknown>> {
    const context = await ownedContext(this.db, identityId);
    const entry = await ledgerEntry(this.db, context.walletId, entryId);
    return { entry: formatLedger(entry), virtualNotice: 'Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money.' };
  }

  async setup(
    identityId: string,
    input: SetupInput,
    idempotencyKey: string,
    requestHashValue: string,
  ): Promise<CommandResponse<Record<string, unknown>>> {
    const familyName = text(input.familyName, 'familyName', 120) ?? "Eddie's family";
    const nickname = text(input.nickname, 'nickname', 80, true)!;
    const lessonAgeBand = text(input.lessonAgeBand, 'lessonAgeBand', 32, true)!;
    const avatarUrl = text(input.avatarUrl, 'avatarUrl', 2048);
    return command(this.db, identityId, idempotencyKey, requestHashValue, async (client) => {
      await client.query('SELECT id FROM parent_identities WHERE id = $1 FOR UPDATE', [identityId]);
      const existing = await client.query('SELECT id FROM families WHERE owner_identity_id = $1 FOR UPDATE', [identityId]);
      if (existing.rows.length > 0) throw new AppError(409, 'FAMILY_ALREADY_SETUP', 'This parent already has a family.');
      const family = await client.query<{ id: string }>(
        'INSERT INTO families (owner_identity_id, name) VALUES ($1, $2) RETURNING id',
        [identityId, familyName],
      );
      const familyId = family.rows[0]?.id;
      if (!familyId) throw new Error('Family insert did not return an id.');
      const child = await client.query<{ id: string }>(
        `INSERT INTO children (family_id, nickname, avatar_url, lesson_age_band)
         VALUES ($1, $2, $3, $4) RETURNING id`,
        [familyId, nickname, avatarUrl, lessonAgeBand],
      );
      const childId = child.rows[0]?.id;
      if (!childId) throw new Error('Child insert did not return an id.');
      await client.query('INSERT INTO wallets (child_id) VALUES ($1)', [childId]);
      return { statusCode: 201, body: await snapshot(client, identityId) };
    });
  }

  async updateProfile(
    identityId: string,
    input: ProfilePatch,
    idempotencyKey: string,
    requestHashValue: string,
  ): Promise<CommandResponse<Record<string, unknown>>> {
    const updates: string[] = [];
    const values: unknown[] = [];
    if (input.nickname !== undefined) {
      updates.push(`nickname = $${values.length + 1}`);
      values.push(text(input.nickname, 'nickname', 80, true));
    }
    if (input.avatarUrl !== undefined) {
      updates.push(`avatar_url = $${values.length + 1}`);
      values.push(text(input.avatarUrl, 'avatarUrl', 2048));
    }
    if (input.lessonAgeBand !== undefined) {
      updates.push(`lesson_age_band = $${values.length + 1}`);
      values.push(text(input.lessonAgeBand, 'lessonAgeBand', 32, true));
    }
    if (updates.length === 0) throw validationError('At least one profile field is required.');
    return command(this.db, identityId, idempotencyKey, requestHashValue, async (client) => {
      const context = await ownedContext(client, identityId);
      values.push(context.childId);
      const updated = await client.query(`UPDATE children SET ${updates.join(', ')} WHERE id = $${values.length} RETURNING id`, values);
      if (updated.rows.length === 0) throw new AppError(404, 'CHILD_NOT_FOUND', 'Eddie profile was not found.');
      return { statusCode: 200, body: await snapshot(client, identityId) };
    });
  }

  async updateFamily(
    identityId: string,
    input: { name: unknown },
    idempotencyKey: string,
    requestHashValue: string,
  ): Promise<CommandResponse<Record<string, unknown>>> {
    const name = text(input.name, 'name', 120, true)!;
    return command(this.db, identityId, idempotencyKey, requestHashValue, async (client) => {
      const context = await ownedContext(client, identityId);
      await client.query('UPDATE families SET name = $1 WHERE id = $2', [name, context.familyId]);
      return { statusCode: 200, body: await snapshot(client, identityId) };
    });
  }

  async deposit(
    identityId: string,
    input: { amountCents: unknown; reason?: unknown },
    idempotencyKey: string,
    requestHashValue: string,
  ): Promise<CommandResponse<Record<string, unknown>>> {
    const amountCents = parseAmountCents(input.amountCents);
    const reason = text(input.reason, 'reason', 240);
    return command(this.db, identityId, idempotencyKey, requestHashValue, async (client) => {
      const context = await ownedContext(client, identityId);
      const entry = await recordLedger(client, {
        walletId: context.walletId,
        actorIdentityId: identityId,
        type: 'deposit',
        direction: 'credit',
        amountCents,
        reason,
      });
      return { statusCode: 201, body: { entry: formatLedger(entry), wallet: (await snapshot(client, identityId)).wallet } };
    });
  }

  async withdrawal(
    identityId: string,
    input: { amountCents: unknown; reason?: unknown },
    idempotencyKey: string,
    requestHashValue: string,
  ): Promise<CommandResponse<Record<string, unknown>>> {
    const amountCents = parseAmountCents(input.amountCents);
    const reason = text(input.reason, 'reason', 240);
    return command(this.db, identityId, idempotencyKey, requestHashValue, async (client) => {
      const context = await ownedContext(client, identityId);
      const entry = await recordLedger(client, {
        walletId: context.walletId,
        actorIdentityId: identityId,
        type: 'withdrawal',
        direction: 'debit',
        amountCents,
        reason,
      });
      return { statusCode: 201, body: { entry: formatLedger(entry), wallet: (await snapshot(client, identityId)).wallet } };
    });
  }

  async createLoan(
    identityId: string,
    input: { principalCents: unknown; purpose?: unknown; dueDate?: unknown },
    idempotencyKey: string,
    requestHashValue: string,
  ): Promise<CommandResponse<Record<string, unknown>>> {
    const principalCents = parseAmountCents(input.principalCents, 'principalCents');
    const purpose = text(input.purpose, 'purpose', 240);
    const dueDate = input.dueDate === undefined || input.dueDate === null ? null : parseDateOnly(input.dueDate, 'dueDate');
    return command(this.db, identityId, idempotencyKey, requestHashValue, async (client) => {
      const context = await ownedContext(client, identityId);
      await client.query('SELECT id FROM wallets WHERE id = $1 FOR UPDATE', [context.walletId]);
      const openLoan = await client.query('SELECT id FROM loans WHERE wallet_id = $1 AND status = \'open\' FOR UPDATE', [context.walletId]);
      if (openLoan.rows.length > 0) throw new AppError(409, 'OPEN_LOAN_EXISTS', 'Only one open loan is supported in the MVP.');
      const loan = await client.query<{ id: string }>(
        `INSERT INTO loans (wallet_id, principal_cents, outstanding_cents, purpose, due_date, created_by_identity_id)
         VALUES ($1, $2, $2, $3, $4, $5) RETURNING id`,
        [context.walletId, principalCents.toString(), purpose, dueDate, identityId],
      );
      const loanId = loan.rows[0]?.id;
      if (!loanId) throw new Error('Loan insert did not return an id.');
      const entry = await recordLedger(client, {
        walletId: context.walletId,
        actorIdentityId: identityId,
        type: 'loan',
        direction: 'credit',
        amountCents: principalCents,
        reason: purpose,
        loanId,
      });
      const loanRow = await client.query<LoanRow>(
        `SELECT id, principal_cents::text, outstanding_cents::text, purpose, due_date, status, created_at, paid_at
         FROM loans WHERE id = $1`,
        [loanId],
      );
      return {
        statusCode: 201,
        body: { loan: loanRow.rows[0] ? formatLoan(loanRow.rows[0]) : null, entry: formatLedger(entry), wallet: (await snapshot(client, identityId)).wallet },
      };
    });
  }

  async repayLoan(
    identityId: string,
    loanId: string,
    input: { amountCents: unknown; reason?: unknown },
    idempotencyKey: string,
    requestHashValue: string,
  ): Promise<CommandResponse<Record<string, unknown>>> {
    const amountCents = parseAmountCents(input.amountCents);
    const reason = text(input.reason, 'reason', 240);
    return command(this.db, identityId, idempotencyKey, requestHashValue, async (client) => {
      const context = await ownedContext(client, identityId);
      await client.query('SELECT id FROM wallets WHERE id = $1 FOR UPDATE', [context.walletId]);
      const loanResult = await client.query<LoanRow>(
        `SELECT id, principal_cents::text, outstanding_cents::text, purpose, due_date, status, created_at, paid_at
         FROM loans WHERE id = $1 AND wallet_id = $2 FOR UPDATE`,
        [loanId, context.walletId],
      );
      const loan = loanResult.rows[0];
      if (!loan) throw new AppError(404, 'LOAN_NOT_FOUND', 'The loan was not found.');
      const outstanding = BigInt(loan.outstanding_cents);
      if (loan.status !== 'open' || outstanding === 0n) throw new AppError(409, 'LOAN_ALREADY_PAID', 'The loan is already paid.');
      if (amountCents > outstanding) throw new AppError(409, 'REPAYMENT_EXCEEDS_OUTSTANDING', 'Repayment cannot exceed the outstanding principal.');
      const entry = await recordLedger(client, {
        walletId: context.walletId,
        actorIdentityId: identityId,
        type: 'repayment',
        direction: 'debit',
        amountCents,
        reason,
        loanId,
      });
      await client.query(
        `INSERT INTO repayments (loan_id, ledger_entry_id, amount_cents, recorded_by_identity_id)
         VALUES ($1, $2, $3, $4)`,
        [loanId, entry.id, amountCents.toString(), identityId],
      );
      const remaining = outstanding - amountCents;
      await client.query(
        `UPDATE loans SET outstanding_cents = $1, status = $2, paid_at = CASE WHEN $3 = 0 THEN now() ELSE NULL END WHERE id = $4`,
        [remaining.toString(), remaining === 0n ? 'paid' : 'open', remaining.toString(), loanId],
      );
      const updatedLoan = await client.query<LoanRow>(
        `SELECT id, principal_cents::text, outstanding_cents::text, purpose, due_date, status, created_at, paid_at
         FROM loans WHERE id = $1`,
        [loanId],
      );
      return {
        statusCode: 201,
        body: { loan: updatedLoan.rows[0] ? formatLoan(updatedLoan.rows[0]) : null, entry: formatLedger(entry), wallet: (await snapshot(client, identityId)).wallet },
      };
    });
  }

  async setAllowance(
    identityId: string,
    input: AllowanceInput,
    idempotencyKey: string,
    requestHashValue: string,
  ): Promise<CommandResponse<Record<string, unknown>>> {
    const amountCents = parseAmountCents(input.amountCents);
    if (input.cadence !== 'weekly') throw validationError('Only weekly allowance rules are supported in the MVP.');
    if (!Number.isInteger(input.weekday) || input.weekday < 0 || input.weekday > 6) throw validationError('weekday must be an integer from 0 (Sunday) to 6 (Saturday).');
    const startDate = parseDateOnly(input.startDate, 'startDate');
    const endDate = input.endDate === undefined || input.endDate === null ? null : parseDateOnly(input.endDate, 'endDate');
    if (endDate && endDate < startDate) throw validationError('endDate cannot be before startDate.');
    return command(this.db, identityId, idempotencyKey, requestHashValue, async (client) => {
      const context = await ownedContext(client, identityId);
      await client.query('SELECT id FROM wallets WHERE id = $1 FOR UPDATE', [context.walletId]);
      const existing = await client.query<{ id: string }>('SELECT id FROM allowance_rules WHERE wallet_id = $1 FOR UPDATE', [context.walletId]);
      let ruleId: string;
      if (existing.rows[0]) {
        ruleId = existing.rows[0].id;
        await client.query(
          `UPDATE allowance_rules SET amount_cents = $1, cadence = $2, weekday = $3, start_date = $4, end_date = $5, active = true
           WHERE id = $6`,
          [amountCents.toString(), input.cadence, input.weekday, startDate, endDate, ruleId],
        );
        await client.query("UPDATE allowance_occurrences SET status = 'cancelled' WHERE rule_id = $1 AND status = 'scheduled'", [ruleId]);
      } else {
        const inserted = await client.query<{ id: string }>(
          `INSERT INTO allowance_rules (wallet_id, amount_cents, cadence, weekday, start_date, end_date, created_by_identity_id)
           VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id`,
          [context.walletId, amountCents.toString(), input.cadence, input.weekday, startDate, endDate, identityId],
        );
        ruleId = inserted.rows[0]?.id ?? '';
      }
      const today = new Date().toISOString().slice(0, 10);
      let nextDue = nextWeeklyDate(startDate > today ? startDate : today, input.weekday);
      while (nextDue < today) nextDue = addDays(nextDue, 7);
      if (!endDate || nextDue <= endDate) {
        await client.query(
          `INSERT INTO allowance_occurrences (rule_id, due_on) VALUES ($1, $2) ON CONFLICT (rule_id, due_on) DO NOTHING`,
          [ruleId, nextDue],
        );
      }
      return { statusCode: 200, body: await snapshot(client, identityId) };
    });
  }

  async recordAllowance(
    identityId: string,
    ruleId: string,
    occurrenceId: string,
    input: { reason?: unknown },
    idempotencyKey: string,
    requestHashValue: string,
  ): Promise<CommandResponse<Record<string, unknown>>> {
    const reason = text(input.reason, 'reason', 240) ?? 'Allowance';
    return command(this.db, identityId, idempotencyKey, requestHashValue, async (client) => {
      const context = await ownedContext(client, identityId);
      await client.query('SELECT id FROM wallets WHERE id = $1 FOR UPDATE', [context.walletId]);
      const result = await client.query<{
        occurrence_id: string;
        due_on: string;
        status: string;
        rule_id: string;
        amount_cents: string;
        end_date: string | null;
        weekday: number;
        active: boolean;
      }>(
        `SELECT o.id AS occurrence_id, o.due_on, o.status, r.id AS rule_id, r.amount_cents::text, r.end_date, r.weekday, r.active
         FROM allowance_occurrences o JOIN allowance_rules r ON r.id = o.rule_id
         WHERE o.id = $1 AND o.rule_id = $2 AND r.wallet_id = $3 FOR UPDATE`,
        [occurrenceId, ruleId, context.walletId],
      );
      const occurrence = result.rows[0];
      if (!occurrence) throw new AppError(404, 'ALLOWANCE_OCCURRENCE_NOT_FOUND', 'The allowance occurrence was not found.');
      if (!occurrence.active || occurrence.status !== 'scheduled') throw new AppError(409, 'ALLOWANCE_NOT_SCHEDULED', 'This allowance occurrence is no longer scheduled.');
      const entry = await recordLedger(client, {
        walletId: context.walletId,
        actorIdentityId: identityId,
        type: 'allowance',
        direction: 'credit',
        amountCents: BigInt(occurrence.amount_cents),
        reason,
      });
      await client.query(
        "UPDATE allowance_occurrences SET status = 'recorded', accepted_entry_id = $1 WHERE id = $2",
        [entry.id, occurrenceId],
      );
      const nextDue = addDays(occurrence.due_on, 7);
      if (!occurrence.end_date || nextDue <= occurrence.end_date) {
        await client.query(
          `INSERT INTO allowance_occurrences (rule_id, due_on) VALUES ($1, $2) ON CONFLICT (rule_id, due_on) DO NOTHING`,
          [ruleId, nextDue],
        );
      }
      return { statusCode: 201, body: { entry: formatLedger(entry), wallet: (await snapshot(client, identityId)).wallet } };
    });
  }

  async loanDetail(identityId: string, loanId: string): Promise<Record<string, unknown>> {
    const context = await ownedContext(this.db, identityId);
    const loanResult = await this.db.query<LoanRow>(
      `SELECT id, principal_cents::text, outstanding_cents::text, purpose, due_date, status, created_at, paid_at
       FROM loans WHERE id = $1 AND wallet_id = $2`,
      [loanId, context.walletId],
    );
    const loan = loanResult.rows[0];
    if (!loan) throw new AppError(404, 'LOAN_NOT_FOUND', 'The loan was not found.');
    const entries = await this.db.query<LedgerRow>(
      `SELECT id, wallet_id, entry_type, direction, amount_cents::text, balance_before_cents::text,
              balance_after_cents::text, reason, loan_id, recorded_at
       FROM ledger_entries WHERE wallet_id = $1 AND loan_id = $2 ORDER BY recorded_at ASC, id ASC`,
      [context.walletId, loanId],
    );
    return {
      loan: formatLoan(loan),
      repaymentsAndLoanEntry: entries.rows.map(formatLedger),
      virtualNotice: 'Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money.',
    };
  }
}

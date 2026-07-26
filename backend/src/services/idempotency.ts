import type { Database, SqlClient } from '../db/client.js';
import { AppError } from '../errors.js';

export interface CommandResponse<T> {
  statusCode: number;
  body: T;
}

export async function runIdempotent<T>(
  db: Database,
  actorIdentityId: string,
  idempotencyKey: string,
  requestHash: string,
  work: (client: SqlClient) => Promise<CommandResponse<T>>,
): Promise<CommandResponse<T>> {
  return db.transaction(async (client) => {
    const inserted = await client.query<{ id: string }>(
      `
        INSERT INTO idempotency_records (actor_identity_id, idempotency_key, request_hash)
        VALUES ($1, $2, $3)
        ON CONFLICT (actor_identity_id, idempotency_key) DO NOTHING
        RETURNING id
      `,
      [actorIdentityId, idempotencyKey, requestHash],
    );

    if (inserted.rows.length === 0) {
      const existing = await client.query<{
        request_hash: string;
        response_status: number | null;
        response_body: T | null;
      }>(
        `
          SELECT request_hash, response_status, response_body
          FROM idempotency_records
          WHERE actor_identity_id = $1 AND idempotency_key = $2
          FOR UPDATE
        `,
        [actorIdentityId, idempotencyKey],
      );
      const row = existing.rows[0];
      if (!row || row.request_hash !== requestHash) {
        throw new AppError(409, 'IDEMPOTENCY_KEY_REUSED', 'The idempotency key was used with a different command.');
      }
      if (row.response_status === null || row.response_body === null) {
        throw new AppError(409, 'COMMAND_IN_PROGRESS', 'The command is still being processed. Retry it.');
      }
      return { statusCode: row.response_status, body: row.response_body };
    }

    const response = await work(client);
    await client.query(
      `
        UPDATE idempotency_records
        SET response_status = $1, response_body = $2
        WHERE actor_identity_id = $3 AND idempotency_key = $4
      `,
      [response.statusCode, JSON.stringify(response.body), actorIdentityId, idempotencyKey],
    );
    return response;
  });
}

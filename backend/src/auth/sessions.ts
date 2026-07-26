import { createHash, randomBytes } from 'node:crypto';
import type { Database } from '../db/client.js';
import { AppError } from '../errors.js';
import type { VerifiedIdentity } from './provider.js';

export interface AuthContext {
  identityId: string;
  provider: 'apple' | 'local';
  subject: string;
  email: string | null;
}

function hashToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

export class SessionService {
  constructor(
    private readonly db: Database,
    private readonly sessionTtlDays: number,
  ) {}

  async createSession(identity: VerifiedIdentity): Promise<{ token: string; expiresAt: string; auth: AuthContext }> {
    const token = randomBytes(32).toString('base64url');
    const expiresAt = new Date(Date.now() + this.sessionTtlDays * 24 * 60 * 60 * 1000);
    const result = await this.db.query<{
      id: string;
      provider: 'apple' | 'local';
      subject: string;
      email: string | null;
    }>(
      `
        INSERT INTO parent_identities (provider, subject, email)
        VALUES ($1, $2, $3)
        ON CONFLICT (provider, subject) DO UPDATE
          SET email = COALESCE(EXCLUDED.email, parent_identities.email)
        RETURNING id, provider, subject, email
      `,
      [identity.provider, identity.subject, identity.email ?? null],
    );
    const row = result.rows[0];
    if (!row) throw new Error('Identity insert did not return an identity.');
    await this.db.query(
      `INSERT INTO sessions (parent_identity_id, token_hash, expires_at) VALUES ($1, $2, $3)`,
      [row.id, hashToken(token), expiresAt],
    );
    return {
      token,
      expiresAt: expiresAt.toISOString(),
      auth: { identityId: row.id, provider: row.provider, subject: row.subject, email: row.email },
    };
  }

  async authenticate(token: string): Promise<AuthContext> {
    const result = await this.db.query<{
      identity_id: string;
      provider: 'apple' | 'local';
      subject: string;
      email: string | null;
    }>(
      `
        SELECT i.id AS identity_id, i.provider, i.subject, i.email
        FROM sessions s
        JOIN parent_identities i ON i.id = s.parent_identity_id
        WHERE s.token_hash = $1
          AND s.revoked_at IS NULL
          AND s.expires_at > now()
      `,
      [hashToken(token)],
    );
    const row = result.rows[0];
    if (!row) throw new AppError(401, 'UNAUTHENTICATED', 'A valid parent session is required.');
    await this.db.query('UPDATE sessions SET last_seen_at = now() WHERE token_hash = $1', [hashToken(token)]);
    return {
      identityId: row.identity_id,
      provider: row.provider,
      subject: row.subject,
      email: row.email,
    };
  }

  async getMe(auth: AuthContext): Promise<Record<string, unknown>> {
    const family = await this.db.query<{
      id: string;
      name: string;
      child_id: string;
      nickname: string;
      avatar_url: string | null;
      lesson_age_band: string;
    }>(
      `
        SELECT f.id, f.name, c.id AS child_id, c.nickname, c.avatar_url, c.lesson_age_band
        FROM families f
        JOIN children c ON c.family_id = f.id
        WHERE f.owner_identity_id = $1
      `,
      [auth.identityId],
    );
    const row = family.rows[0];
    return {
      parent: { provider: auth.provider, subject: auth.subject, email: auth.email },
      family: row
        ? {
            id: row.id,
            name: row.name,
            child: {
              id: row.child_id,
              nickname: row.nickname,
              avatarUrl: row.avatar_url,
              lessonAgeBand: row.lesson_age_band,
            },
          }
        : null,
    };
  }
}

export function bearerToken(header: string | undefined): string {
  if (!header || !/^Bearer\s+[^\s]+$/i.test(header)) {
    throw new AppError(401, 'UNAUTHENTICATED', 'A bearer parent session is required.');
  }
  return header.replace(/^Bearer\s+/i, '');
}

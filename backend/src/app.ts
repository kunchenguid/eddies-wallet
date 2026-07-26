import Fastify, { type FastifyInstance, type FastifyRequest } from 'fastify';
import { z, ZodError } from 'zod';
import type { Config } from './config.js';
import { Database } from './db/client.js';
import { requestHash } from './domain/canonical.js';
import { AppError, asAppError } from './errors.js';
import { AppleIdentityProvider, type IdentityProvider } from './auth/provider.js';
import { bearerToken, SessionService, type AuthContext } from './auth/sessions.js';
import { WalletService } from './services/wallet.js';

const authAppleSchema = z.object({
  identityToken: z.string().min(1).max(16_384),
  nonce: z.string().min(1).max(512).optional(),
});
const localAuthSchema = z.object({ subject: z.string().min(1).max(256), email: z.string().email().optional() });
const setupSchema = z.object({
  familyName: z.string().max(120).optional(),
  nickname: z.string().min(1).max(80),
  avatarUrl: z.string().url().max(2048).nullable().optional(),
  lessonAgeBand: z.string().min(1).max(32),
});
const profileSchema = z.object({
  nickname: z.string().min(1).max(80).optional(),
  avatarUrl: z.string().url().max(2048).nullable().optional(),
  lessonAgeBand: z.string().min(1).max(32).optional(),
});
const familySchema = z.object({ name: z.string().min(1).max(120) });
const moneySchema = z.object({
  amountCents: z.union([z.number().int().positive(), z.string().regex(/^\d+$/)]),
  reason: z.string().max(240).nullable().optional(),
});
const loanSchema = z.object({
  principalCents: z.union([z.number().int().positive(), z.string().regex(/^\d+$/)]),
  purpose: z.string().max(240).nullable().optional(),
  dueDate: z.string().optional().nullable(),
});
const allowanceSchema = z.object({
  amountCents: z.union([z.number().int().positive(), z.string().regex(/^\d+$/)]),
  cadence: z.literal('weekly'),
  weekday: z.number().int().min(0).max(6),
  startDate: z.string(),
  endDate: z.string().nullable().optional(),
});
const reasonSchema = z.object({ reason: z.string().max(240).nullable().optional() });

export interface AppDependencies {
  db: Database;
  config: Config;
  identityProvider?: IdentityProvider;
}

function parse<T>(schema: z.ZodType<T>, value: unknown): T {
  return schema.parse(value ?? {});
}

function idempotencyKey(request: FastifyRequest): string {
  const header = request.headers['idempotency-key'];
  const key = Array.isArray(header) ? header[0] : header;
  if (!key || key.length > 128) {
    throw new AppError(400, 'IDEMPOTENCY_KEY_REQUIRED', 'Mutating commands require an Idempotency-Key header.');
  }
  return key;
}

function queryLimit(request: FastifyRequest): number {
  const raw = (request.query as { limit?: string } | undefined)?.limit;
  if (raw === undefined) return 50;
  const limit = Number(raw);
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
    throw new AppError(400, 'VALIDATION_ERROR', 'limit must be an integer from 1 to 100.');
  }
  return limit;
}

async function requireAuth(request: FastifyRequest, sessions: SessionService): Promise<AuthContext> {
  return sessions.authenticate(bearerToken(request.headers.authorization));
}

function sendCommand<T>(reply: { code: (statusCode: number) => { send: (body: T) => unknown } }, response: { statusCode: number; body: T }) {
  return reply.code(response.statusCode).send(response.body);
}

export function createApp(dependencies: AppDependencies): FastifyInstance {
  const { db, config } = dependencies;
  const app = Fastify({ logger: false });
  const sessions = new SessionService(db, config.sessionTtlDays);
  const wallet = new WalletService(db);
  const identityProvider = dependencies.identityProvider
    ?? (config.authMode === 'apple' ? new AppleIdentityProvider(config.appleAudiences, config.appleNonceRequired) : undefined);

  app.get('/healthz', async (_request, reply) => {
    const healthy = await db.health();
    return reply.code(healthy ? 200 : 503).send({ status: healthy ? 'ok' : 'degraded', database: healthy ? 'ok' : 'unavailable' });
  });

  app.post('/v1/auth/apple', async (request, reply) => {
    if (config.authMode !== 'apple' || !identityProvider) {
      throw new AppError(404, 'NOT_FOUND', 'The requested authentication method is not enabled.');
    }
    const body = parse(authAppleSchema, request.body);
    const identity = await identityProvider.verifyIdentityToken(body.identityToken, body.nonce);
    const session = await sessions.createSession(identity);
    return reply.code(201).send({ token: session.token, expiresAt: session.expiresAt, parent: session.auth });
  });

  app.post('/v1/auth/local', async (request, reply) => {
    if (config.authMode !== 'local') {
      throw new AppError(404, 'NOT_FOUND', 'The requested authentication method is not enabled.');
    }
    const body = parse(localAuthSchema, request.body);
    const session = await sessions.createSession({ provider: 'local', subject: body.subject, email: body.email });
    return reply.code(201).send({ token: session.token, expiresAt: session.expiresAt, parent: session.auth, developmentOnly: true });
  });

  app.get('/v1/me', async (request) => {
    const auth = await requireAuth(request, sessions);
    return sessions.getMe(auth);
  });

  app.get('/v1/family', async (request) => {
    const auth = await requireAuth(request, sessions);
    return wallet.family(auth.identityId);
  });

  app.post('/v1/family/setup', async (request, reply) => {
    const auth = await requireAuth(request, sessions);
    const body = parse(setupSchema, request.body);
    const key = idempotencyKey(request);
    return sendCommand(reply, await wallet.setup(auth.identityId, body, key, requestHash(request.url, body)));
  });

  app.patch('/v1/family', async (request, reply) => {
    const auth = await requireAuth(request, sessions);
    const body = parse(familySchema, request.body);
    const key = idempotencyKey(request);
    return sendCommand(reply, await wallet.updateFamily(auth.identityId, body, key, requestHash(request.url, body)));
  });

  app.patch('/v1/child/profile', async (request, reply) => {
    const auth = await requireAuth(request, sessions);
    const body = parse(profileSchema, request.body);
    const key = idempotencyKey(request);
    return sendCommand(reply, await wallet.updateProfile(auth.identityId, body, key, requestHash(request.url, body)));
  });

  app.get('/v1/wallet', async (request) => {
    const auth = await requireAuth(request, sessions);
    return wallet.family(auth.identityId);
  });

  app.get('/v1/child-view', async (request) => {
    const auth = await requireAuth(request, sessions);
    return wallet.childView(auth.identityId);
  });

  app.get('/v1/activity', async (request) => {
    const auth = await requireAuth(request, sessions);
    return wallet.activity(auth.identityId, queryLimit(request));
  });

  app.get('/v1/activity/:entryId', async (request) => {
    const auth = await requireAuth(request, sessions);
    const params = request.params as { entryId: string };
    return wallet.activityDetail(auth.identityId, params.entryId);
  });

  app.get('/v1/loans/:loanId', async (request) => {
    const auth = await requireAuth(request, sessions);
    const params = request.params as { loanId: string };
    return wallet.loanDetail(auth.identityId, params.loanId);
  });

  app.get('/v1/allowance-rule', async (request) => {
    const auth = await requireAuth(request, sessions);
    const current = await wallet.family(auth.identityId);
    return { allowanceRule: current.allowanceRule };
  });

  app.put('/v1/allowance-rule', async (request, reply) => {
    const auth = await requireAuth(request, sessions);
    const body = parse(allowanceSchema, request.body);
    const key = idempotencyKey(request);
    return sendCommand(reply, await wallet.setAllowance(auth.identityId, body, key, requestHash(request.url, body)));
  });

  app.post('/v1/allowance-rule/:ruleId/occurrences/:occurrenceId/record', async (request, reply) => {
    const auth = await requireAuth(request, sessions);
    const body = parse(reasonSchema, request.body);
    const params = request.params as { ruleId: string; occurrenceId: string };
    const key = idempotencyKey(request);
    return sendCommand(reply, await wallet.recordAllowance(auth.identityId, params.ruleId, params.occurrenceId, body, key, requestHash(request.url, body)));
  });

  app.post('/v1/wallet/deposits', async (request, reply) => {
    const auth = await requireAuth(request, sessions);
    const body = parse(moneySchema, request.body);
    const key = idempotencyKey(request);
    return sendCommand(reply, await wallet.deposit(auth.identityId, body, key, requestHash(request.url, body)));
  });

  app.post('/v1/wallet/withdrawals', async (request, reply) => {
    const auth = await requireAuth(request, sessions);
    const body = parse(moneySchema, request.body);
    const key = idempotencyKey(request);
    return sendCommand(reply, await wallet.withdrawal(auth.identityId, body, key, requestHash(request.url, body)));
  });

  app.post('/v1/loans', async (request, reply) => {
    const auth = await requireAuth(request, sessions);
    const body = parse(loanSchema, request.body);
    const key = idempotencyKey(request);
    return sendCommand(reply, await wallet.createLoan(auth.identityId, body, key, requestHash(request.url, body)));
  });

  app.post('/v1/loans/:loanId/repayments', async (request, reply) => {
    const auth = await requireAuth(request, sessions);
    const body = parse(moneySchema, request.body);
    const params = request.params as { loanId: string };
    const key = idempotencyKey(request);
    return sendCommand(reply, await wallet.repayLoan(auth.identityId, params.loanId, body, key, requestHash(request.url, body)));
  });

  app.setNotFoundHandler((_request, reply) => reply.code(404).send({ error: { code: 'NOT_FOUND', message: 'The requested endpoint was not found.' } }));
  app.setErrorHandler((error, request, reply) => {
    if (error instanceof ZodError) {
      return reply.code(400).send({ error: { code: 'VALIDATION_ERROR', message: 'The request body is invalid.', details: error.flatten() } });
    }
    const appError = asAppError(error);
    if (appError.statusCode >= 500) {
      request.log.error({ err: error });
    }
    return reply.code(appError.statusCode).send({
      error: { code: appError.code, message: appError.message, ...(appError.details ? { details: appError.details } : {}) },
    });
  });

  return app;
}

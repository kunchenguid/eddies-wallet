import { AppError } from './errors.js';

export type AuthMode = 'apple' | 'local';

export interface Config {
  nodeEnv: string;
  port: number;
  databaseUrl: string;
  authMode: AuthMode;
  appleAudiences: string[];
  appleNonceRequired: boolean;
  sessionTtlDays: number;
}

function positiveInt(value: string | undefined, fallback: number, name: string): number {
  const parsed = value === undefined ? fallback : Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new AppError(500, 'INVALID_CONFIGURATION', `${name} must be a positive integer.`);
  }
  return parsed;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const nodeEnv = env.NODE_ENV ?? 'development';
  const authMode = (env.AUTH_MODE ?? 'apple') as AuthMode;
  if (authMode !== 'apple' && authMode !== 'local') {
    throw new AppError(500, 'INVALID_CONFIGURATION', 'AUTH_MODE must be apple or local.');
  }
  if (authMode === 'local' && nodeEnv === 'production') {
    throw new AppError(500, 'INVALID_CONFIGURATION', 'Local authentication cannot be enabled in production.');
  }

  const appleAudiences = (env.APPLE_AUDIENCES ?? '')
    .split(',')
    .map((value) => value.trim())
    .filter(Boolean);
  if (authMode === 'apple' && appleAudiences.length === 0) {
    throw new AppError(500, 'INVALID_CONFIGURATION', 'APPLE_AUDIENCES is required when AUTH_MODE=apple.');
  }

  return {
    nodeEnv,
    port: positiveInt(env.PORT, 3000, 'PORT'),
    databaseUrl: env.DATABASE_URL ?? 'postgresql://postgres@localhost:5433/eddys_wallet',
    authMode,
    appleAudiences,
    appleNonceRequired: (env.APPLE_NONCE_REQUIRED ?? 'true').toLowerCase() !== 'false',
    sessionTtlDays: positiveInt(env.SESSION_TTL_DAYS, 30, 'SESSION_TTL_DAYS'),
  };
}

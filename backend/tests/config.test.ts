import { describe, expect, it } from 'vitest';
import { loadConfig } from '../src/config.js';

describe('configuration safety', () => {
  it('rejects local auth in production', () => {
    expect(() => loadConfig({ NODE_ENV: 'production', AUTH_MODE: 'local' })).toThrow(/production/);
  });

  it('requires Apple audience in Apple mode', () => {
    expect(() => loadConfig({ NODE_ENV: 'test', AUTH_MODE: 'apple' })).toThrow(/APPLE_AUDIENCES/);
    const config = loadConfig({ NODE_ENV: 'test', AUTH_MODE: 'apple', APPLE_AUDIENCES: 'com.example.app' });
    expect(config.appleAudiences).toEqual(['com.example.app']);
    expect(config.appleNonceRequired).toBe(true);
  });
});

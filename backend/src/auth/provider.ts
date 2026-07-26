import { createRemoteJWKSet, jwtVerify } from 'jose';
import { AppError } from '../errors.js';

export interface VerifiedIdentity {
  provider: 'apple' | 'local';
  subject: string;
  email?: string;
}

export interface IdentityProvider {
  verifyIdentityToken(token: string, nonce?: string): Promise<VerifiedIdentity>;
}

export class AppleIdentityProvider implements IdentityProvider {
  private readonly jwks = createRemoteJWKSet(new URL('https://appleid.apple.com/auth/keys'));

  constructor(
    private readonly audiences: string[],
    private readonly nonceRequired: boolean,
  ) {}

  async verifyIdentityToken(token: string, nonce?: string): Promise<VerifiedIdentity> {
    if (!token || token.length > 16_384) {
      throw new AppError(401, 'INVALID_IDENTITY_TOKEN', 'The Apple identity token is invalid.');
    }
    if (this.nonceRequired && !nonce) {
      throw new AppError(401, 'INVALID_IDENTITY_TOKEN', 'A nonce is required for Apple Sign In.');
    }
    try {
      const { payload } = await jwtVerify(token, this.jwks, {
        issuer: 'https://appleid.apple.com',
        audience: this.audiences,
        ...(nonce ? { nonce } : {}),
      });
      if (typeof payload.sub !== 'string' || payload.sub.length === 0) {
        throw new Error('Apple token did not contain a subject.');
      }
      return {
        provider: 'apple',
        subject: payload.sub,
        ...(typeof payload.email === 'string' ? { email: payload.email } : {}),
      };
    } catch {
      throw new AppError(401, 'INVALID_IDENTITY_TOKEN', 'The Apple identity token could not be verified.');
    }
  }
}

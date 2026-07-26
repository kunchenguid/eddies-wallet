import { readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

async function fileAt(relativePath: string): Promise<string> {
  return readFile(resolve(repositoryRoot, relativePath), 'utf8');
}

describe('production and local container contracts', () => {
  it('keeps the production image aligned with internal port 8080', async () => {
    const dockerfile = await fileAt('backend/Dockerfile');
    const productionCompose = await fileAt('deploy/compose.yaml');
    const caddyfile = await fileAt('deploy/Caddyfile');

    expect(dockerfile).toMatch(/ENV PORT=8080/);
    expect(dockerfile).toMatch(/EXPOSE 8080/);
    expect(productionCompose).toMatch(/expose:\s+- "8080"/);
    expect(productionCompose).toMatch(/127\.0\.0\.1:8080\/healthz/);
    expect(caddyfile).toContain('reverse_proxy backend:8080');
  });

  it('keeps local development on port 3000', async () => {
    const localCompose = await fileAt('backend/docker-compose.yml');
    expect(localCompose).toMatch(/PORT: 3000/);
    expect(localCompose).toContain('"3000:3000"');
  });

  it('uses the compiled migration entrypoint in deployment configuration', async () => {
    const deployEnv = await fileAt('deploy/.env.example');
    const deployReadme = await fileAt('deploy/README.md');
    const migrationCommand = 'node dist/src/db/migrate.js';

    expect(deployEnv).toContain(`MIGRATION_COMMAND=${migrationCommand}`);
    expect(deployReadme).toContain(`MIGRATION_COMMAND='${migrationCommand}'`);
  });
});

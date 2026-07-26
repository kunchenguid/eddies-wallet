import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const MIGRATIONS_DIR = process.env.MIGRATIONS_DIR ?? join(process.cwd(), 'migrations');

export async function runMigrations(databaseUrl: string): Promise<void> {
  const pool = new pg.Pool({ connectionString: databaseUrl, max: 1 });
  const client = await pool.connect();
  try {
    await client.query('SELECT pg_advisory_lock(729381246)');
    await client.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version bigint PRIMARY KEY,
        name text NOT NULL,
        checksum text NOT NULL,
        applied_at timestamptz NOT NULL DEFAULT now()
      )
    `);

    const names = (await readdir(MIGRATIONS_DIR))
      .filter((name) => /^\d+_[a-z0-9_]+\.sql$/.test(name))
      .sort();
    for (const name of names) {
      const versionText = name.split('_', 1)[0];
      const version = Number(versionText);
      const sql = await readFile(join(MIGRATIONS_DIR, name), 'utf8');
      const checksum = createHash('sha256').update(sql).digest('hex');
      const existing = await client.query<{ checksum: string }>(
        'SELECT checksum FROM schema_migrations WHERE version = $1',
        [version],
      );
      if (existing.rows.length > 0) {
        if (existing.rows[0]?.checksum !== checksum) {
          throw new Error(`Migration ${name} was changed after it was applied.`);
        }
        continue;
      }
      await client.query('BEGIN');
      try {
        await client.query(sql);
        await client.query(
          'INSERT INTO schema_migrations (version, name, checksum) VALUES ($1, $2, $3)',
          [version, name, checksum],
        );
        await client.query('COMMIT');
      } catch (error) {
        await client.query('ROLLBACK');
        throw error;
      }
    }
    await client.query('SELECT pg_advisory_unlock(729381246)');
  } finally {
    client.release();
    await pool.end();
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const databaseUrl = process.env.DATABASE_URL ?? 'postgresql://postgres@localhost:5433/eddys_wallet';
  runMigrations(databaseUrl)
    .then(() => {
      console.log('Database migrations are up to date.');
    })
    .catch((error: unknown) => {
      console.error(error);
      process.exitCode = 1;
    });
}

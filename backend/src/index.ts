import { createApp } from './app.js';
import { loadConfig } from './config.js';
import { Database } from './db/client.js';

const config = loadConfig();
const db = new Database(config.databaseUrl);
const app = createApp({ db, config });

const shutdown = async (signal: string) => {
  app.log.info(`Received ${signal}; shutting down.`);
  await app.close();
  await db.close();
  process.exit(0);
};

process.once('SIGTERM', () => void shutdown('SIGTERM'));
process.once('SIGINT', () => void shutdown('SIGINT'));

app.listen({ port: config.port, host: '0.0.0.0' }).catch(async (error) => {
  app.log.error(error);
  await db.close();
  process.exit(1);
});

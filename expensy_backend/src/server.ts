import 'dotenv/config';
import fs from 'node:fs';
import { Registry } from 'prom-client';
import { createApp } from './app';
import { connectDB } from './config/db.config';
import { createRedis } from './config/redis';
import { loadSettings } from './config/settings';
import { logError } from './log';
import Expense from './models/expense.model';
import { ExpenseService } from './services/expense.service';

async function main(): Promise<void> {
  const settings = loadSettings(process.env, (path) => fs.readFileSync(path, 'utf8'));
  const redis = createRedis(settings.redis);
  await connectDB(settings.mongo);

  const app = createApp({ expenses: new ExpenseService(Expense, redis), registry: new Registry() });
  app.listen(settings.port, () => {
    console.log(`Server is running on port ${settings.port}`);
  });
}

main().catch((error) => {
  logError('Startup failed', error);
  process.exit(1);
});

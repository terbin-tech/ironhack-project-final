import express from 'express';
import bodyParser from 'body-parser';
import cors from 'cors';
import type { Registry } from 'prom-client';
import { expenseRoutes } from './routes/expense.route';
import { httpMetrics } from './metrics';
import type { ExpenseService } from './services/expense.service';

export function createApp(deps: { expenses: ExpenseService; registry: Registry }): express.Express {
  const app = express();
  app.disable('x-powered-by');
  app.use(httpMetrics(deps.registry));
  app.use(cors());
  app.use(bodyParser.json());

  app.get('/healthz', (_req, res) => {
    res.status(200).json({ status: 'ok' });
  });
  app.get('/metrics', async (_req, res) => {
    res.set('Content-Type', deps.registry.contentType);
    res.send(await deps.registry.metrics());
  });
  app.use('/api', expenseRoutes(deps.expenses));

  return app;
}

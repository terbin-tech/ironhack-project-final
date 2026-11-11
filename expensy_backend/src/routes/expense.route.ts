import { Router } from 'express';
import { expenseController } from '../controllers/expense.controller';
import type { ExpenseService } from '../services/expense.service';

export function expenseRoutes(service: ExpenseService): Router {
  const { getExpenses, addExpense } = expenseController(service);
  const router = Router();
  router.get('/expenses', getExpenses);
  router.post('/expenses', addExpense);
  return router;
}

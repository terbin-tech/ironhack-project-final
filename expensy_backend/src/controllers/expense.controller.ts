import type { Request, Response } from 'express';
import mongoose from 'mongoose';
import type { ExpenseService } from '../services/expense.service';
import { logError } from '../log';

const isInvalidInput = (error: unknown): error is Error =>
  error instanceof mongoose.Error.ValidationError || error instanceof mongoose.Error.CastError;

export function expenseController(service: ExpenseService) {
  return {
    getExpenses: async (_req: Request, res: Response) => {
      try {
        res.status(200).json(await service.getAllExpenses());
      } catch (error) {
        logError('Failed to fetch expenses', error);
        res.status(500).json({ error: 'Failed to fetch expenses' });
      }
    },

    addExpense: async (req: Request, res: Response) => {
      try {
        const { name, amount, category } = req.body ?? {};
        res.status(201).json(await service.createExpense({ name, amount, category }));
      } catch (error) {
        if (isInvalidInput(error)) {
          res.status(400).json({ error: error.message });
          return;
        }
        logError('Failed to create expense', error);
        res.status(500).json({ error: 'Failed to create expense' });
      }
    },
  };
}

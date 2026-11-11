import type Redis from 'ioredis';
import Expense from '../models/expense.model';
import { logError } from '../log';

export interface NewExpense {
  name: string;
  amount: number;
  category: string;
}

export interface ExpenseStore {
  find(): PromiseLike<unknown[]>;
  create(expense: NewExpense): Promise<unknown>;
}

export type ExpenseCache = Pick<Redis, 'get' | 'set' | 'del'>;

const CACHE_KEY = 'expenses';
const CACHE_SECONDS = 60 * 5;

// Redis is only a cache: a failed step is logged and skipped.
async function cacheStep<T>(step: string, run: () => Promise<T>): Promise<T | undefined> {
  try {
    return await run();
  } catch (error) {
    logError(`Cache ${step} failed, skipped`, error);
    return undefined;
  }
}

export class ExpenseService {
  constructor(
    private readonly store: ExpenseStore,
    private readonly cache: ExpenseCache,
  ) {}

  async getAllExpenses(): Promise<unknown> {
    const cached = await cacheStep('read', () => this.cache.get(CACHE_KEY));
    if (cached) {
      console.log('Cache hit');
      return JSON.parse(cached);
    }

    const expenses = await this.store.find();
    await cacheStep('write', () => this.cache.set(CACHE_KEY, JSON.stringify(expenses), 'EX', CACHE_SECONDS));
    return expenses;
  }

  async createExpense(expense: NewExpense): Promise<unknown> {
    // Validate first, so an invalid body is a ValidationError whatever the store is.
    await new Expense(expense).validate();
    const created = await this.store.create(expense);
    await cacheStep('clear', () => this.cache.del(CACHE_KEY));
    return created;
  }
}

import type { ExpenseCache, ExpenseStore } from '../src/services/expense.service';

export const rows = [{ name: 'Groceries', amount: 100, category: 'Food' }];

export function fakeStore(): ExpenseStore & { created: unknown[] } {
  const created: unknown[] = [];
  return {
    created,
    find: async () => rows,
    create: async (expense) => {
      created.push(expense);
      return { _id: 'id-1', ...expense };
    },
  } as ExpenseStore & { created: unknown[] };
}

export function fakeCache(overrides: Partial<ExpenseCache> = {}): ExpenseCache & { deleted: string[] } {
  const deleted: string[] = [];
  return {
    deleted,
    get: async () => null,
    set: async () => 'OK',
    del: async (key: string) => {
      deleted.push(key);
      return 1;
    },
    ...overrides,
  } as ExpenseCache & { deleted: string[] };
}

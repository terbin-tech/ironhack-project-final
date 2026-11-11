import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ExpenseService } from '../src/services/expense.service';
import { fakeCache, fakeStore, rows } from './fakes';

test('getAllExpenses falls back to the database when the cache throws', async () => {
  const cache = fakeCache({
    get: async () => { throw new Error('connection refused'); },
    set: async () => { throw new Error('connection refused'); },
  });
  const service = new ExpenseService(fakeStore(), cache);
  assert.deepEqual(await service.getAllExpenses(), rows);
});

test('createExpense clears the cache', async () => {
  const cache = fakeCache();
  const service = new ExpenseService(fakeStore(), cache);
  await service.createExpense({ name: 'Rent', amount: 900, category: 'Housing' });
  assert.deepEqual(cache.deleted, ['expenses']);
});

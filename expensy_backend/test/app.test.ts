import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import type { Server } from 'node:http';
import { Registry } from 'prom-client';
import { createApp } from '../src/app';
import { ExpenseService } from '../src/services/expense.service';
import { fakeCache, fakeStore } from './fakes';

let server: Server;
let base: string;

before(async () => {
  const app = createApp({ expenses: new ExpenseService(fakeStore(), fakeCache()), registry: new Registry() });
  server = app.listen(0);
  await new Promise((resolve) => server.once('listening', resolve));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});

after(() => new Promise((resolve) => server.close(resolve)));

const post = (body: unknown) =>
  fetch(`${base}/api/expenses`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });

test('POST with an invalid body returns 400', async () => {
  const res = await post({ amount: 'abc' });
  assert.equal(res.status, 400);
  const body = await res.json();
  assert.equal(typeof body.error, 'string');
});

test('POST with a valid body returns 201', async () => {
  const res = await post({ name: 'Groceries', amount: 100, category: 'Food' });
  assert.equal(res.status, 201);
});

test('/healthz returns 200', async () => {
  const res = await fetch(`${base}/healthz`);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { status: 'ok' });
});

test('/metrics returns http_requests_total with route="/api/expenses"', async () => {
  await fetch(`${base}/api/expenses`);
  const res = await fetch(`${base}/metrics`);
  assert.ok(res.headers.get('content-type')?.startsWith('text/plain'));
  const text = await res.text();
  assert.match(text, /http_requests_total\{method="GET",route="\/api\/expenses",status="200"\} 1/);
});

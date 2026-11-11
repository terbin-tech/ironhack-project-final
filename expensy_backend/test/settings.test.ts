import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadSettings } from '../src/config/settings';

const fail = (path: string): string => {
  throw new Error(`unexpected read of ${path}`);
};

test('compose: DATABASE_URI used as is, no TLS', () => {
  const s = loadSettings({ DATABASE_URI: 'mongodb://root:example@mongo:27017', REDIS_HOST: 'redis', REDIS_PASSWORD: 'someredispassword' }, fail);
  assert.equal(s.mongo.uri, 'mongodb://root:example@mongo:27017');
  assert.equal(s.mongo.options.tls, undefined);
  assert.deepEqual([s.redis.host, s.redis.port, s.redis.password, s.redis.tls], ['redis', 6379, 'someredispassword', undefined]);
  assert.equal(s.port, 8706);
});

test('AWS: credentials from files, TLS with CA, password URL-encoded, no retryable writes', () => {
  const files: Record<string, string> = { '/s/u': 'expensy\n', '/s/p': 'p@ss/w:rd', '/s/r': 'valkeypw' };
  const s = loadSettings({ DB_HOST: 'db.example', DB_USERNAME_FILE: '/s/u', DB_PASSWORD_FILE: '/s/p', DB_TLS: 'true', DB_TLS_CA_FILE: '/ca.pem',
    REDIS_HOST: 'cache.example', REDIS_USERNAME: 'expensy', REDIS_PASSWORD_FILE: '/s/r', REDIS_TLS: 'true' }, (p) => files[p]);
  assert.equal(s.mongo.uri, 'mongodb://expensy:p%40ss%2Fw%3Ard@db.example:27017/expensy?replicaSet=rs0&readPreference=secondaryPreferred&retryWrites=false');
  assert.deepEqual([s.mongo.options.tls, s.mongo.options.tlsCAFile], [true, '/ca.pem']);
  assert.deepEqual([s.redis.username, s.redis.password, s.redis.tls], ['expensy', 'valkeypw', {}]);
});

test('missing DB_HOST and DATABASE_URI throws', () => assert.throws(() => loadSettings({}, fail), /DB_HOST or DATABASE_URI/));

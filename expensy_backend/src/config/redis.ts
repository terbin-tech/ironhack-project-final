import Redis, { type RedisOptions } from 'ioredis';
import { logError } from '../log';

// No offline queue and a short timeout: while Redis is down a command fails at
// once, so the request falls back to the database instead of waiting.
export function createRedis(options: RedisOptions): Redis {
  const redis = new Redis({ ...options, enableOfflineQueue: false, commandTimeout: 1000 });
  redis.on('error', (error) => logError('Redis error', error));
  return redis;
}

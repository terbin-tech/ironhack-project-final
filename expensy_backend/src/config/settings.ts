import type { ConnectOptions } from 'mongoose';
import type { RedisOptions } from 'ioredis';

export interface Settings {
  port: number;
  mongo: { uri: string; options: ConnectOptions };
  redis: RedisOptions;
}

type ReadFile = (path: string) => string;

// Secret files mounted by the CSI driver may end with a newline.
const readSecret = (readFile: ReadFile, path: string): string => readFile(path).replace(/\r?\n$/, '');

// DocumentDB: replica set rs0, reads from replicas, and no retryable writes
// (supported only from engine 8.0.2, and not with query planner 1.0).
function mongoUri(env: NodeJS.ProcessEnv, readFile: ReadFile): string {
  if (env.DATABASE_URI) return env.DATABASE_URI;
  if (!env.DB_HOST) throw new Error('Set DB_HOST or DATABASE_URI');

  const user = encodeURIComponent(readSecret(readFile, env.DB_USERNAME_FILE ?? ''));
  const password = encodeURIComponent(readSecret(readFile, env.DB_PASSWORD_FILE ?? ''));
  const port = env.DB_PORT ?? '27017';
  const name = env.DB_NAME ?? 'expensy';
  return `mongodb://${user}:${password}@${env.DB_HOST}:${port}/${name}?replicaSet=rs0&readPreference=secondaryPreferred&retryWrites=false`;
}

export function loadSettings(env: NodeJS.ProcessEnv, readFile: ReadFile): Settings {
  const options: ConnectOptions = {};
  if (env.DB_TLS === 'true') {
    options.tls = true;
    options.tlsCAFile = env.DB_TLS_CA_FILE;
  }

  const redisPassword = env.REDIS_PASSWORD_FILE ? readSecret(readFile, env.REDIS_PASSWORD_FILE) : env.REDIS_PASSWORD;

  return {
    port: Number(env.PORT) || 8706,
    mongo: { uri: mongoUri(env, readFile), options },
    redis: {
      host: env.REDIS_HOST ?? 'localhost',
      port: Number(env.REDIS_PORT) || 6379,
      username: env.REDIS_USERNAME,
      password: redisPassword,
      // ElastiCache's certificates are publicly trusted, so the system store verifies them.
      tls: env.REDIS_TLS === 'true' ? {} : undefined,
    },
  };
}

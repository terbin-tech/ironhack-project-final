import mongoose from 'mongoose';
import type { Settings } from './settings';
import { logError } from '../log';

// Exits on failure, so the server never listens without a database.
export async function connectDB(mongo: Settings['mongo']): Promise<void> {
  try {
    await mongoose.connect(mongo.uri, mongo.options);
    console.log('MongoDB connected');
  } catch (error) {
    logError('MongoDB connection error', error);
    process.exit(1);
  }
}

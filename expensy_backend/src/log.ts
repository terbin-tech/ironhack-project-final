// Errors are logged by name and message only: a full error object can carry
// connection settings.
export function logError(context: string, error: unknown): void {
  const { name, message } = error instanceof Error ? error : { name: 'Error', message: String(error) };
  console.error(`${context}: ${name}: ${message}`);
}

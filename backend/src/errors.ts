export type ErrorDetails = Record<string, unknown>;

export class AppError extends Error {
  constructor(
    public readonly statusCode: number,
    public readonly code: string,
    message: string,
    public readonly details?: ErrorDetails,
  ) {
    super(message);
    this.name = 'AppError';
  }
}

export function validationError(message: string, details?: ErrorDetails): AppError {
  return new AppError(400, 'VALIDATION_ERROR', message, details);
}

export function asAppError(error: unknown): AppError {
  if (error instanceof AppError) return error;
  return new AppError(500, 'INTERNAL_ERROR', 'An unexpected error occurred.');
}

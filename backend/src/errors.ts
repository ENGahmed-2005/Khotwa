export class ApiError extends Error {
  constructor(public readonly statusCode: number, public readonly code: string, message: string) {
    super(message);
  }
}

export const invalid = () => new ApiError(400, 'INVALID_INPUT', 'راجع الحقول المطلوبة وصياغتها.');
export const unauthorized = () => new ApiError(401, 'UNAUTHENTICATED', 'يلزم تسجيل الدخول مجددًا.');
export const missing = () => new ApiError(404, 'NOT_FOUND', 'السجل غير متاح.');


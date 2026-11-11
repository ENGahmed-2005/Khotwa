import { ApiError } from '../errors.js';

/** Classifies provider HTTP failures without reading or exposing provider bodies. */
export function providerHttpError(status: number): ApiError {
  switch (status) {
    case 503:
      return new ApiError(503, 'AI_PROVIDER_BUSY', 'خدمة التوليد مشغولة حاليًا؛ أعد المحاولة بعد قليل.');
    case 429:
      return new ApiError(503, 'AI_PROVIDER_LIMITED', 'بلغت خدمة التوليد حد الاستخدام؛ أعد المحاولة لاحقًا.');
    case 400:
      return new ApiError(502, 'AI_REQUEST_REJECTED', 'تعذر تنفيذ طلب التوليد؛ تواصل مع الدعم إذا استمرت المشكلة.');
    case 401:
    case 403:
      return new ApiError(503, 'AI_PROVIDER_CONFIGURATION', 'خدمة التوليد غير جاهزة حاليًا؛ يرجى التواصل مع الدعم.');
    default:
      return new ApiError(502, 'AI_PROVIDER_UNAVAILABLE', 'تعذر توليد المحتوى حاليًا؛ حاول لاحقًا.');
  }
}

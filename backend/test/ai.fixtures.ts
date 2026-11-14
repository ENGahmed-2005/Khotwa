import { randomUUID } from 'node:crypto';
import type { GenerationInput } from '../src/planning/domain.js';

export const aiInput: GenerationInput = { skills: [{ skillId: 'reading.sound_deletion', level: 'developing', evidence: 'approvedAcademicAssessment' }], durationWeeks: 6, sessionsPerWeek: 2, availableTools: ['cards'] };
export const aiContent = () => ({ needsSummary: 'تنمية مهارة حذف الصوت', strengthsSummary: 'لم تدرج تفاصيل نقاط القوة في الحمولة', generalGoal: 'تنمية الوعي الصوتي', baseline: 'مهارة حذف الصوت قيد التطور', tools: ['البطاقات'], measurementTools: ['قائمة رصد'], durationWeeks: 6, sessionsPerWeek: 2, goals: [{ id: randomUUID(), skillId: 'reading.sound_deletion', behavior: 'يحذف الصوت الأول', condition: 'عند عرض كلمة مسموعة', criterion: { type: 'trials' as const, correct: 4, total: 5 }, timeframeWeeks: 2 }], strategies: ['العرض المتدرج'], recommendations: ['مراجعة الأداء'], nextFollowUp: '2026-11-16' });

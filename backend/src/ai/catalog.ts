import type { AssessmentData } from '../schemas.js';

const catalog = [
  ['reading.sound_deletion', 'حذف الصوت الأول', ['1a']],
  ['reading.sound_substitution', 'إبدال الصوت الأول', ['1b']],
  ['reading.sound_blending', 'تجميع الأصوات', ['1c']],
  ['reading.words', 'قراءة الكلمات', ['1d1', '1d2', '1d3', '1d4']],
  ['writing.dictation', 'الإملاء', ['2a', '5a']],
  ['writing.handwriting', 'أداء الكتابة', ['2b']],
  ['math.skip_counting', 'العد القفزي', ['3a']],
  ['math.addition', 'الجمع', ['3b']],
  ['math.subtraction', 'الطرح', ['3c']],
  ['math.word_problems', 'حل المسائل اللفظية', ['3d', '6d']],
  ['reading.fluency', 'القراءة الجهرية', ['4a']],
  ['reading.literal_comprehension', 'الفهم المباشر', ['4b']],
  ['reading.inference', 'الفهم الاستنتاجي', ['4c']],
  ['language.antonyms', 'المضاد اللغوي', ['4d']],
  ['writing.expression', 'التعبير الكتابي', ['5b']],
  ['math.multiplication', 'الضرب', ['6a']],
  ['math.place_value', 'القيمة المنزلية', ['6b']],
  ['math.fractions', 'الكسور', ['6c']],
] as const;

export function skillsForAssessment(assessment: AssessmentData) {
  return catalog.filter(([, , items]) => items.some(id => assessment.results[id]?.execution === 'performed'))
    .map(([skillId, label]) => ({ skillId, label, evidence: 'approvedAcademicAssessment' as const }));
}

export const toolLabels = { board: 'السبورة', pencils: 'الأقلام', cards: 'البطاقات', paper: 'الأوراق', colors: 'الألوان' } as const;

import type { InitialAssessment } from './schema.js';

/** Educational suggestions from SRS FR-28/30, never standardized scales or diagnoses. */
export const educationalCatalog = [
  { id: 'reading', label: 'القراءة والمهارات القرائية', skills: [
    ['reading.letters', 'التعرف على الحروف'], ['reading.words', 'قراءة الكلمات'],
    ['reading.sound_deletion', 'حذف الصوت الأول'], ['reading.sound_substitution', 'إبدال الصوت الأول'],
    ['reading.sound_blending', 'تجميع الأصوات'], ['reading.fluency', 'القراءة الجهرية'],
    ['reading.literal_comprehension', 'الفهم المباشر'], ['reading.inference', 'الفهم الاستنتاجي'],
  ] },
  { id: 'writing', label: 'الكتابة والإملاء', skills: [
    ['writing.dictation', 'الإملاء'], ['writing.handwriting', 'أداء الكتابة'],
    ['writing.expression', 'التعبير الكتابي'], ['writing.name_pattern', 'كتابة نموذج الاسم دون حفظه في التطبيق'],
  ] },
  { id: 'math', label: 'الرياضيات والعمليات الحسابية', skills: [
    ['math.numbers', 'التعرف على الأرقام'], ['math.skip_counting', 'العد القفزي'], ['math.addition', 'الجمع'],
    ['math.subtraction', 'الطرح'], ['math.multiplication', 'الضرب'], ['math.place_value', 'القيمة المنزلية'],
    ['math.fractions', 'الكسور'], ['math.word_problems', 'حل المسائل اللفظية'],
  ] },
  { id: 'foundational', label: 'المهارات التعليمية والتأسيسية', skills: [
    ['foundational.auditory', 'التمييز السمعي'], ['foundational.visual', 'التمييز البصري'],
    ['foundational.classification', 'التصنيف'], ['foundational.sequencing', 'التسلسل'],
    ['foundational.pencil', 'مسك القلم'], ['foundational.cutting', 'القص'], ['foundational.coloring', 'التلوين'],
  ] },
  { id: 'attention', label: 'الانتباه والتركيز والمشاركة', skills: [
    ['attention.focus', 'المشاركة في مهمة تعليمية'], ['attention.participation', 'المشاركة في النشاط'],
  ] },
  { id: 'communication', label: 'التواصل واللغة', skills: [
    ['language.needs', 'التعبير عن الاحتياجات'], ['language.sentences', 'تكوين الجمل'], ['language.antonyms', 'المضاد اللغوي'],
  ] },
  { id: 'life', label: 'المهارات الحياتية والاستقلالية', skills: [
    ['life.independence', 'الاعتماد على النفس'], ['life.hygiene', 'النظافة'], ['life.tools', 'تنظيم الأدوات'],
  ] },
] as const;

export const educationalSkillLabels = new Map<string, string>(educationalCatalog.flatMap(domain => domain.skills.map(([id, label]) => [id, label] as [string, string])));

export function skillsForInitialAssessment(assessment: InitialAssessment) {
  return assessment.domains.flatMap(domain => domain.skills)
    .filter(skill => educationalSkillLabels.has(skill.id))
    .map(skill => ({ skillId: skill.id, label: educationalSkillLabels.get(skill.id)!, level: skill.level,
      evidence: assessment.method === 'academicCards' ? 'approvedAcademicAssessment' as const : 'approvedAlternativeAssessment' as const }));
}

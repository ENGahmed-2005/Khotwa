import { z } from 'zod';

// A lexical guard cannot detect every identity. Human privacy review remains required.
const privateOrClinical = /(?:[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|(?:\+?\d[\s-]?){9,}|\b\d{4}[-/]\d{2}[-/]\d{2}\b|تشخيص|توحد|التوحد|ديسلكسيا|عسر القراءة|إعاقة|دواء|أدوية|كسول|فاشل|غبي|diagnos|autis|dyslex|medicat)/iu;
export const educationalText = z.string().trim().max(2000).refine(value => !privateOrClinical.test(value), 'Review educational text for identifying or clinical content');
const label = educationalText.refine(value => value.length > 0 && value.length <= 120, 'Enter a short educational label');
const identifier = z.string().regex(/^[a-z][a-z0-9_.-]{1,80}$/);

export const initialSkillSchema = z.strictObject({
  id: identifier, label, level: z.enum(['mastered', 'developing', 'needsSupport']), evidence: educationalText,
});
export const initialDomainSchema = z.strictObject({
  id: identifier, label, currentPerformance: educationalText, strengths: educationalText, needs: educationalText,
  skills: z.array(initialSkillSchema).max(80),
});
export const initialAssessmentSchema = z.strictObject({
  id: z.uuid({ version: 'v4' }), studentId: z.uuid({ version: 'v4' }),
  createdAt: z.iso.datetime({ offset: true }), assessedOn: z.iso.date(),
  status: z.enum(['draft', 'approved']),
  method: z.enum(['directObservation', 'educationalActivity', 'checklist', 'academicCards']),
  academicAssessmentId: z.uuid({ version: 'v4' }).nullable().optional(),
  alternativeReason: educationalText,
  domains: z.array(initialDomainSchema).max(20),
  previousStrategies: z.array(z.strictObject({ name: label, result: educationalText })).max(30),
  privacyReviewed: z.literal(true), approvedAt: z.iso.datetime({ offset: true }).nullable(),
}).superRefine((value, context) => {
  if ((value.status === 'approved') !== (value.approvedAt !== null)) context.addIssue({ code: 'custom', path: ['approvedAt'], message: 'Only explicit approval has a timestamp' });
  const domainIds = new Set<string>();
  const skillIds = new Set<string>();
  for (const [index, domain] of value.domains.entries()) {
    if (domainIds.has(domain.id)) context.addIssue({ code: 'custom', path: ['domains', index, 'id'], message: 'Duplicate domain' });
    domainIds.add(domain.id);
    for (const [skillIndex, skill] of domain.skills.entries()) {
      if (skillIds.has(skill.id)) context.addIssue({ code: 'custom', path: ['domains', index, 'skills', skillIndex, 'id'], message: 'Duplicate skill' });
      skillIds.add(skill.id);
      if (value.status === 'approved' && !skill.evidence) context.addIssue({ code: 'custom', path: ['domains', index, 'skills', skillIndex, 'evidence'], message: 'Document the source of each level before approval' });
    }
    if (value.status === 'approved' && (!domain.currentPerformance || !domain.strengths || !domain.needs || !domain.skills.length)) context.addIssue({ code: 'custom', path: ['domains', index], message: 'Review performance, strengths, needs and skills before approval' });
  }
  if (value.status === 'approved') {
    if (!value.domains.length) context.addIssue({ code: 'custom', path: ['domains'], message: 'At least one reviewed educational domain is required' });
    if (value.method === 'academicCards' ? !value.academicAssessmentId : !value.alternativeReason) context.addIssue({ code: 'custom', message: 'Reference approved cards or explain the alternative assessment' });
  }
});
export type InitialAssessment = z.infer<typeof initialAssessmentSchema>;

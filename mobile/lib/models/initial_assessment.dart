const performanceLevels = <String, String>{
  'mastered': 'متقن',
  'developing': 'يحتاج إلى تطوير',
  'needsSupport': 'يحتاج إلى دعم إضافي',
};
const assessmentMethods = <String, String>{
  'directObservation': 'ملاحظة مباشرة',
  'educationalActivity': 'نشاط تقييم تربوي',
  'checklist': 'قائمة رصد',
  'academicCards': 'بطاقات التقييم الأكاديمي المعتمدة',
};

/// Educational descriptions from SRS FR-28/30, not diagnostic scales.
const educationalDomains = <String, Map<String, String>>{
  "reading": {
    "label": "القراءة والمهارات القرائية",
    "reading.letters": "التعرف على الحروف",
    "reading.words": "قراءة الكلمات",
    "reading.sound_deletion": "حذف الصوت الأول",
    "reading.sound_substitution": "إبدال الصوت الأول",
    "reading.sound_blending": "تجميع الأصوات",
    "reading.fluency": "القراءة الجهرية",
    "reading.literal_comprehension": "الفهم المباشر",
    "reading.inference": "الفهم الاستنتاجي",
  },
  "writing": {
    "label": "الكتابة والإملاء",
    "writing.dictation": "الإملاء",
    "writing.handwriting": "أداء الكتابة",
    "writing.expression": "التعبير الكتابي",
    "writing.name_pattern": "كتابة نموذج الاسم دون حفظه في التطبيق",
  },
  "math": {
    "label": "الرياضيات والعمليات الحسابية",
    "math.numbers": "التعرف على الأرقام",
    "math.skip_counting": "العد القفزي",
    "math.addition": "الجمع",
    "math.subtraction": "الطرح",
    "math.multiplication": "الضرب",
    "math.place_value": "القيمة المنزلية",
    "math.fractions": "الكسور",
    "math.word_problems": "حل المسائل اللفظية",
  },
  "foundational": {
    "label": "المهارات التعليمية والتأسيسية",
    "foundational.auditory": "التمييز السمعي",
    "foundational.visual": "التمييز البصري",
    "foundational.classification": "التصنيف",
    "foundational.sequencing": "التسلسل",
    "foundational.pencil": "مسك القلم",
    "foundational.cutting": "القص",
    "foundational.coloring": "التلوين",
  },
  "attention": {
    "label": "الانتباه والتركيز والمشاركة",
    "attention.focus": "المشاركة في مهمة تعليمية",
    "attention.participation": "المشاركة في النشاط",
  },
  "communication": {
    "label": "التواصل واللغة",
    "language.needs": "التعبير عن الاحتياجات",
    "language.sentences": "تكوين الجمل",
    "language.antonyms": "المضاد اللغوي",
  },
  "life": {
    "label": "المهارات الحياتية والاستقلالية",
    "life.independence": "الاعتماد على النفس",
    "life.hygiene": "النظافة",
    "life.tools": "تنظيم الأدوات",
  },
};

String? educationalTextIssue(Iterable<String> values) {
  final text = values.join(' ');
  if (values.any((value) => value.length > 2000)) {
    return 'النص أطول من 2000 حرف.';
  }
  if (RegExp(
    r'[^\s@]+@[^\s@]+\.[^\s@]+|(?:\+?\d[\d\s-]{7,}\d)|\b\d{4}[-/]\d{1,2}[-/]\d{1,2}\b',
  ).hasMatch(text)) {
    return 'أزيلي بيانات الاتصال أو التاريخ التعريفي. استخدمي وصف الأداء فقط.';
  }
  if (RegExp(
    r'تشخيص|توحد|توحّد|متلازمة|دواء|أدوية|اضطراب نفسي|ديسلكسيا|عسر القراءة|إعاقة|كسول|فاشل|غبي|diagnos|autis|dyslex|medicat|ADHD|DSM',
    caseSensitive: false,
  ).hasMatch(text)) {
    return 'هذا التطبيق للتقييم التربوي. تُراجع المسائل الطبية والنفسية مع المختصين خارج التطبيق.';
  }
  return null;
}

class InitialSkill {
  const InitialSkill({
    required this.id,
    required this.label,
    required this.level,
    required this.evidence,
  });
  final String id, label, level, evidence;
  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'level': level,
    'evidence': evidence,
  };
  factory InitialSkill.fromJson(Map<String, dynamic> data) => InitialSkill(
    id: data['id'] as String,
    label: data['label'] as String,
    level: data['level'] as String,
    evidence: data['evidence'] as String,
  );
}

class InitialDomain {
  const InitialDomain({
    required this.id,
    required this.label,
    required this.currentPerformance,
    required this.strengths,
    required this.needs,
    required this.skills,
  });
  final String id, label, currentPerformance, strengths, needs;
  final List<InitialSkill> skills;
  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'currentPerformance': currentPerformance,
    'strengths': strengths,
    'needs': needs,
    'skills': skills.map((s) => s.toJson()).toList(),
  };
  factory InitialDomain.fromJson(Map<String, dynamic> data) => InitialDomain(
    id: data['id'] as String,
    label: data['label'] as String,
    currentPerformance: data['currentPerformance'] as String,
    strengths: data['strengths'] as String,
    needs: data['needs'] as String,
    skills: (data['skills'] as List)
        .map((s) => InitialSkill.fromJson(Map<String, dynamic>.from(s as Map)))
        .toList(),
  );
}

class InitialAssessmentRecord {
  const InitialAssessmentRecord({
    required this.id,
    required this.studentId,
    required this.createdAt,
    required this.assessedOn,
    this.status = 'draft',
    this.method = 'directObservation',
    this.alternativeReason = '',
    this.academicAssessmentId,
    this.domains = const [],
    this.previousStrategies = const [],
    this.privacyReviewed = false,
    this.approvedAt,
  });
  final String id,
      studentId,
      createdAt,
      assessedOn,
      status,
      method,
      alternativeReason;
  final String? academicAssessmentId, approvedAt;
  final List<InitialDomain> domains;
  final List<Map<String, String>> previousStrategies;
  final bool privacyReviewed;
  bool get approved => status == 'approved';
  bool get hasDevelopmentNeed =>
      domains.any((d) => d.skills.any((s) => s.level != 'mastered'));
  Map<String, dynamic> toJson() => {
    'id': id,
    'studentId': studentId,
    'createdAt': createdAt,
    'assessedOn': assessedOn,
    'status': status,
    'method': method,
    'alternativeReason': alternativeReason,
    'academicAssessmentId': academicAssessmentId,
    'domains': domains.map((d) => d.toJson()).toList(),
    'previousStrategies': previousStrategies,
    'privacyReviewed': privacyReviewed,
    'approvedAt': approvedAt,
  };
  factory InitialAssessmentRecord.fromJson(Map<String, dynamic> data) =>
      InitialAssessmentRecord(
        id: data['id'] as String,
        studentId: data['studentId'] as String,
        createdAt: data['createdAt'] as String,
        assessedOn: data['assessedOn'] as String,
        status: data['status'] as String,
        method: data['method'] as String,
        alternativeReason: data['alternativeReason'] as String,
        academicAssessmentId: data['academicAssessmentId'] as String?,
        domains: (data['domains'] as List)
            .map(
              (d) =>
                  InitialDomain.fromJson(Map<String, dynamic>.from(d as Map)),
            )
            .toList(),
        previousStrategies: ((data['previousStrategies'] as List?) ?? [])
            .map((s) => Map<String, String>.from(s as Map))
            .toList(),
        privacyReviewed: data['privacyReviewed'] == true,
        approvedAt: data['approvedAt'] as String?,
      );
  InitialAssessmentRecord copyWith({
    String? assessedOn,
    String? status,
    String? method,
    String? alternativeReason,
    String? academicAssessmentId,
    List<InitialDomain>? domains,
    List<Map<String, String>>? previousStrategies,
    bool? privacyReviewed,
    String? approvedAt,
  }) => InitialAssessmentRecord(
    id: id,
    studentId: studentId,
    createdAt: createdAt,
    assessedOn: assessedOn ?? this.assessedOn,
    status: status ?? this.status,
    method: method ?? this.method,
    alternativeReason: alternativeReason ?? this.alternativeReason,
    academicAssessmentId: academicAssessmentId ?? this.academicAssessmentId,
    domains: domains ?? this.domains,
    previousStrategies: previousStrategies ?? this.previousStrategies,
    privacyReviewed: privacyReviewed ?? this.privacyReviewed,
    approvedAt: approvedAt ?? this.approvedAt,
  );

  String? validate({bool forApproval = false, DateTime? now}) {
    final parsed = DateTime.tryParse(assessedOn);
    if (parsed == null ||
        assessedOn.length != 10 ||
        parsed.toIso8601String().substring(0, 10) != assessedOn ||
        assessedOn.compareTo(
              (now ?? DateTime.now()).toIso8601String().substring(0, 10),
            ) >
            0) {
      return 'اختاري تاريخ تقييم صحيحًا لا يقع في المستقبل.';
    }
    if (!privacyReviewed) {
      return 'راجعي خلو النصوص من الأسماء والمعلومات التعريفية والصحية.';
    }
    if (!assessmentMethods.containsKey(method)) return 'حددي أسلوب التقييم.';
    final identifiers = RegExp(r'^[a-z][a-z0-9_.-]{1,80}$');
    final skillIds = <String>{};
    if (previousStrategies.length > 30 ||
        previousStrategies.any(
          (s) =>
              (s['name'] ?? '').trim().isEmpty ||
              (s['name'] ?? '').length > 120,
        )) {
      return 'أدخلي اسمًا قصيرًا لكل استراتيجية سابقة أو احذفي السطر الفارغ.';
    }
    if (domains.length > 20 ||
        domains.map((d) => d.id).toSet().length != domains.length) {
      return 'المجالات مكررة أو أكثر من الحد المسموح.';
    }
    for (final domain in domains) {
      if (!identifiers.hasMatch(domain.id) ||
          domain.label.trim().isEmpty ||
          domain.skills.map((s) => s.id).toSet().length !=
              domain.skills.length) {
        return 'راجعي اسم المجال ومعرّفات مهاراته.';
      }
      if (domain.skills.length > 80) {
        return 'عدد المهارات في المجال أكبر من الحد المسموح.';
      }
      if (forApproval &&
          ([
                domain.currentPerformance,
                domain.strengths,
                domain.needs,
              ].any((v) => v.trim().isEmpty) ||
              domain.skills.isEmpty)) {
        return 'أكملي الأداء الحالي والقوة والاحتياج ومهارة موثقة لكل مجال.';
      }
      for (final skill in domain.skills) {
        if (!skillIds.add(skill.id)) return 'المهارة نفسها مكررة بين المجالات.';
        if (!identifiers.hasMatch(skill.id) ||
            skill.label.trim().isEmpty ||
            !performanceLevels.containsKey(skill.level) ||
            (forApproval && skill.evidence.trim().isEmpty)) {
          return 'حددي مستوى كل مهارة وشاهد الأداء قبل الاعتماد.';
        }
      }
    }
    if (forApproval &&
        (domains.isEmpty ||
            (method != 'academicCards' && alternativeReason.trim().isEmpty) ||
            (method == 'academicCards' && academicAssessmentId == null))) {
      return 'يلزم مجال موثق ومصدر تقييم: بطاقة معتمدة أو سبب التقييم البديل.';
    }
    final texts = [
      alternativeReason,
      for (final d in domains) ...[
        d.label,
        d.currentPerformance,
        d.strengths,
        d.needs,
        for (final s in d.skills) ...[s.label, s.evidence],
      ],
      for (final s in previousStrategies) ...s.values,
    ];
    return educationalTextIssue(texts);
  }
}

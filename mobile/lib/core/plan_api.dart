import 'api_client.dart';

class PlanSkill {
  const PlanSkill({
    required this.id,
    required this.label,
    required this.evidence,
    this.assessedLevel,
  });
  final String id, label, evidence;
  final String? assessedLevel;
  factory PlanSkill.fromJson(Map<String, dynamic> value) => PlanSkill(
    id: value['skillId'] as String,
    label: value['label'] as String,
    evidence: value['evidence'] as String,
    assessedLevel: value['level'] as String?,
  );
}

class PlanPreview {
  const PlanPreview({
    required this.payload,
    required this.hash,
    required this.token,
    required this.expiresAt,
    this.customLabelsRequireConfirmation = false,
    this.studentReference,
  });
  final Map<String, dynamic> payload;
  final String hash, token;
  final DateTime expiresAt;
  final bool customLabelsRequireConfirmation;
  final String? studentReference;
  bool get hasCustomLabels =>
      customLabelsRequireConfirmation ||
      (payload['skills'] as List? ?? []).any(
        (value) => (value as Map)['reviewedLabel'] != null,
      );
  bool get expired => !expiresAt.isAfter(DateTime.now());
  Map<String, dynamic> toJson() => {
    'payload': payload,
    'hash': hash,
    'previewToken': token,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'customLabelsRequireConfirmation': hasCustomLabels,
    'presentation': {'studentReference': studentReference},
  };
  factory PlanPreview.fromJson(Map<String, dynamic> value) => PlanPreview(
    payload: Map<String, dynamic>.from(value['payload'] as Map),
    hash: value['hash'] as String,
    token: value['previewToken'] as String,
    expiresAt: DateTime.parse(value['expiresAt'] as String),
    customLabelsRequireConfirmation:
        value['customLabelsRequireConfirmation'] == true,
    studentReference:
        (value['presentation'] as Map?)?['studentReference'] as String?,
  );
}

class PlanRecord {
  const PlanRecord({
    required this.id,
    required this.revision,
    required this.data,
    required this.envelope,
  });
  final String id;
  final int revision;
  final Map<String, dynamic> data, envelope;
  String get studentId => data['studentId'] as String;
  bool get approved => data['status'] == 'approved';
  String get studentReference =>
      (data['presentation'] as Map?)?['studentReference'] as String? ??
      'الطالب/الطالبة';
  Map<String, dynamic> get content =>
      Map<String, dynamic>.from(data['content'] as Map);
  factory PlanRecord.fromJson(Map<String, dynamic> value) {
    if (value['kind'] != 'plan' || value['deletedAt'] != null) {
      throw const ApiException('invalid_plan', 'سجل الخطة غير متاح.');
    }
    return PlanRecord(
      id: value['id'] as String,
      revision: value['revision'] as int,
      data: Map<String, dynamic>.from(value['data'] as Map),
      envelope: value,
    );
  }
}

class PlanApi {
  const PlanApi({required this.api, required this.tokenForRequest});
  final ApiClient api;
  final String? Function() tokenForRequest;
  String get _token {
    final value = tokenForRequest();
    if (value == null) {
      throw const ApiException('unauthenticated', 'سجّلي الدخول لفتح الخطط.');
    }
    return value;
  }

  Future<List<PlanSkill>> skills(String assessmentId) async {
    final value = await api.request(
      'GET',
      '/v1/ai/skills?assessmentId=${Uri.encodeQueryComponent(assessmentId)}',
      token: _token,
    );
    return (value['skills'] as List)
        .map(
          (skill) =>
              PlanSkill.fromJson(Map<String, dynamic>.from(skill as Map)),
        )
        .toList();
  }

  Future<List<PlanRecord>> plans() async {
    final value = await api.request(
      'GET',
      '/v1/records?kind=plan',
      token: _token,
    );
    return (value['records'] as List)
        .map((record) => Map<String, dynamic>.from(record as Map))
        .where((record) => record['deletedAt'] == null)
        .map(PlanRecord.fromJson)
        .toList();
  }

  Future<PlanPreview> preview({
    required String studentId,
    required String assessmentId,
    required List<Map<String, dynamic>> skills,
    required int durationWeeks,
    required int sessionsPerWeek,
    required List<String> availableTools,
    required bool syntheticDataConfirmed,
    bool customSkillsReviewed = false,
  }) async {
    if (!syntheticDataConfirmed ||
        skills.isEmpty ||
        skills.every((skill) => skill['level'] == 'mastered') ||
        availableTools.isEmpty) {
      throw const ApiException(
        'CONFIRMATION_REQUIRED',
        'اختاري مهارة تحتاج تطويرًا وأداة متاحة وأكّدي استخدام بيانات مصطنعة.',
      );
    }
    final value = await api.request(
      'POST',
      '/v1/ai/preview',
      token: _token,
      data: {
        'studentId': studentId,
        'assessmentId': assessmentId,
        'skills': skills,
        'durationWeeks': durationWeeks,
        'sessionsPerWeek': sessionsPerWeek,
        'availableTools': availableTools,
        'syntheticDataConfirmed': true,
        if (customSkillsReviewed) 'customSkillsReviewed': true,
      },
    );
    return PlanPreview.fromJson(value);
  }

  Future<PlanRecord> generate({
    required PlanPreview preview,
    required String operationId,
    required bool confirmed,
    required bool syntheticDataConfirmed,
    bool customLabelsConfirmed = false,
  }) async {
    if (!confirmed ||
        !syntheticDataConfirmed ||
        (preview.hasCustomLabels && !customLabelsConfirmed)) {
      throw const ApiException(
        'CONFIRMATION_REQUIRED',
        'راجعي الحقول وأكّدي إرسالها أولًا.',
      );
    }
    // The server checks expiry for new work while permitting receipt recovery
    // after a committed request's acknowledgment was lost.
    final value = await api.request(
      'POST',
      '/v1/ai/generate',
      token: _token,
      timeout: const Duration(seconds: 90),
      data: {
        'previewToken': preview.token,
        'confirmed': true,
        'confirmedHash': preview.hash,
        'syntheticDataConfirmed': true,
        'operationId': operationId,
        if (preview.hasCustomLabels)
          'customLabelsConfirmed': customLabelsConfirmed,
      },
    );
    return PlanRecord.fromJson(
      Map<String, dynamic>.from(value['record'] as Map),
    );
  }

  Future<Map<String, dynamic>> operationStatus(String operationId) =>
      api.request(
        'GET',
        '/v1/ai/operations/${Uri.encodeComponent(operationId)}',
        token: _token,
      );

  Future<void> cancelOperation(
    String operationId, {
    required bool confirmed,
  }) async {
    if (!confirmed) {
      throw const ApiException(
        'CONFIRMATION_REQUIRED',
        'إلغاء الطلب يحتاج قرارًا صريحًا.',
      );
    }
    await api.request(
      'POST',
      '/v1/ai/operations/${Uri.encodeComponent(operationId)}/cancel',
      token: _token,
      data: {'confirmed': true},
    );
  }

  Future<PlanRecord> approve(PlanRecord plan, {required bool confirmed}) async {
    if (!confirmed || plan.approved) {
      throw const ApiException(
        'CONFIRMATION_REQUIRED',
        'اعتماد الخطة يحتاج مراجعة المختصة وتأكيدها الصريح.',
      );
    }
    final value = await api.request(
      'POST',
      '/v1/plans/${Uri.encodeComponent(plan.id)}/approve',
      token: _token,
      data: {'revision': plan.revision, 'confirmed': true},
    );
    return PlanRecord.fromJson(
      Map<String, dynamic>.from(value['record'] as Map),
    );
  }

  Future<PlanRecord> revise(
    PlanRecord plan, {
    required String operationId,
    required Map<String, dynamic> content,
    required Map<String, bool> templateOptions,
    required bool confirmed,
  }) async {
    if (!confirmed) {
      throw const ApiException(
        'CONFIRMATION_REQUIRED',
        'راجعي التعديلات وأكدي حفظ نسخة جديدة كمسودة.',
      );
    }
    final value = await api.request(
      'POST',
      '/v1/plans/${Uri.encodeComponent(plan.id)}/versions',
      token: _token,
      data: {
        'revision': plan.revision,
        'operationId': operationId,
        'confirmed': true,
        'content': content,
        'templateOptions': templateOptions,
      },
    );
    return PlanRecord.fromJson(
      Map<String, dynamic>.from(value['record'] as Map),
    );
  }

  Future<Map<String, dynamic>> history(String planId) => api.request(
    'GET',
    '/v1/plans/${Uri.encodeComponent(planId)}/history',
    token: _token,
  );
}

String planErrorMessage(Object error) {
  if (error is! ApiException) {
    return 'تعذّر إكمال الإجراء. احتُفظ بالمدخلات؛ أعيدي المحاولة.';
  }
  return switch (error.code) {
    'SOURCE_NOT_READY' =>
      'يلزم تقييم معتمد ومتزامن مع نقاط القوة والاحتياج وموافقة موثّقة.',
    'SOURCE_CHANGED' =>
      'تغيّر مصدر التقييم؛ حدّثي المعاينة وراجعي الحقول من جديد.',
    'PREVIEW_INVALID' || 'PREVIEW_EXPIRED' =>
      'انتهت صلاحية المعاينة أو لم تعد صالحة. أنشئي معاينة جديدة.',
    'AI_DISABLED' => 'خدمة التوليد غير مفعّلة على الخادم بعد.',
    'SYNTHETIC_ONLY' => 'هذه النسخة تسمح ببيانات اختبار مصطنعة فقط.',
    'AI_IN_PROGRESS' =>
      'الطلب السابق ما زال قيد التنفيذ. أعيدي المحاولة لاسترجاع النتيجة نفسها.',
    'AI_PROVIDER_UNAVAILABLE' =>
      'تعذّر التوليد عبر Gemini. احتُفظ بالمدخلات؛ أنشئي معاينة جديدة قبل إعادة الإرسال.',
    'AI_PREVIOUS_FAILED' =>
      'فشل الطلب السابق دون إنشاء خطة. احتُفظ بالمدخلات؛ أنشئي معاينة جديدة وأكّدي إرسالها لإعادة المحاولة.',
    'AI_OUTPUT_INVALID' =>
      'لم تجتز المسودة فحوص البنية أو السلامة؛ لم تُعرض ولم تُعتمد.',
    'REVISION_CONFLICT' =>
      'تغيّرت الخطة على الخادم. حدّثي القائمة وراجعي أحدث نسخة قبل الاعتماد.',
    _ => error.message,
  };
}

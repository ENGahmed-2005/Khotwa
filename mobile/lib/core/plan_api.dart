import 'api_client.dart';

class PlanSkill {
  const PlanSkill({
    required this.id,
    required this.label,
    required this.evidence,
  });
  final String id, label, evidence;
  factory PlanSkill.fromJson(Map<String, dynamic> value) => PlanSkill(
    id: value['skillId'] as String,
    label: value['label'] as String,
    evidence: value['evidence'] as String,
  );
}

class PlanPreview {
  const PlanPreview({
    required this.payload,
    required this.hash,
    required this.token,
    required this.expiresAt,
  });
  final Map<String, dynamic> payload;
  final String hash, token;
  final DateTime expiresAt;
  bool get expired => !expiresAt.isAfter(DateTime.now());
  Map<String, dynamic> toJson() => {
    'payload': payload,
    'hash': hash,
    'previewToken': token,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  };
  factory PlanPreview.fromJson(Map<String, dynamic> value) => PlanPreview(
    payload: Map<String, dynamic>.from(value['payload'] as Map),
    hash: value['hash'] as String,
    token: value['previewToken'] as String,
    expiresAt: DateTime.parse(value['expiresAt'] as String),
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
      },
    );
    return PlanPreview.fromJson(value);
  }

  Future<PlanRecord> generate({
    required PlanPreview preview,
    required String operationId,
    required bool confirmed,
    required bool syntheticDataConfirmed,
  }) async {
    if (!confirmed || !syntheticDataConfirmed) {
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
      },
    );
    return PlanRecord.fromJson(
      Map<String, dynamic>.from(value['record'] as Map),
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
    'AI_PROVIDER_UNAVAILABLE' => 'تعذّر التوليد عبر Gemini. احتُفظ بالمدخلات؛ أنشئي معاينة جديدة قبل إعادة الإرسال.',
    'AI_PREVIOUS_FAILED' => 'فشل الطلب السابق دون إنشاء خطة. احتُفظ بالمدخلات؛ أنشئي معاينة جديدة وأكّدي إرسالها لإعادة المحاولة.',
    'AI_OUTPUT_INVALID' =>
      'لم تجتز المسودة فحوص البنية أو السلامة؛ لم تُعرض ولم تُعتمد.',
    'REVISION_CONFLICT' =>
      'تغيّرت الخطة على الخادم. حدّثي القائمة وراجعي أحدث نسخة قبل الاعتماد.',
    _ => error.message,
  };
}

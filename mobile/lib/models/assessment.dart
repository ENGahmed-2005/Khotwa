import 'initial_assessment.dart' show educationalTextIssue;

const structuredObservationLabels = <String, String>{
  'pencilGrip': 'ملاحظة مسك القلم',
  'writingDirection': 'اتجاه الكتابة',
  'letterDots': 'نقاط الحروف',
  'taaForms': 'التاء المفتوحة والمربوطة',
  'tanween': 'التنوين',
  'spellingNotes': 'ملاحظات الإملاء',
  'solutionMethod': 'طريقة حل المسألة',
};

List<String> structuredKeysForTask(String itemId) {
  if (const {'2a', '2b', '5a', '5b'}.contains(itemId)) {
    return structuredObservationLabels.keys
        .where((key) => key != 'solutionMethod')
        .toList();
  }
  return itemId.startsWith('3') || itemId.startsWith('6')
      ? ['solutionMethod']
      : [];
}

String? structuredObservationIssue(Map<String, String> values) {
  if (values.keys.any((key) => !structuredObservationLabels.containsKey(key))) {
    return 'حقل الملاحظة المنظمة غير معروف.';
  }
  if (values.values.any((value) => value.length > 1000)) {
    return 'كل ملاحظة منظمة لا تتجاوز 1000 حرف.';
  }
  return educationalTextIssue(values.values);
}

enum AssessmentStatus { draft, completed, approved }

enum ItemExecution { notDone, performed, unable }

enum ItemJudgment {
  independentCorrect,
  supportedCorrect,
  incorrect,
  notScorable,
}

enum SupportLevel { independent, verbal, partial, full }

class AssessmentItemResult {
  const AssessmentItemResult({
    this.execution = ItemExecution.notDone,
    this.judgment,
    this.support = SupportLevel.independent,
    this.response = '',
    this.observation = '',
    this.readingSeconds,
    this.readingErrors,
    this.wordsRead,
    this.selfCorrections,
    this.structuredObservations = const {},
  });

  final ItemExecution execution;
  final ItemJudgment? judgment;
  final SupportLevel support;
  final String response;
  final String observation;
  final int? readingSeconds;
  final int? readingErrors;
  final int? wordsRead;
  final int? selfCorrections;
  final Map<String, String> structuredObservations;

  bool get isScorable =>
      execution == ItemExecution.performed &&
      judgment != null &&
      judgment != ItemJudgment.notScorable;
  bool get isIndependentCorrect =>
      isScorable && judgment == ItemJudgment.independentCorrect;

  Map<String, dynamic> toJson() => {
    'execution': execution.name,
    'judgment': judgment?.name,
    'support': support.name,
    'response': response,
    'observation': observation,
    'readingSeconds': readingSeconds,
    'readingErrors': readingErrors,
    'wordsRead': wordsRead,
    'selfCorrections': selfCorrections,
    if (structuredObservations.isNotEmpty)
      'structuredObservations': {...structuredObservations},
  };

  factory AssessmentItemResult.fromJson(Map<String, dynamic> json) =>
      AssessmentItemResult(
        execution: ItemExecution.values.byName(json['execution'] as String),
        judgment: (json['judgment'] as String?) == null
            ? null
            : ItemJudgment.values.byName(json['judgment'] as String),
        support: SupportLevel.values.byName(json['support'] as String),
        response: (json['response'] as String?) ?? '',
        observation: (json['observation'] as String?) ?? '',
        readingSeconds: (json['readingSeconds'] as num?)?.toInt(),
        readingErrors: (json['readingErrors'] as num?)?.toInt(),
        wordsRead: (json['wordsRead'] as num?)?.toInt(),
        selfCorrections: (json['selfCorrections'] as num?)?.toInt(),
        structuredObservations: _readStructuredObservations(
          json['structuredObservations'],
        ),
      );

  static Map<String, String> _readStructuredObservations(Object? raw) {
    final values = Map<String, String>.from((raw as Map?) ?? {});
    final issue = structuredObservationIssue(values);
    if (issue != null) {
      throw FormatException(issue);
    }
    return values;
  }
}

class AssessmentRecord {
  const AssessmentRecord({
    required this.id,
    required this.studentId,
    required this.ageGroup,
    required this.templateVersion,
    required this.createdAt,
    this.status = AssessmentStatus.draft,
    this.ageOverrideReason = '',
    this.results = const {},
    this.strengths = '',
    this.needs = '',
    this.approvedAt,
    this.privacyReviewed = false,
    this.assessedOn,
    this.gradeAtAssessment,
  });

  final String id;
  final String studentId;
  final String ageGroup;
  final String templateVersion;
  final String createdAt;
  final AssessmentStatus status;
  final String ageOverrideReason;
  final Map<String, AssessmentItemResult> results;
  final String strengths;
  final String needs;
  final String? approvedAt;
  final bool privacyReviewed;
  final String? assessedOn, gradeAtAssessment;

  AssessmentRecord copyWith({
    Map<String, AssessmentItemResult>? results,
    String? strengths,
    String? needs,
    AssessmentStatus? status,
    String? approvedAt,
  }) => AssessmentRecord(
    id: id,
    studentId: studentId,
    ageGroup: ageGroup,
    templateVersion: templateVersion,
    createdAt: createdAt,
    ageOverrideReason: ageOverrideReason,
    results: results ?? this.results,
    strengths: strengths ?? this.strengths,
    needs: needs ?? this.needs,
    status: status ?? this.status,
    approvedAt: approvedAt ?? this.approvedAt,
    privacyReviewed: privacyReviewed,
    assessedOn: assessedOn,
    gradeAtAssessment: gradeAtAssessment,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'studentId': studentId,
    'ageGroup': ageGroup,
    'templateVersion': templateVersion,
    'createdAt': createdAt,
    'status': status.name,
    'ageOverrideReason': ageOverrideReason,
    'results': results.map((key, value) => MapEntry(key, value.toJson())),
    'strengths': strengths,
    'needs': needs,
    'approvedAt': approvedAt,
    'privacyReviewed': privacyReviewed,
    if (assessedOn != null) 'assessedOn': assessedOn,
    if (gradeAtAssessment != null) 'gradeAtAssessment': gradeAtAssessment,
  };

  factory AssessmentRecord.fromJson(Map<String, dynamic> data) {
    final raw = (data['results'] as Map<String, dynamic>?) ?? {};
    return AssessmentRecord(
      id: data['id'] as String,
      studentId: data['studentId'] as String,
      ageGroup: data['ageGroup'] as String,
      templateVersion: data['templateVersion'] as String,
      createdAt: data['createdAt'] as String,
      status: AssessmentStatus.values.byName(data['status'] as String),
      ageOverrideReason: (data['ageOverrideReason'] as String?) ?? '',
      results: raw.map(
        (key, value) => MapEntry(
          key,
          AssessmentItemResult.fromJson(
            Map<String, dynamic>.from(value as Map),
          ),
        ),
      ),
      strengths: (data['strengths'] as String?) ?? '',
      needs: (data['needs'] as String?) ?? '',
      approvedAt: data['approvedAt'] as String?,
      privacyReviewed: data['privacyReviewed'] == true,
      assessedOn: data['assessedOn'] as String?,
      gradeAtAssessment: data['gradeAtAssessment'] as String?,
    );
  }
}

class AssessmentScore {
  const AssessmentScore({
    required this.independentCorrect,
    required this.scorable,
  });
  final int independentCorrect;
  final int scorable;
  String get label => '$independentCorrect من $scorable';

  /// Describes only items performed and judged as scorable.
  /// Never treat this score as a standardized diagnostic measure.
  static AssessmentScore fromResults(Iterable<AssessmentItemResult> items) {
    final scorable = items.where((item) => item.isScorable).toList();
    return AssessmentScore(
      independentCorrect: scorable
          .where((item) => item.isIndependentCorrect)
          .length,
      scorable: scorable.length,
    );
  }
}

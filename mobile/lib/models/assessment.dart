enum AssessmentStatus { draft, completed, approved }
enum ItemExecution { notDone, performed, unable }
enum ItemJudgment { independentCorrect, supportedCorrect, incorrect, notScorable }
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

  bool get isScorable => execution == ItemExecution.performed &&
      judgment != null && judgment != ItemJudgment.notScorable;
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
      );
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
      results: raw.map((key, value) => MapEntry(
          key, AssessmentItemResult.fromJson(Map<String, dynamic>.from(value as Map)))),
      strengths: (data['strengths'] as String?) ?? '',
      needs: (data['needs'] as String?) ?? '',
      approvedAt: data['approvedAt'] as String?,
      privacyReviewed: data['privacyReviewed'] == true,
    );
  }
}

class AssessmentScore {
  const AssessmentScore({required this.independentCorrect, required this.scorable});
  final int independentCorrect;
  final int scorable;
  String get label => '$independentCorrect من $scorable';

  /// Describes only items performed and judged as scorable.
  /// Never treat this score as a standardized diagnostic measure.
  static AssessmentScore fromResults(Iterable<AssessmentItemResult> items) {
    final scorable = items.where((item) => item.isScorable).toList();
    return AssessmentScore(
      independentCorrect: scorable.where((item) => item.isIndependentCorrect).length,
      scorable: scorable.length,
    );
  }
}

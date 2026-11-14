const supportLevels = <String, String>{
  'independent': 'مستقل',
  'verbal': 'لفظي',
  'partial': 'جزئي',
  'full': 'كلي',
};
const sessionStatuses = <String, String>{
  'completed': 'تمت',
  'absent': 'غاب الطالب',
  'cancelled': 'ألغيت',
};

class InterventionSession {
  const InterventionSession({
    required this.id,
    required this.studentId,
    required this.planVersionId,
    required this.goalId,
    required this.occurredOn,
    required this.createdAt,
    this.status = 'completed',
    this.total,
    this.correct,
    this.support,
    this.engagement,
    this.durationMinutes,
    this.activityId,
    this.notes = '',
    this.privacyReviewed = false,
  });
  final String id,
      studentId,
      planVersionId,
      goalId,
      occurredOn,
      createdAt,
      status,
      notes;
  final int? total, correct, durationMinutes;
  final String? support, engagement, activityId;
  final bool privacyReviewed;
  double? get accuracy =>
      status == 'completed' && total != null && total! > 0 && correct != null
      ? correct! / total! * 100
      : null;
  Map<String, dynamic> toJson() => {
    'id': id,
    'studentId': studentId,
    'planVersionId': planVersionId,
    'goalId': goalId,
    'occurredOn': occurredOn,
    'createdAt': createdAt,
    'status': status,
    'total': total,
    'correct': correct,
    'support': support,
    'engagement': engagement,
    'durationMinutes': durationMinutes,
    'activityId': activityId,
    'notes': notes,
    'privacyReviewed': privacyReviewed,
  };
  factory InterventionSession.fromJson(Map<String, dynamic> data) =>
      InterventionSession(
        id: data['id'] as String,
        studentId: data['studentId'] as String,
        planVersionId: data['planVersionId'] as String,
        goalId: data['goalId'] as String,
        occurredOn: data['occurredOn'] as String,
        createdAt: data['createdAt'] as String,
        status: data['status'] as String,
        total: (data['total'] as num?)?.toInt(),
        correct: (data['correct'] as num?)?.toInt(),
        support: data['support'] as String?,
        engagement: data['engagement'] as String?,
        durationMinutes: (data['durationMinutes'] as num?)?.toInt(),
        activityId: data['activityId'] as String?,
        notes: data['notes'] as String? ?? '',
        privacyReviewed: data['privacyReviewed'] == true,
      );
  String? validate({DateTime? now}) {
    if (!sessionStatuses.containsKey(status)) return 'حالة الجلسة غير صالحة.';
    final parsed = DateTime.tryParse(occurredOn);
    if (parsed == null ||
        occurredOn.length != 10 ||
        parsed.toIso8601String().substring(0, 10) != occurredOn ||
        occurredOn.compareTo(
              (now ?? DateTime.now()).toIso8601String().substring(0, 10),
            ) >
            0) {
      return 'لا يمكن تسجيل أداء بتاريخ مستقبلي.';
    }
    if (!privacyReviewed || notes.length > 2000) {
      return 'راجعي خصوصية الملاحظات وحدها الأقصى.';
    }
    if (status == 'completed') {
      if (total == null ||
          total! <= 0 ||
          correct == null ||
          correct! < 0 ||
          correct! > total!) {
        return 'يلزم عدد محاولات موجب، والصحيح بين صفر وعدد المحاولات.';
      }
      if (!supportLevels.containsKey(support) ||
          engagement == null ||
          engagement!.trim().isEmpty ||
          engagement!.length > 100) {
        return 'حددي مستوى الدعم ووصف التفاعل.';
      }
      if (durationMinutes != null &&
          (durationMinutes! < 1 || durationMinutes! > 1440)) {
        return 'المدة غير صالحة.';
      }
    } else if ([
      total,
      correct,
      support,
      engagement,
      durationMinutes,
    ].any((v) => v != null)) {
      return 'جلسة الغياب أو الإلغاء لا تحمل نتائج أداء أو مدة.';
    }
    return null;
  }
}

class AttendanceSummary {
  const AttendanceSummary(this.completed, this.scheduled);
  final int completed, scheduled;
  double? get percent => scheduled == 0 ? null : completed / scheduled * 100;
  factory AttendanceSummary.fromSessions(
    Iterable<InterventionSession> sessions,
  ) {
    final scheduled = sessions.where((s) => s.status != 'cancelled').toList();
    return AttendanceSummary(
      scheduled.where((s) => s.status == 'completed').length,
      scheduled.length,
    );
  }
}

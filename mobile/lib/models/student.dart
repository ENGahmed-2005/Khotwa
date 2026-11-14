class StudentRecord {
  const StudentRecord({
    required this.id,
    required this.code,
    required this.grade,
    required this.ageYears,
    required this.ageMonths,
    required this.consentConfirmed,
    required this.consentDate,
    required this.createdAt,
    this.gender = 'unspecified',
    this.referralReason = '',
    this.classroomObservation = '',
    this.difficulties = '',
    this.familyNotes = '',
    this.teacherNotes = '',
    this.proposedDurationWeeks = 8,
    this.sessionsPerWeek = 2,
    this.sessionMinutes = 30,
  });

  final String id;
  final String code;
  final String grade;
  final int ageYears;
  final int ageMonths;
  final bool consentConfirmed;
  final String consentDate;
  final String createdAt;
  final String gender,
      referralReason,
      classroomObservation,
      difficulties,
      familyNotes,
      teacherNotes;
  final int proposedDurationWeeks, sessionsPerWeek, sessionMinutes;

  int get ageInMonths => ageYears * 12 + ageMonths;
  String get ageLabel => '$ageYears سنوات و$ageMonths أشهر';

  Map<String, dynamic> toJson() => {
    'id': id,
    'code': code,
    'grade': grade,
    'ageYears': ageYears,
    'ageMonths': ageMonths,
    'consentConfirmed': consentConfirmed,
    'consentDate': consentDate,
    'createdAt': createdAt,
    'gender': gender,
    'referralReason': referralReason,
    'classroomObservation': classroomObservation,
    'difficulties': difficulties,
    'familyNotes': familyNotes,
    'teacherNotes': teacherNotes,
    'proposedDurationWeeks': proposedDurationWeeks,
    'sessionsPerWeek': sessionsPerWeek,
    'sessionMinutes': sessionMinutes,
  };

  factory StudentRecord.fromJson(Map<String, dynamic> data) => StudentRecord(
    id: data['id'] as String,
    code: data['code'] as String,
    grade: data['grade'] as String,
    ageYears: (data['ageYears'] as num).toInt(),
    ageMonths: (data['ageMonths'] as num).toInt(),
    consentConfirmed: data['consentConfirmed'] == true,
    consentDate: (data['consentDate'] as String?) ?? '',
    createdAt: data['createdAt'] as String,
    gender: data['gender'] as String? ?? 'unspecified',
    referralReason: data['referralReason'] as String? ?? '',
    classroomObservation: data['classroomObservation'] as String? ?? '',
    difficulties: data['difficulties'] as String? ?? '',
    familyNotes: data['familyNotes'] as String? ?? '',
    teacherNotes: data['teacherNotes'] as String? ?? '',
    proposedDurationWeeks:
        (data['proposedDurationWeeks'] as num?)?.toInt() ?? 8,
    sessionsPerWeek: (data['sessionsPerWeek'] as num?)?.toInt() ?? 2,
    sessionMinutes: (data['sessionMinutes'] as num?)?.toInt() ?? 30,
  );
}

const supportedSchoolGrades = <String>[
  'التمهيدي',
  'الأول الأساسي',
  'الثاني الأساسي',
  'الثالث الأساسي',
  'الرابع الأساسي',
  'الخامس الأساسي',
  'السادس الأساسي',
  'السابع الأساسي',
  'الثامن الأساسي',
  'التاسع الأساسي',
  'العاشر الأساسي',
  'الحادي عشر',
  'الثاني عشر',
];

class StudentInputValidator {
  static String? validate({
    required String code,
    required String grade,
    required int ageYears,
    required int ageMonths,
    required bool consentConfirmed,
  }) {
    if (!RegExp(r'^ST-[0-9A-F]{8}$').hasMatch(code)) {
      return 'رمز الطالب يجب أن يكون مولّدًا عشوائيًا دون اسم.';
    }
    if (!supportedSchoolGrades.contains(grade)) {
      return 'اختر الصف الدراسي من القائمة المعتمدة.';
    }
    if (ageYears < 3 || ageYears > 21 || ageMonths < 0 || ageMonths > 11) {
      return 'يرجى إدخال العمر بالسنوات والأشهر بصورة صحيحة.';
    }
    if (!consentConfirmed) {
      return 'يلزم إقرار الموافقة المؤسسية المطلوبة قبل إنشاء ملف.';
    }
    return null;
  }
}

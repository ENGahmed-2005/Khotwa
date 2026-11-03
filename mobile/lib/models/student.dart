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
  });

  final String id;
  final String code;
  final String grade;
  final int ageYears;
  final int ageMonths;
  final bool consentConfirmed;
  final String consentDate;
  final String createdAt;

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

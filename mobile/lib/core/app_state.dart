import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/assessment_templates.dart';
import '../models/assessment.dart';
import '../models/student.dart';
import 'secure_local_store.dart';

class AppState extends ChangeNotifier {
  AppState(this._store);

  final LocalStore _store;
  final List<StudentRecord> _students = [];
  final List<AssessmentRecord> _assessments = [];
  String? storageError;

  List<StudentRecord> get students => List.unmodifiable(_students);
  List<AssessmentRecord> get assessments => List.unmodifiable(_assessments);

  String _newId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  String get _now => DateTime.now().toUtc().toIso8601String();

  Future<void> load() async {
    try {
      final raw = await _store.read();
      if (raw == null || raw.isEmpty) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['schemaVersion'] != 1) {
        throw StateError('صيغة بيانات غير مدعومة. يلزم تحديث أو ترحيل آمن.');
      }
      _students
        ..clear()
        ..addAll(((data['students'] as List?) ?? [])
            .map((e) => StudentRecord.fromJson(Map<String, dynamic>.from(e as Map))));
      _assessments
        ..clear()
        ..addAll(((data['assessments'] as List?) ?? [])
            .map((e) => AssessmentRecord.fromJson(Map<String, dynamic>.from(e as Map))));
      storageError = null;
    } catch (error) {
      // Fail closed: never overwrite an unreadable encrypted snapshot.
      storageError = error.toString();
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final data = {
      'schemaVersion': 1,
      'students': _students.map((s) => s.toJson()).toList(),
      'assessments': _assessments.map((a) => a.toJson()).toList(),
    };
    await _store.write(jsonEncode(data));
    notifyListeners();
  }

  Future<StudentRecord> createStudent({
    required String code,
    required String grade,
    required int ageYears,
    required int ageMonths,
    required bool consentConfirmed,
  }) async {
    final cleaned = code.trim().toUpperCase();
    final validation = StudentInputValidator.validate(
      code: cleaned,
      grade: grade,
      ageYears: ageYears,
      ageMonths: ageMonths,
      consentConfirmed: consentConfirmed,
    );
    if (validation != null) throw StateError(validation);
    if (_students.any((student) => student.code == cleaned)) {
      throw StateError('رمز الطالب مستخدم بالفعل. اختر رمزًا آخر.');
    }
    final record = StudentRecord(
      id: _newId(),
      code: cleaned,
      grade: grade.trim(),
      ageYears: ageYears,
      ageMonths: ageMonths,
      consentConfirmed: true,
      consentDate: _now,
      createdAt: _now,
    );
    _students.add(record);
    await _save();
    return record;
  }

  StudentRecord studentById(String id) =>
      _students.firstWhere((student) => student.id == id);

  List<AssessmentRecord> assessmentsFor(String studentId) =>
      _assessments.where((a) => a.studentId == studentId).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  AssessmentRecord assessmentById(String id) =>
      _assessments.firstWhere((a) => a.id == id);

  Future<AssessmentRecord> createAssessment({
    required String studentId,
    String? overrideGroup,
    String overrideReason = '',
  }) async {
    final student = studentById(studentId);
    if (!student.consentConfirmed) {
      throw StateError('الموافقة مطلوبة قبل التقييم.');
    }
    final recommended = recommendedAgeGroup(student);
    if (recommended == null) {
      throw StateError('لا توجد بطاقات جاهزة خارج 6–12 سنة. التقييم اليدوي لم يُنفذ بعد.');
    }
    final group = overrideGroup ?? recommended;
    if (!const {'6-8', '9-12'}.contains(group)) {
      throw StateError('فئة عمرية غير صالحة.');
    }
    if (group != recommended && overrideReason.trim().isEmpty) {
      throw StateError('اختيار بطاقة مغايرة يتطلب مسوّغًا تربويًا موثقًا.');
    }
    final result = AssessmentRecord(
      id: _newId(),
      studentId: studentId,
      ageGroup: group,
      templateVersion: assessmentTemplateVersion,
      createdAt: _now,
      ageOverrideReason: group == recommended ? '' : overrideReason.trim(),
    );
    _assessments.add(result);
    await _save();
    return result;
  }

  Future<void> saveResult({
    required String assessmentId,
    required String itemId,
    required AssessmentItemResult result,
  }) async {
    final index = _assessments.indexWhere((a) => a.id == assessmentId);
    if (index < 0) throw StateError('التقييم غير موجود.');
    final assessment = _assessments[index];
    if (assessment.status == AssessmentStatus.approved) {
      throw StateError('التقييم المعتمد للقراءة فقط؛ أنشئ تقييمًا جديدًا.');
    }
    if (!tasksForAge(assessment.ageGroup).any((task) => task.id == itemId)) {
      throw StateError('البند لا ينتمي إلى هذا القالب.');
    }
    final newMap = Map<String, AssessmentItemResult>.from(assessment.results);
    newMap[itemId] = result;
    _assessments[index] = assessment.copyWith(results: newMap);
    await _save();
  }

  Future<void> saveSummary({
    required String assessmentId,
    required String strengths,
    required String needs,
  }) async {
    final index = _assessments.indexWhere((a) => a.id == assessmentId);
    if (index < 0) throw StateError('التقييم غير موجود.');
    final assessment = _assessments[index];
    if (assessment.status == AssessmentStatus.approved) {
      throw StateError('لا يمكن تغيير ملخص معتمد.');
    }
    _assessments[index] = assessment.copyWith(
      strengths: strengths.trim(),
      needs: needs.trim(),
      status: AssessmentStatus.completed,
    );
    await _save();
  }

  /// Approval is explicit; no AI or automated diagnostic classification.
  Future<void> approveAssessment(String assessmentId) async {
    final index = _assessments.indexWhere((a) => a.id == assessmentId);
    if (index < 0) throw StateError('التقييم غير موجود.');
    final assessment = _assessments[index];
    if (assessment.status == AssessmentStatus.approved) return;
    final taskIds = tasksForAge(assessment.ageGroup).map((task) => task.id);
    if (!taskIds.every(assessment.results.containsKey)) {
      throw StateError('مرّ على جميع البنود واحفظ حالة كل مهمة قبل الاعتماد، حتى لو لم تُجرَ.');
    }
    if (assessment.strengths.isEmpty || assessment.needs.isEmpty) {
      throw StateError('راجِع وأدخل ملخص نقاط القوة والاحتياج أولًا.');
    }
    final values = assessment.results.values
        .where((value) => value.execution == ItemExecution.performed)
        .toList();
    if (values.isEmpty) {
      throw StateError('لا يمكن اعتماد تقييم لم تُنفّذ فيه مهام.');
    }
    if (values.any((value) => value.judgment == null)) {
      throw StateError('حدد حكم المختصة لكل مهمة منفذة قبل الاعتماد.');
    }
    _assessments[index] = assessment.copyWith(
      status: AssessmentStatus.approved,
      approvedAt: _now,
    );
    await _save();
  }

  Future<void> clearPrototypeData() async {
    await _store.clear();
    _students.clear();
    _assessments.clear();
    notifyListeners();
  }
}

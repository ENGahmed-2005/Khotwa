import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/assessment_templates.dart';
import '../models/assessment.dart';
import '../models/student.dart';
import '../models/sync_record.dart';
import '../models/initial_assessment.dart';
import '../models/intervention_session.dart';
import 'plan_api.dart';
import 'api_client.dart';
import 'secure_local_store.dart';

class AppState extends ChangeNotifier {
  AppState(
    this._store, {
    required this.ownerId,
    required this.deviceId,
    LocalStore? draftStore,
  }) : _draftStore = draftStore;
  final LocalStore _store;
  final LocalStore? _draftStore;
  final String ownerId, deviceId;
  Map<String, SyncRecord> _records = {};
  List<Map<String, dynamic>> _outbox = [];
  Map<String, Map<String, dynamic>> _conflicts = {};
  List<Map<String, dynamic>> _history = [];
  Map<String, Map<String, dynamic>> _drafts = {};
  Map<String, String> _draftCompletions = {};
  Future<void> _tail = Future.value();
  Future<void> _draftTail = Future.value();
  Future<void>? _activeRecordWrite, _activeDraftWrite;
  bool _disposed = false, _accountDeleted = false;
  bool get accountDeleted => _accountDeleted;
  bool get active => !_disposed && !_accountDeleted;
  static final _draftDrains = <String, Set<Future<void> Function()>>{};
  static void registerDraftDrain(String owner, Future<void> Function() drain) {
    (_draftDrains[owner] ??= {}).add(drain);
  }

  static void unregisterDraftDrain(
    String owner,
    Future<void> Function() drain,
  ) {
    _draftDrains[owner]?.remove(drain);
    if (_draftDrains[owner]?.isEmpty ?? false) _draftDrains.remove(owner);
  }

  static Future<void> flushDraftsForOwner(String owner) async {
    await Future.wait(
      (List<Future<void> Function()>.from(
        _draftDrains[owner] ?? {},
      )).map((drain) => drain()),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) super.notifyListeners();
  }

  String? storageError, syncError;
  bool syncing = false;
  String? lastSyncedAt;
  static const _uuid = Uuid();
  String get _now => DateTime.now().toUtc().toIso8601String();
  int get pendingCount => _outbox.length;
  Map<String, Map<String, dynamic>> get conflicts =>
      Map.unmodifiable(_conflicts);
  List<StudentRecord> get students => _records.values
      .where((r) => r.kind == 'student' && r.deletedAt == null)
      .map((r) => StudentRecord.fromJson(r.data))
      .toList();
  List<AssessmentRecord> get assessments => _records.values
      .where((r) => r.kind == 'assessment' && r.deletedAt == null)
      .map((r) => AssessmentRecord.fromJson(r.data))
      .toList();
  List<InitialAssessmentRecord> get initialAssessments => _records.values
      .where((r) => r.kind == 'initialAssessment' && r.deletedAt == null)
      .map((r) => InitialAssessmentRecord.fromJson(r.data))
      .toList();
  List<InterventionSession> get sessions => _records.values
      .where((r) => r.kind == 'session' && r.deletedAt == null)
      .map((r) => InterventionSession.fromJson(r.data))
      .toList();
  List<PlanRecord> get plans => _records.values
      .where((r) => r.kind == 'plan' && r.deletedAt == null)
      .map((r) => PlanRecord.fromJson(r.toJson()))
      .toList();
  List<Map<String, dynamic>> activitiesForGoal(String goalId) => _records.values
      .where(
        (r) =>
            r.kind == 'activity' &&
            r.deletedAt == null &&
            r.data['goalId'] == goalId,
      )
      .map((r) => {'id': r.id, ...r.data})
      .toList();
  bool guideSeen = false;
  String stateFor(String id) => _conflicts.containsKey(id)
      ? 'conflict'
      : _outbox.any((o) => o['entityId'] == id && o['error'] != null)
      ? 'error'
      : _outbox.any((o) => o['entityId'] == id)
      ? 'pending'
      : 'synced';

  Future<T> _serial<T>(Future<T> Function() action) {
    final future = _tail.then((_) => action());
    _tail = future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return future;
  }

  Future<void> load() async {
    try {
      final raw = await _store.read();
      if (raw != null) {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        if (data['schemaVersion'] != 2 || data['ownerId'] != ownerId) {
          throw StateError('صيغة أو مالك التخزين غير مطابق.');
        }
        _records = {
          for (final r in data['records'] as List)
            (r as Map)['id'] as String: SyncRecord.fromJson(
              Map<String, dynamic>.from(r),
            ),
        };
        _outbox = (data['outbox'] as List)
            .map((o) => Map<String, dynamic>.from(o as Map))
            .toList();
        _conflicts = (data['conflicts'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map)),
        );
        _history = ((data['history'] as List?) ?? [])
            .map((o) => Map<String, dynamic>.from(o as Map))
            .toList();
        lastSyncedAt = data['lastSyncedAt'] as String?;
        guideSeen = data['guideSeen'] == true;
        _drafts = ((data['drafts'] as Map?) ?? {}).map(
          (key, value) =>
              MapEntry(key as String, Map<String, dynamic>.from(value as Map)),
        );
        _draftCompletions = Map<String, String>.from(
          (data['draftCompletions'] as Map?) ?? {},
        );
      }
      if (_draftStore != null) {
        final legacyDrafts = _drafts;
        final draftRaw = await _draftStore.read();
        if (draftRaw != null) {
          final data = jsonDecode(draftRaw) as Map<String, dynamic>;
          if (data['schemaVersion'] != 1 || data['ownerId'] != ownerId) {
            throw StateError('صيغة مسودات أو حساب غير مطابق.');
          }
          final separateDrafts = (data['drafts'] as Map).map(
            (key, value) => MapEntry(
              key as String,
              Map<String, dynamic>.from(value as Map),
            ),
          );
          _drafts = {...legacyDrafts, ...separateDrafts};
        }
        _removeCompletedDrafts();
        if (legacyDrafts.isNotEmpty) {
          // Copy legacy inputs durably before removing them from the records
          // snapshot. A restart between these writes keeps both recoverable.
          storageError = null;
          await _mutateDrafts(() => _drafts);
          await _commit();
        }
      }
      storageError = null;
    } catch (_) {
      storageError =
          'تعذّر فتح البيانات المحلية بأمان. لن تُستبدل البيانات الموجودة.';
    }
    _notify();
  }

  Future<void> _commit({
    Map<String, SyncRecord>? records,
    List<Map<String, dynamic>>? outbox,
    Map<String, Map<String, dynamic>>? conflicts,
    List<Map<String, dynamic>>? history,
    String? syncedAt,
    bool? hasSeenGuide,
    Map<String, Map<String, dynamic>>? drafts,
    String? completeDraftKey,
  }) async {
    if (_disposed) {
      throw StateError('أُغلقت جلسة السجلات؛ تبقى مدخلات النموذج في مسودتها.');
    }
    if (_accountDeleted) {
      throw StateError(
        'حُذفت بيانات هذا الحساب؛ لا يمكن إعادة فتح نطاق الكتابة القديم.',
      );
    }
    if (storageError != null) {
      throw StateError(storageError!);
    }
    final nextRecords = records ?? _records;
    final nextOutbox = outbox ?? _outbox;
    final nextConflicts = conflicts ?? _conflicts;
    final nextHistory = history ?? _history;
    final nextDraftCompletions = {..._draftCompletions};
    final completedSnapshotId = _drafts[completeDraftKey]?['_snapshotId'];
    if (_draftStore != null && completedSnapshotId is String) {
      nextDraftCompletions[completeDraftKey!] = completedSnapshotId;
    }
    final writing = _store.write(
      jsonEncode({
        'schemaVersion': 2,
        'ownerId': ownerId,
        'records': nextRecords.values.map((r) => r.toJson()).toList(),
        'outbox': nextOutbox,
        'conflicts': nextConflicts,
        'history': nextHistory,
        'lastSyncedAt': syncedAt ?? lastSyncedAt,
        'guideSeen': hasSeenGuide ?? guideSeen,
        'drafts': _draftStore == null
            ? (drafts ?? _drafts)
            : <String, dynamic>{},
        'draftCompletions': nextDraftCompletions,
      }),
    );
    _activeRecordWrite = writing;
    try {
      await writing;
    } finally {
      if (identical(_activeRecordWrite, writing)) _activeRecordWrite = null;
    }
    if (_accountDeleted) {
      throw StateError('حُذف الحساب أثناء الكتابة؛ أُغلق نطاقه.');
    }
    _records = nextRecords;
    _outbox = nextOutbox;
    _conflicts = nextConflicts;
    _history = nextHistory;
    lastSyncedAt = syncedAt ?? lastSyncedAt;
    guideSeen = hasSeenGuide ?? guideSeen;
    _drafts = drafts ?? _drafts;
    _draftCompletions = nextDraftCompletions;
    _removeCompletedDrafts();
    _notify();
  }

  void _removeCompletedDrafts() {
    _drafts = Map.fromEntries(
      _drafts.entries.where(
        (entry) =>
            entry.value['_snapshotId'] == null ||
            _draftCompletions[entry.key] != entry.value['_snapshotId'],
      ),
    );
  }

  Future<void> _cleanCompletedDrafts() async {
    try {
      await _mutateDrafts(() => _drafts);
    } catch (_) {
      // The completion marker already committed with records and outbox. A
      // cleanup failure cannot restore the completed input or duplicate a save.
    }
  }

  Map<String, dynamic> _operation(SyncRecord record, int baseRevision) => {
    'operationId': _uuid.v4(),
    'deviceId': deviceId,
    'entityId': record.id,
    'kind': record.kind,
    'parentId': record.parentId,
    'baseRevision': baseRevision,
    'occurredAt': _now,
    'action': record.deletedAt == null ? 'upsert' : 'delete',
    'data': jsonDecode(jsonEncode(record.data)),
  };
  Future<void> _put(
    String kind,
    String id,
    Map<String, dynamic> data, {
    String? parentId,
    String? clearDraftKey,
  }) async {
    if (_conflicts.containsKey(id)) {
      throw StateError('حل تعارض المزامنة أولًا؛ النسختان محفوظتان.');
    }
    final previous = _records[id];
    final record = SyncRecord(
      id: id,
      kind: kind,
      parentId: parentId,
      data: Map<String, dynamic>.from(jsonDecode(jsonEncode(data)) as Map),
      revision: previous?.revision ?? 0,
      createdAt: previous?.createdAt ?? _now,
      updatedAt: _now,
    );
    final waiting = _outbox.where((o) => o['entityId'] == id).length;
    await _commit(
      records: {..._records, id: record},
      outbox: [..._outbox, _operation(record, record.revision + waiting)],
      drafts: clearDraftKey == null || _draftStore != null
          ? null
          : ({..._drafts}..remove(clearDraftKey)),
      completeDraftKey: clearDraftKey,
    );
    if (clearDraftKey != null && _draftStore != null) {
      await _cleanCompletedDrafts();
    }
  }

  Future<StudentRecord> createStudent({
    String? id,
    required String grade,
    required int ageYears,
    required int ageMonths,
    required bool consentConfirmed,
    String gender = 'unspecified',
    String referralReason = '',
    String classroomObservation = '',
    String difficulties = '',
    String familyNotes = '',
    String teacherNotes = '',
    int proposedDurationWeeks = 8,
    int sessionsPerWeek = 2,
    int sessionMinutes = 30,
    bool privacyReviewed = false,
    String? draftKey,
  }) => _serial(() async {
    if (id != null &&
        (!RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
              caseSensitive: false,
            ).hasMatch(id) ||
            _records.containsKey(id))) {
      throw StateError('معرّف ملف جديد غير صالح أو مستخدم.');
    }
    final random = Random.secure();
    String code;
    do {
      code =
          'ST-${List.generate(4, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join().toUpperCase()}';
    } while (students.any((s) => s.code == code));
    final validation = StudentInputValidator.validate(
      code: code,
      grade: grade,
      ageYears: ageYears,
      ageMonths: ageMonths,
      consentConfirmed: consentConfirmed,
    );
    if (validation != null) {
      throw StateError(validation);
    }
    _validateIntake(
      gender: gender,
      texts: [
        referralReason,
        classroomObservation,
        difficulties,
        familyNotes,
        teacherNotes,
      ],
      weeks: proposedDurationWeeks,
      sessionsPerWeek: sessionsPerWeek,
      minutes: sessionMinutes,
      privacyReviewed: privacyReviewed,
    );
    final student = StudentRecord(
      id: id ?? _uuid.v4(),
      code: code,
      grade: grade,
      ageYears: ageYears,
      ageMonths: ageMonths,
      consentConfirmed: true,
      consentDate: _now,
      createdAt: _now,
      gender: gender,
      referralReason: referralReason.trim(),
      classroomObservation: classroomObservation.trim(),
      difficulties: difficulties.trim(),
      familyNotes: familyNotes.trim(),
      teacherNotes: teacherNotes.trim(),
      proposedDurationWeeks: proposedDurationWeeks,
      sessionsPerWeek: sessionsPerWeek,
      sessionMinutes: sessionMinutes,
    );
    await _put(
      'student',
      student.id,
      student.toJson(),
      clearDraftKey: draftKey,
    );
    return student;
  });
  StudentRecord studentById(String id) =>
      students.firstWhere((s) => s.id == id);
  void _validateIntake({
    required String gender,
    required List<String> texts,
    required int weeks,
    required int sessionsPerWeek,
    required int minutes,
    required bool privacyReviewed,
  }) {
    if (!const {'male', 'female', 'unspecified'}.contains(gender) ||
        weeks < 1 ||
        weeks > 104 ||
        sessionsPerWeek < 1 ||
        sessionsPerWeek > 14 ||
        minutes < 1 ||
        minutes > 240) {
      throw StateError('راجعي الجنس ومدة الخطة وعدد الجلسات وزمنها.');
    }
    if (!privacyReviewed && texts.any((text) => text.trim().isNotEmpty)) {
      throw StateError('يلزم تأكيد مراجعة خصوصية الحقول الحرة.');
    }
    final issue = educationalTextIssue(texts);
    if (issue != null) throw StateError(issue);
  }

  Future<void> updateStudentIntake(
    StudentRecord student, {
    required bool privacyReviewed,
    String? draftKey,
  }) => _serial(() async {
    final old = studentById(student.id);
    if (old.code != student.code ||
        old.createdAt != student.createdAt ||
        old.consentDate != student.consentDate) {
      throw StateError('رمز الطالب وتاريخ إنشاء الملف والموافقة ثابتة.');
    }
    final issue = StudentInputValidator.validate(
      code: student.code,
      grade: student.grade,
      ageYears: student.ageYears,
      ageMonths: student.ageMonths,
      consentConfirmed: student.consentConfirmed,
    );
    if (issue != null) throw StateError(issue);
    _validateIntake(
      gender: student.gender,
      texts: [
        student.referralReason,
        student.classroomObservation,
        student.difficulties,
        student.familyNotes,
        student.teacherNotes,
      ],
      weeks: student.proposedDurationWeeks,
      sessionsPerWeek: student.sessionsPerWeek,
      minutes: student.sessionMinutes,
      privacyReviewed: privacyReviewed,
    );
    await _put(
      'student',
      student.id,
      student.toJson(),
      clearDraftKey: draftKey,
    );
  });
  List<InitialAssessmentRecord> initialAssessmentsFor(String studentId) =>
      initialAssessments.where((a) => a.studentId == studentId).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  InitialAssessmentRecord initialAssessmentById(String id) =>
      initialAssessments.firstWhere((a) => a.id == id);
  Future<InitialAssessmentRecord> createInitialAssessment(String studentId) =>
      _serial(() async {
        if (!studentById(studentId).consentConfirmed) {
          throw StateError('الموافقة مطلوبة.');
        }
        final assessment = InitialAssessmentRecord(
          id: _uuid.v4(),
          studentId: studentId,
          createdAt: _now,
          assessedOn: DateTime.now().toIso8601String().substring(0, 10),
          privacyReviewed: true,
        );
        await _put(
          'initialAssessment',
          assessment.id,
          assessment.toJson(),
          parentId: studentId,
        );
        return assessment;
      });
  Future<void> saveInitialAssessment(
    InitialAssessmentRecord next, {
    bool approve = false,
    String? draftKey,
  }) => _serial(() async {
    final old = initialAssessmentById(next.id);
    if (old.approved) {
      throw StateError('التقييم المعتمد للقراءة فقط؛ أنشئي إعادة تقييم جديدة.');
    }
    if (next.studentId != old.studentId ||
        next.createdAt != old.createdAt ||
        next.status != 'draft' ||
        next.approvedAt != null) {
      throw StateError('ارتباط التقييم ثابت والاعتماد إجراء منفصل.');
    }
    final issue = next.validate(forApproval: approve);
    if (issue != null) throw StateError(issue);
    if (approve &&
        next.method == 'academicCards' &&
        !assessments.any(
          (a) =>
              a.id == next.academicAssessmentId &&
              a.studentId == next.studentId &&
              a.status == AssessmentStatus.approved,
        )) {
      throw StateError('اختاري بطاقة معتمدة تخص هذا الطالب.');
    }
    final saved = approve
        ? next.copyWith(status: 'approved', approvedAt: _now)
        : next;
    await _put(
      'initialAssessment',
      saved.id,
      saved.toJson(),
      parentId: saved.studentId,
      clearDraftKey: draftKey,
    );
  });
  Future<void> cachePlanRecords(List<PlanRecord> values) => _serial(() async {
    final next = {..._records};
    for (final value in values) {
      if (!students.any((s) => s.id == value.studentId)) continue;
      final previous = next[value.id];
      if (previous == null ||
          (previous.deletedAt == null && value.revision >= previous.revision)) {
        next[value.id] = SyncRecord.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(jsonEncode(value.envelope)) as Map,
          ),
        );
      }
    }
    await _commit(records: next);
  });
  Future<void> markGuideSeen() => _serial(() => _commit(hasSeenGuide: true));
  Map<String, dynamic>? draftFor(String key) => _drafts[key] == null
      ? null
      : (Map<String, dynamic>.from(jsonDecode(jsonEncode(_drafts[key])) as Map)
          ..remove('_snapshotId'));
  Future<void> saveDraft(String key, Map<String, dynamic> value) {
    final snapshot = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(value)) as Map,
    );
    return _mutateDrafts(
      () => {
        ..._drafts,
        key: {...snapshot, '_snapshotId': _uuid.v4()},
      },
    );
  }

  Future<void> clearDraft(String key) =>
      _mutateDrafts(() => {..._drafts}..remove(key));
  Future<void> completeDraft(String key) => _serial(() async {
    await _commit(
      drafts: _draftStore == null ? ({..._drafts}..remove(key)) : null,
      completeDraftKey: key,
    );
    if (_draftStore != null) await _cleanCompletedDrafts();
  });
  Future<void> _mutateDrafts(
    Map<String, Map<String, dynamic>> Function() build,
  ) {
    if (_draftStore == null) return _serial(() => _commit(drafts: build()));
    final next = _draftTail.then((_) async {
      if (_accountDeleted) throw StateError('حُذفت بيانات الحساب.');
      if (storageError != null) throw StateError(storageError!);
      final drafts = {
        for (final entry in build().entries)
          entry.key: {
            ...entry.value,
            '_snapshotId': entry.value['_snapshotId'] ?? _uuid.v4(),
          },
      };
      final writing = _draftStore.write(
        jsonEncode({'schemaVersion': 1, 'ownerId': ownerId, 'drafts': drafts}),
      );
      _activeDraftWrite = writing;
      try {
        await writing;
      } finally {
        if (identical(_activeDraftWrite, writing)) _activeDraftWrite = null;
      }
      if (_accountDeleted) {
        throw StateError('حُذفت بيانات الحساب أثناء حفظ المسودة.');
      }
      _drafts = drafts;
      _removeCompletedDrafts();
      _notify();
    });
    _draftTail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> saveSessions(
    List<InterventionSession> batch, {
    String? draftKey,
  }) => _serial(() async {
    if (batch.isEmpty ||
        batch.length > 50 ||
        batch.map((s) => s.id).toSet().length != batch.length) {
      throw StateError('اختاري من جلسة إلى 50 جلسة بلا تكرار.');
    }
    final records = {..._records};
    final outbox = [..._outbox];
    for (final session in batch) {
      final issue = session.validate();
      if (issue != null) throw StateError(issue);
      final privacyIssue = educationalTextIssue([
        session.notes,
        session.engagement ?? '',
      ]);
      if (privacyIssue != null) throw StateError(privacyIssue);
      studentById(session.studentId);
      final possible = plans.where(
        (p) =>
            p.id == session.planVersionId &&
            p.studentId == session.studentId &&
            p.approved,
      );
      if (possible.isEmpty ||
          !(possible.single.content['goals'] as List).any(
            (g) => (g as Map)['id'] == session.goalId,
          )) {
        throw StateError('الجلسة ترتبط بهدف وخطة معتمدة تخص هذا الطالب.');
      }
      if (session.activityId != null &&
          !activitiesForGoal(
            session.goalId,
          ).any((a) => a['id'] == session.activityId)) {
        throw StateError('النشاط غير مرتبط بهذا الهدف.');
      }
      if (records.containsKey(session.id)) {
        if (jsonEncode(records[session.id]!.data) ==
            jsonEncode(session.toJson())) {
          continue;
        }
        throw StateError('معرّف جلسة مكرر؛ لم يتغير السجل السابق.');
      }
      final record = SyncRecord(
        id: session.id,
        kind: 'session',
        parentId: session.studentId,
        revision: 0,
        data: session.toJson(),
        createdAt: session.createdAt,
        updatedAt: _now,
      );
      records[session.id] = record;
      outbox.add(_operation(record, 0));
    }
    await _commit(
      records: records,
      outbox: outbox,
      drafts: draftKey == null || _draftStore != null
          ? null
          : ({..._drafts}..remove(draftKey)),
      completeDraftKey: draftKey,
    );
    if (draftKey != null && _draftStore != null) await _cleanCompletedDrafts();
  });
  List<AssessmentRecord> assessmentsFor(String studentId) =>
      assessments.where((a) => a.studentId == studentId).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  AssessmentRecord assessmentById(String id) =>
      assessments.firstWhere((a) => a.id == id);
  Future<AssessmentRecord> createAssessment({
    required String studentId,
    String? overrideGroup,
    String overrideReason = '',
    required bool privacyReviewed,
  }) => _serial(() async {
    if (!privacyReviewed) {
      throw StateError('راجع تعهّد الخصوصية أولًا.');
    }
    final student = studentById(studentId);
    if (!student.consentConfirmed) {
      throw StateError('الموافقة مطلوبة قبل التقييم.');
    }
    final recommended = recommendedAgeGroup(student);
    if (recommended == null) {
      throw StateError(
        'العمر خارج نطاق البطاقات. استخدمي التقييم التربوي الحر.',
      );
    }
    final group = overrideGroup ?? recommended;
    if (!const {'6-8', '9-12'}.contains(group)) {
      throw StateError('فئة عمرية غير صالحة.');
    }
    if (group != recommended && overrideReason.trim().isEmpty) {
      throw StateError('يلزم مسوّغ تربوي لاختيار فئة أخرى.');
    }
    if (overrideReason.length > 500) {
      throw StateError('المسوّغ أطول من الحد المسموح.');
    }
    final createdAt = _now;
    final assessment = AssessmentRecord(
      id: _uuid.v4(),
      studentId: studentId,
      ageGroup: group,
      templateVersion: assessmentTemplateVersion,
      createdAt: createdAt,
      assessedOn: createdAt.substring(0, 10),
      gradeAtAssessment: student.grade,
      ageOverrideReason: group == recommended ? '' : overrideReason.trim(),
      privacyReviewed: true,
    );
    await _put(
      'assessment',
      assessment.id,
      assessment.toJson(),
      parentId: studentId,
    );
    return assessment;
  });
  void _editable(AssessmentRecord a) {
    if (a.status == AssessmentStatus.approved) {
      throw StateError('التقييم المعتمد للقراءة فقط؛ أنشئ تقييمًا جديدًا.');
    }
    if (a.templateVersion != assessmentTemplateVersion) {
      throw StateError('قالب قديم محفوظ للقراءة فقط. أنشئ تقييمًا جديدًا.');
    }
  }

  Future<void> saveResult({
    required String assessmentId,
    required String itemId,
    required AssessmentItemResult result,
    String? draftKey,
  }) => _serial(() async {
    final a = assessmentById(assessmentId);
    _editable(a);
    final tasks = tasksForAge(a.ageGroup).where((t) => t.id == itemId);
    if (tasks.isEmpty) {
      throw StateError('البند لا ينتمي لهذا القالب.');
    }
    final task = tasks.single;
    if (result.execution != ItemExecution.performed &&
        result.judgment != null) {
      throw StateError('البند غير المنفذ لا يُصحّح.');
    }
    if (result.execution == ItemExecution.performed &&
        !task.isObjective &&
        result.judgment != ItemJudgment.notScorable) {
      throw StateError('هذا البند وصفي ولا تُطبّق عليه درجة عددية.');
    }
    if (result.judgment == ItemJudgment.independentCorrect &&
        result.support != SupportLevel.independent) {
      throw StateError('الحكم المستقل يتطلب أداءً دون مساعدة.');
    }
    if ([
      result.readingSeconds,
      result.readingErrors,
      result.wordsRead,
      result.selfCorrections,
    ].any((v) => v != null && v < 0)) {
      throw StateError('أدخل عددًا غير سالب.');
    }
    if (result.response.length > 160 || result.observation.length > 500) {
      throw StateError('النص أطول من الحد المسموح.');
    }
    final textIssue =
        educationalTextIssue([result.response, result.observation]) ??
        structuredObservationIssue(result.structuredObservations);
    if (textIssue != null) {
      throw StateError(textIssue);
    }
    if (result.structuredObservations.keys.any(
      (key) => !structuredKeysForTask(itemId).contains(key),
    )) {
      throw StateError('الملاحظة المنظمة لا تنتمي إلى هذا البند.');
    }
    final next = a.copyWith(
      results: {...a.results, itemId: result},
      status: AssessmentStatus.draft,
    );
    await _put(
      'assessment',
      a.id,
      next.toJson(),
      parentId: a.studentId,
      clearDraftKey: draftKey,
    );
  });
  Future<void> saveSummary({
    required String assessmentId,
    required String strengths,
    required String needs,
    required bool privacyReviewed,
    String? draftKey,
  }) => _serial(() async {
    final a = assessmentById(assessmentId);
    _editable(a);
    if (!privacyReviewed) {
      throw StateError('أكد مراجعة خلو النصوص من البيانات التعريفية والصحية.');
    }
    if (strengths.length > 350 || needs.length > 350) {
      throw StateError('النص أطول من الحد المسموح.');
    }
    final textIssue = educationalTextIssue([strengths, needs]);
    if (textIssue != null) {
      throw StateError(textIssue);
    }
    final allVisited = tasksForAge(
      a.ageGroup,
    ).every((t) => a.results.containsKey(t.id));
    final performed = a.results.values.where(
      (r) => r.execution == ItemExecution.performed,
    );
    final complete =
        allVisited &&
        performed.isNotEmpty &&
        performed.every((r) => r.judgment != null) &&
        strengths.trim().isNotEmpty &&
        needs.trim().isNotEmpty;
    final next = a.copyWith(
      strengths: strengths.trim(),
      needs: needs.trim(),
      status: complete ? AssessmentStatus.completed : AssessmentStatus.draft,
    );
    await _put(
      'assessment',
      a.id,
      next.toJson(),
      parentId: a.studentId,
      clearDraftKey: draftKey,
    );
  });
  Future<void> approveAssessment(String assessmentId) => _serial(() async {
    final a = assessmentById(assessmentId);
    _editable(a);
    if (!tasksForAge(a.ageGroup).every((t) => a.results.containsKey(t.id))) {
      throw StateError('احفظ حالة كل بند قبل الاعتماد.');
    }
    if (a.strengths.isEmpty || a.needs.isEmpty) {
      throw StateError('أدخل نقاط القوة والاحتياج أولًا.');
    }
    final performed = a.results.values.where(
      (r) => r.execution == ItemExecution.performed,
    );
    if (performed.isEmpty || performed.any((r) => r.judgment == null)) {
      throw StateError('يلزم أداء مسجل وحكم المختصة لكل بند منفذ.');
    }
    await _put(
      'assessment',
      a.id,
      a.copyWith(status: AssessmentStatus.approved, approvedAt: _now).toJson(),
      parentId: a.studentId,
    );
  });
  Future<void> sync(ApiClient api, String token) => _serial(() async {
    syncing = true;
    syncError = null;
    _notify();
    try {
      final blocked = <String>{..._conflicts.keys};
      for (final queued in List<Map<String, dynamic>>.from(_outbox)) {
        final id = queued['entityId'] as String;
        if (blocked.contains(id) || blocked.contains(queued['parentId'])) {
          continue;
        }
        final op = Map<String, dynamic>.from(queued)
          ..remove('error')
          ..remove('attempts');
        await _commit(
          outbox: _outbox
              .map(
                (o) => o['operationId'] == op['operationId']
                    ? {...o, 'attempts': ((o['attempts'] as int?) ?? 0) + 1}
                    : o,
              )
              .toList(),
        );
        final response = await api.request(
          'POST',
          '/v1/sync/push',
          token: token,
          data: {
            'operations': [op],
          },
        );
        final result = Map<String, dynamic>.from(
          (response['results'] as List).single as Map,
        );
        if (result['operationId'] != op['operationId']) {
          throw StateError('استجابة مزامنة غير مطابقة.');
        }
        if (result['status'] == 'applied') {
          final server = SyncRecord.fromJson(
            Map<String, dynamic>.from(result['record'] as Map),
          );
          final remaining = _outbox
              .where((o) => o['operationId'] != op['operationId'])
              .toList();
          final hasLater = remaining.any((o) => o['entityId'] == id);
          final local = _records[id]!;
          await _commit(
            records: {
              ..._records,
              id: hasLater
                  ? SyncRecord(
                      id: id,
                      kind: local.kind,
                      parentId: local.parentId,
                      data: local.data,
                      revision: server.revision,
                      deletedAt: local.deletedAt,
                      createdAt: local.createdAt,
                      updatedAt: local.updatedAt,
                    )
                  : server,
            },
            outbox: remaining,
          );
        } else if (result['status'] == 'conflict') {
          blocked.add(id);
          await _commit(
            conflicts: {
              ..._conflicts,
              id: {
                'local': _records[id]!.toJson(),
                'server': result['record'],
                'detectedAt': _now,
              },
            },
          );
        } else {
          blocked.add(id);
          await _commit(
            outbox: _outbox
                .map(
                  (o) => o['operationId'] == op['operationId']
                      ? {
                          ...o,
                          'error':
                              (result['error'] as Map?)?['code'] ?? 'rejected',
                        }
                      : o,
                )
                .toList(),
          );
          syncError = 'رفض الخادم بعض التغييرات. احتُفظ بها محليًا للمراجعة.';
        }
      }
      final response = await api.request('GET', '/v1/sync/pull', token: token);
      final next = {..._records};
      final conflicts = {..._conflicts};
      for (final value in response['records'] as List) {
        final server = SyncRecord.fromJson(
          Map<String, dynamic>.from(value as Map),
        );
        final pending = _outbox.where((o) => o['entityId'] == server.id);
        if (pending.isNotEmpty) {
          if (server.revision > (pending.first['baseRevision'] as int)) {
            conflicts[server.id] = {
              'local': _records[server.id]!.toJson(),
              'server': server.toJson(),
              'detectedAt': _now,
            };
          }
        } else {
          next[server.id] = server;
        }
      }
      await _commit(records: next, conflicts: conflicts, syncedAt: _now);
    } catch (error) {
      syncError = error is ApiException
          ? error.message
          : 'تعذّرت المزامنة الآمنة. احتُفظ بالعمل لإعادة المحاولة.';
    } finally {
      syncing = false;
      _notify();
    }
  });
  Future<void> resolveConflict(
    String id, {
    required bool keepLocal,
  }) => _serial(() async {
    final conflict = _conflicts[id];
    if (conflict == null) {
      return;
    }
    final server = SyncRecord.fromJson(
      Map<String, dynamic>.from(conflict['server'] as Map),
    );
    final local = _records[id]!;
    if (keepLocal &&
        (server.deletedAt != null || server.data['status'] == 'approved')) {
      throw StateError(
        'لا يمكن الكتابة فوق حذف أو اعتماد. احتفظ بالنسخة المؤرشفة وأنشئ سجلًا جديدًا.',
      );
    }
    final outbox = _outbox.where((o) => o['entityId'] != id).toList();
    final conflicts = {..._conflicts}..remove(id);
    if (keepLocal) {
      outbox.add(_operation(local, server.revision));
    }
    await _commit(
      records: {
        ..._records,
        id: keepLocal
            ? SyncRecord(
                id: id,
                kind: local.kind,
                parentId: local.parentId,
                data: local.data,
                revision: server.revision,
                createdAt: local.createdAt,
                updatedAt: _now,
              )
            : server,
      },
      outbox: outbox,
      conflicts: conflicts,
      history: [
        ..._history,
        {
          ...conflict,
          'resolution': keepLocal ? 'local' : 'server',
          'resolvedAt': _now,
        },
      ],
    );
  });
  Future<void> deleteLocalAfterAccountDeletion() async {
    _accountDeleted = true;
    // Revoke now; wait for local I/O, never for a pending network response.
    for (final writing in [_activeRecordWrite, _activeDraftWrite]) {
      if (writing != null) {
        try {
          await writing;
        } catch (_) {}
      }
    }
    await _store.clear();
    await _draftStore?.clear();
    _records = {};
    _outbox = [];
    _conflicts = {};
    _history = [];
    _drafts = {};
    _draftCompletions = {};
    _notify();
  }
}

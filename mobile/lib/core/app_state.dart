import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../data/assessment_templates.dart';
import '../models/assessment.dart';
import '../models/student.dart';
import '../models/sync_record.dart';
import 'api_client.dart';
import 'secure_local_store.dart';

class AppState extends ChangeNotifier {
  AppState(this._store, {required this.ownerId, required this.deviceId});
  final LocalStore _store;
  final String ownerId, deviceId;
  Map<String, SyncRecord> _records = {};
  List<Map<String, dynamic>> _outbox = [];
  Map<String, Map<String, dynamic>> _conflicts = {};
  List<Map<String, dynamic>> _history = [];
  Future<void> _tail = Future.value();
  String? storageError, syncError;
  bool syncing = false;
  String? lastSyncedAt;
  static const _uuid = Uuid();
  String get _now => DateTime.now().toUtc().toIso8601String();
  int get pendingCount => _outbox.length;
  Map<String, Map<String, dynamic>> get conflicts => Map.unmodifiable(_conflicts);
  List<StudentRecord> get students => _records.values.where((r) => r.kind == 'student' && r.deletedAt == null).map((r) => StudentRecord.fromJson(r.data)).toList();
  List<AssessmentRecord> get assessments => _records.values.where((r) => r.kind == 'assessment' && r.deletedAt == null).map((r) => AssessmentRecord.fromJson(r.data)).toList();
  String stateFor(String id) => _conflicts.containsKey(id) ? 'conflict' : _outbox.any((o) => o['entityId'] == id && o['error'] != null) ? 'error' : _outbox.any((o) => o['entityId'] == id) ? 'pending' : 'synced';

  Future<T> _serial<T>(Future<T> Function() action) {
    final future = _tail.then((_) => action());
    _tail = future.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return future;
  }
  Future<void> load() async {
    try {
      final raw = await _store.read();
      if (raw != null) {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        if (data['schemaVersion'] != 2 || data['ownerId'] != ownerId) throw StateError('صيغة أو مالك التخزين غير مطابق.');
        _records = {for (final r in data['records'] as List) (r as Map)['id'] as String: SyncRecord.fromJson(Map<String,dynamic>.from(r))};
        _outbox = (data['outbox'] as List).map((o) => Map<String,dynamic>.from(o as Map)).toList();
        _conflicts = (data['conflicts'] as Map<String,dynamic>).map((k,v) => MapEntry(k, Map<String,dynamic>.from(v as Map)));
        _history = ((data['history'] as List?) ?? []).map((o) => Map<String,dynamic>.from(o as Map)).toList();
        lastSyncedAt = data['lastSyncedAt'] as String?;
      }
      storageError = null;
    } catch (_) { storageError = 'تعذّر فتح البيانات المحلية بأمان. لن تُستبدل البيانات الموجودة.'; }
    notifyListeners();
  }
  Future<void> _commit({Map<String, SyncRecord>? records, List<Map<String,dynamic>>? outbox, Map<String,Map<String,dynamic>>? conflicts, List<Map<String,dynamic>>? history, String? syncedAt}) async {
    if (storageError != null) throw StateError(storageError!);
    final nextRecords = records ?? _records;
    final nextOutbox = outbox ?? _outbox;
    final nextConflicts = conflicts ?? _conflicts;
    final nextHistory = history ?? _history;
    await _store.write(jsonEncode({'schemaVersion': 2, 'ownerId': ownerId, 'records': nextRecords.values.map((r) => r.toJson()).toList(), 'outbox': nextOutbox, 'conflicts': nextConflicts, 'history': nextHistory, 'lastSyncedAt': syncedAt ?? lastSyncedAt}));
    _records = nextRecords; _outbox = nextOutbox; _conflicts = nextConflicts; _history = nextHistory;
    lastSyncedAt = syncedAt ?? lastSyncedAt;
    notifyListeners();
  }
  Map<String,dynamic> _operation(SyncRecord record, int baseRevision) => {'operationId': _uuid.v4(), 'deviceId': deviceId, 'entityId': record.id, 'kind': record.kind, 'parentId': record.parentId, 'baseRevision': baseRevision, 'occurredAt': _now, 'action': record.deletedAt == null ? 'upsert' : 'delete', 'data': record.data};
  Future<void> _put(String kind, String id, Map<String,dynamic> data, {String? parentId}) async {
    if (_conflicts.containsKey(id)) throw StateError('حل تعارض المزامنة أولًا؛ النسختان محفوظتان.');
    final previous = _records[id];
    final record = SyncRecord(id: id, kind: kind, parentId: parentId, data: data, revision: previous?.revision ?? 0, createdAt: previous?.createdAt ?? _now, updatedAt: _now);
    final waiting = _outbox.where((o) => o['entityId'] == id).length;
    await _commit(records: {..._records, id: record}, outbox: [..._outbox, _operation(record, record.revision + waiting)]);
  }
  Future<StudentRecord> createStudent({required String grade, required int ageYears, required int ageMonths, required bool consentConfirmed}) => _serial(() async {
    final random = Random.secure();
    String code;
    do { code = 'ST-${List.generate(4, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join().toUpperCase()}'; } while (students.any((s) => s.code == code));
    final validation = StudentInputValidator.validate(code: code, grade: grade, ageYears: ageYears, ageMonths: ageMonths, consentConfirmed: consentConfirmed);
    if (validation != null) throw StateError(validation);
    final student = StudentRecord(id: _uuid.v4(), code: code, grade: grade, ageYears: ageYears, ageMonths: ageMonths, consentConfirmed: true, consentDate: _now, createdAt: _now);
    await _put('student', student.id, student.toJson());
    return student;
  });
  StudentRecord studentById(String id) => students.firstWhere((s) => s.id == id);
  List<AssessmentRecord> assessmentsFor(String studentId) => assessments.where((a) => a.studentId == studentId).toList()..sort((a,b) => b.createdAt.compareTo(a.createdAt));
  AssessmentRecord assessmentById(String id) => assessments.firstWhere((a) => a.id == id);
  Future<AssessmentRecord> createAssessment({required String studentId, String? overrideGroup, String overrideReason = '', required bool privacyReviewed}) => _serial(() async {
    if (!privacyReviewed) throw StateError('راجع تعهّد الخصوصية أولًا.');
    final student = studentById(studentId);
    if (!student.consentConfirmed) throw StateError('الموافقة مطلوبة قبل التقييم.');
    final recommended = recommendedAgeGroup(student);
    if (recommended == null) throw StateError('العمر خارج نطاق البطاقات. التقييم التربوي الحر قيد التطوير.');
    final group = overrideGroup ?? recommended;
    if (!const {'6-8','9-12'}.contains(group)) throw StateError('فئة عمرية غير صالحة.');
    if (group != recommended && overrideReason.trim().isEmpty) throw StateError('يلزم مسوّغ تربوي لاختيار فئة أخرى.');
    if (overrideReason.length > 500) throw StateError('المسوّغ أطول من الحد المسموح.');
    final assessment = AssessmentRecord(id: _uuid.v4(), studentId: studentId, ageGroup: group, templateVersion: assessmentTemplateVersion, createdAt: _now, ageOverrideReason: group == recommended ? '' : overrideReason.trim(), privacyReviewed: true);
    await _put('assessment', assessment.id, assessment.toJson(), parentId: studentId);
    return assessment;
  });
  void _editable(AssessmentRecord a) {
    if (a.status == AssessmentStatus.approved) throw StateError('التقييم المعتمد للقراءة فقط؛ أنشئ تقييمًا جديدًا.');
    if (a.templateVersion != assessmentTemplateVersion) throw StateError('قالب قديم محفوظ للقراءة فقط. أنشئ تقييمًا جديدًا.');
  }
  Future<void> saveResult({required String assessmentId, required String itemId, required AssessmentItemResult result}) => _serial(() async {
    final a = assessmentById(assessmentId); _editable(a);
    final tasks = tasksForAge(a.ageGroup).where((t) => t.id == itemId);
    if (tasks.isEmpty) throw StateError('البند لا ينتمي لهذا القالب.');
    final task = tasks.single;
    if (result.execution != ItemExecution.performed && result.judgment != null) throw StateError('البند غير المنفذ لا يُصحّح.');
    if (result.execution == ItemExecution.performed && !task.isObjective && result.judgment != ItemJudgment.notScorable) throw StateError('هذا البند وصفي ولا تُطبّق عليه درجة عددية.');
    if (result.judgment == ItemJudgment.independentCorrect && result.support != SupportLevel.independent) throw StateError('الحكم المستقل يتطلب أداءً دون مساعدة.');
    if ([result.readingSeconds, result.readingErrors, result.wordsRead, result.selfCorrections].any((v) => v != null && v < 0)) throw StateError('أدخل عددًا غير سالب.');
    if (result.response.length > 160 || result.observation.length > 500) throw StateError('النص أطول من الحد المسموح.');
    final next = a.copyWith(results: {...a.results, itemId: result});
    await _put('assessment', a.id, next.toJson(), parentId: a.studentId);
  });
  Future<void> saveSummary({required String assessmentId, required String strengths, required String needs, required bool privacyReviewed}) => _serial(() async {
    final a = assessmentById(assessmentId); _editable(a);
    if (!privacyReviewed) throw StateError('أكد مراجعة خلو النصوص من البيانات التعريفية والصحية.');
    if (strengths.length > 350 || needs.length > 350) throw StateError('النص أطول من الحد المسموح.');
    final allVisited = tasksForAge(a.ageGroup).every((t) => a.results.containsKey(t.id));
    final performed = a.results.values.where((r) => r.execution == ItemExecution.performed);
    final complete = allVisited && performed.isNotEmpty && performed.every((r) => r.judgment != null) && strengths.trim().isNotEmpty && needs.trim().isNotEmpty;
    final next = a.copyWith(strengths: strengths.trim(), needs: needs.trim(), status: complete ? AssessmentStatus.completed : AssessmentStatus.draft);
    await _put('assessment', a.id, next.toJson(), parentId: a.studentId);
  });
  Future<void> approveAssessment(String assessmentId) => _serial(() async {
    final a = assessmentById(assessmentId); _editable(a);
    if (!tasksForAge(a.ageGroup).every((t) => a.results.containsKey(t.id))) throw StateError('احفظ حالة كل بند قبل الاعتماد.');
    if (a.strengths.isEmpty || a.needs.isEmpty) throw StateError('أدخل نقاط القوة والاحتياج أولًا.');
    final performed = a.results.values.where((r) => r.execution == ItemExecution.performed);
    if (performed.isEmpty || performed.any((r) => r.judgment == null)) throw StateError('يلزم أداء مسجل وحكم المختصة لكل بند منفذ.');
    await _put('assessment', a.id, a.copyWith(status: AssessmentStatus.approved, approvedAt: _now).toJson(), parentId: a.studentId);
  });
  Future<void> sync(ApiClient api, String token) => _serial(() async {
    syncing = true; syncError = null; notifyListeners();
    try {
      final blocked = <String>{..._conflicts.keys};
      for (final queued in List<Map<String,dynamic>>.from(_outbox)) {
        final id = queued['entityId'] as String;
        if (blocked.contains(id) || blocked.contains(queued['parentId'])) continue;
        final op = Map<String,dynamic>.from(queued)..remove('error')..remove('attempts');
        await _commit(outbox: _outbox.map((o) => o['operationId'] == op['operationId'] ? {...o, 'attempts': ((o['attempts'] as int?) ?? 0) + 1} : o).toList());
        final response = await api.request('POST', '/v1/sync/push', token: token, data: {'operations': [op]});
        final result = Map<String,dynamic>.from((response['results'] as List).single as Map);
        if (result['operationId'] != op['operationId']) throw StateError('استجابة مزامنة غير مطابقة.');
        if (result['status'] == 'applied') {
          final server = SyncRecord.fromJson(Map<String,dynamic>.from(result['record'] as Map));
          final remaining = _outbox.where((o) => o['operationId'] != op['operationId']).toList();
          final hasLater = remaining.any((o) => o['entityId'] == id);
          final local = _records[id]!;
          await _commit(records: {..._records, id: hasLater ? SyncRecord(id: id, kind: local.kind, parentId: local.parentId, data: local.data, revision: server.revision, deletedAt: local.deletedAt, createdAt: local.createdAt, updatedAt: local.updatedAt) : server}, outbox: remaining);
        } else if (result['status'] == 'conflict') {
          blocked.add(id);
          await _commit(conflicts: {..._conflicts, id: {'local': _records[id]!.toJson(), 'server': result['record'], 'detectedAt': _now}});
        } else {
          blocked.add(id);
          await _commit(outbox: _outbox.map((o) => o['operationId'] == op['operationId'] ? {...o, 'error': (result['error'] as Map?)?['code'] ?? 'rejected'} : o).toList());
          syncError = 'رفض الخادم بعض التغييرات. احتُفظ بها محليًا للمراجعة.';
        }
      }
      final response = await api.request('GET', '/v1/sync/pull', token: token);
      final next = {..._records}; final conflicts = {..._conflicts};
      for (final value in response['records'] as List) {
        final server = SyncRecord.fromJson(Map<String,dynamic>.from(value as Map));
        final pending = _outbox.where((o) => o['entityId'] == server.id);
        if (pending.isNotEmpty) {
          if (server.revision > (pending.first['baseRevision'] as int)) conflicts[server.id] = {'local': _records[server.id]!.toJson(), 'server': server.toJson(), 'detectedAt': _now};
        } else { next[server.id] = server; }
      }
      await _commit(records: next, conflicts: conflicts, syncedAt: _now);
    } catch (error) { syncError = error is ApiException ? error.message : 'تعذّرت المزامنة الآمنة. احتُفظ بالعمل لإعادة المحاولة.'; }
    finally { syncing = false; notifyListeners(); }
  });
  Future<void> resolveConflict(String id, {required bool keepLocal}) => _serial(() async {
    final conflict = _conflicts[id];
    if (conflict == null) return;
    final server = SyncRecord.fromJson(Map<String,dynamic>.from(conflict['server'] as Map));
    final local = _records[id]!;
    if (keepLocal && (server.deletedAt != null || server.data['status'] == 'approved')) throw StateError('لا يمكن الكتابة فوق حذف أو اعتماد. احتفظ بالنسخة المؤرشفة وأنشئ سجلًا جديدًا.');
    final outbox = _outbox.where((o) => o['entityId'] != id).toList();
    final conflicts = {..._conflicts}..remove(id);
    if (keepLocal) outbox.add(_operation(local, server.revision));
    await _commit(records: {..._records, id: keepLocal ? SyncRecord(id: id, kind: local.kind, parentId: local.parentId, data: local.data, revision: server.revision, createdAt: local.createdAt, updatedAt: _now) : server}, outbox: outbox, conflicts: conflicts, history: [..._history, {...conflict, 'resolution': keepLocal ? 'local' : 'server', 'resolvedAt': _now}]);
  });
  Future<void> deleteLocalAfterAccountDeletion() => _serial(() async { await _store.clear(); _records = {}; _outbox = []; _conflicts = {}; _history = []; notifyListeners(); });
}

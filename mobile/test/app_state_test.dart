import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:khotwa/core/api_client.dart';
import 'package:khotwa/core/app_state.dart';
import 'package:khotwa/core/secure_local_store.dart';
import 'package:khotwa/models/assessment.dart';
import 'package:khotwa/data/assessment_templates.dart';

class FakeStore implements LocalStore {
  String? content;
  bool failWrites = false;
  @override
  Future<String?> read() async => content;
  @override
  Future<void> write(String data) async {
    if (failWrites) {
      throw StateError('disk full');
    }
    content = data;
  }

  @override
  Future<void> clear() async {
    content = null;
  }
}

AppState stateFor(
  FakeStore store, {
  String owner = 'owner-a',
  String device = 'device-a',
}) => AppState(store, ownerId: owner, deviceId: device);
Future<dynamic> addStudent(AppState state, {int age = 7}) =>
    state.createStudent(
      grade: 'الثاني الأساسي',
      ageYears: age,
      ageMonths: 0,
      consentConfirmed: true,
    );

class SyncServer {
  final records = <String, Map<String, dynamic>>{};
  final receipts = <String, Map<String, dynamic>>{};
  bool loseAcknowledgement = false;
  bool offline = false;
  int applications = 0;
  late final ApiClient api = ApiClient(
    baseUrl: 'https://test.invalid',
    client: MockClient((request) async {
      if (offline) {
        throw Exception('network disconnected');
      }
      if (request.url.path.endsWith('/pull')) {
        return http.Response(
          jsonEncode({
            'records': records.values.toList(),
            'fullSnapshot': true,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      final operation = Map<String, dynamic>.from(
        ((jsonDecode(request.body) as Map)['operations'] as List).single as Map,
      );
      final operationId = operation['operationId'] as String;
      if (receipts.containsKey(operationId)) {
        return http.Response(
          jsonEncode({
            'results': [receipts[operationId]],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      final id = operation['entityId'] as String;
      final current = records[id];
      Map<String, dynamic> result;
      if ((current?['revision'] ?? 0) != operation['baseRevision']) {
        result = {
          'operationId': operationId,
          'status': 'conflict',
          'record': current,
        };
      } else {
        final record = <String, dynamic>{
          'id': id,
          'kind': operation['kind'],
          'parentId': operation['parentId'],
          'revision': (current?['revision'] as int? ?? 0) + 1,
          'createdAt': current?['createdAt'] ?? '2026-11-02T00:00:00Z',
          'updatedAt': '2026-11-02T00:00:01Z',
          'deletedAt': operation['action'] == 'delete'
              ? '2026-11-02T00:00:01Z'
              : null,
          'data': operation['data'],
        };
        records[id] = record;
        applications++;
        result = {
          'operationId': operationId,
          'status': 'applied',
          'record': record,
        };
      }
      receipts[operationId] = result;
      if (loseAcknowledgement) {
        loseAcknowledgement = false;
        throw Exception('connection lost after commit');
      }
      return http.Response(
        jsonEncode({
          'results': [result],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );
}

void main() {
  test('consent is mandatory; code and identifier are generated', () async {
    final state = stateFor(FakeStore());
    await expectLater(
      state.createStudent(
        grade: 'الثاني الأساسي',
        ageYears: 7,
        ageMonths: 0,
        consentConfirmed: false,
      ),
      throwsStateError,
    );
    final student = await addStudent(state);
    expect(student.code, matches(r'^ST-[0-9A-F]{8}$'));
    expect(student.id, matches(r'^[0-9a-f-]{36}$'));
    expect(state.pendingCount, 1);
  });
  test(
    'failed durable write leaves memory and outbox unchanged; retry works',
    () async {
      final store = FakeStore()..failWrites = true;
      final state = stateFor(store);
      await expectLater(addStudent(state), throwsStateError);
      expect(state.students, isEmpty);
      expect(state.pendingCount, 0);
      store.failWrites = false;
      await addStudent(state);
      expect(state.students, hasLength(1));
      expect(state.pendingCount, 1);
    },
  );
  test('corrupt snapshot fails closed without overwrite', () async {
    final store = FakeStore()..content = 'broken';
    final state = stateFor(store);
    await state.load();
    expect(state.storageError, isNotNull);
    await expectLater(addStudent(state), throwsStateError);
    expect(store.content, 'broken');
  });
  test('owner mismatch cannot load or overwrite another account', () async {
    final store = FakeStore();
    await addStudent(stateFor(store));
    final other = stateFor(store, owner: 'owner-b');
    await other.load();
    expect(other.students, isEmpty);
    expect(other.storageError, isNotNull);
    await expectLater(addStudent(other), throwsStateError);
  });
  test('template 1.1 has four independently scored words', () {
    expect(assessmentTemplateVersion, '1.1');
    expect(
      tasksForAge('6-8').where((t) => t.id.startsWith('1d')).map((t) => t.id),
      ['1d1', '1d2', '1d3', '1d4'],
    );
    expect(
      tasksForAge('6-8')
          .where((t) => t.id.startsWith('1d'))
          .every((t) => t.isObjective),
      isTrue,
    );
  });
  test('assessment approval is explicit, persisted and immutable', () async {
    final store = FakeStore();
    final state = stateFor(store);
    final student = await addStudent(state);
    final assessment = await state.createAssessment(
      studentId: student.id,
      privacyReviewed: true,
    );
    await expectLater(state.approveAssessment(assessment.id), throwsStateError);
    await state.saveResult(
      assessmentId: assessment.id,
      itemId: '1a',
      result: const AssessmentItemResult(
        execution: ItemExecution.performed,
        judgment: ItemJudgment.independentCorrect,
      ),
    );
    for (final task in tasksForAge('6-8').where((t) => t.id != '1a')) {
      await state.saveResult(
        assessmentId: assessment.id,
        itemId: task.id,
        result: const AssessmentItemResult(),
      );
    }
    await state.saveSummary(
      assessmentId: assessment.id,
      strengths: 'أداء تجريبي',
      needs: 'تدريب تجريبي',
      privacyReviewed: true,
    );
    expect(
      state.assessmentById(assessment.id).status,
      AssessmentStatus.completed,
    );
    await state.approveAssessment(assessment.id);
    await expectLater(
      state.saveResult(
        assessmentId: assessment.id,
        itemId: '1a',
        result: const AssessmentItemResult(),
      ),
      throwsStateError,
    );
    final reopened = stateFor(store);
    await reopened.load();
    expect(reopened.assessments.single.status, AssessmentStatus.approved);
    expect(reopened.pendingCount, state.pendingCount);
  });
  test(
    'partial summary remains draft and cannot silently count as complete',
    () async {
      final state = stateFor(FakeStore());
      final s = await addStudent(state);
      final a = await state.createAssessment(
        studentId: s.id,
        privacyReviewed: true,
      );
      await state.saveSummary(
        assessmentId: a.id,
        strengths: 'مثال',
        needs: 'مثال',
        privacyReviewed: true,
      );
      expect(state.assessmentById(a.id).status, AssessmentStatus.draft);
      await expectLater(
        state.saveSummary(
          assessmentId: a.id,
          strengths: 'مثال',
          needs: 'مثال',
          privacyReviewed: false,
        ),
        throwsStateError,
      );
    },
  );
  test(
    'subjective tasks and independent support enforce professional rules',
    () async {
      final state = stateFor(FakeStore());
      final s = await addStudent(state);
      final a = await state.createAssessment(
        studentId: s.id,
        privacyReviewed: true,
      );
      await expectLater(
        state.saveResult(
          assessmentId: a.id,
          itemId: '2a',
          result: const AssessmentItemResult(
            execution: ItemExecution.performed,
            judgment: ItemJudgment.independentCorrect,
          ),
        ),
        throwsStateError,
      );
      await expectLater(
        state.saveResult(
          assessmentId: a.id,
          itemId: '1a',
          result: const AssessmentItemResult(
            execution: ItemExecution.performed,
            judgment: ItemJudgment.independentCorrect,
            support: SupportLevel.verbal,
          ),
        ),
        throwsStateError,
      );
      await state.saveResult(
        assessmentId: a.id,
        itemId: '2a',
        result: const AssessmentItemResult(
          execution: ItemExecution.performed,
          judgment: ItemJudgment.notScorable,
        ),
      );
    },
  );
  test('out of range age is not forced into a card; override requires reason and privacy', () async {
    final state = stateFor(FakeStore());
    final s = await addStudent(state, age: 5);
    await expectLater(
      state.createAssessment(studentId: s.id, privacyReviewed: true),
      throwsStateError,
    );
    final seven = await addStudent(state);
    await expectLater(
      state.createAssessment(
        studentId: seven.id,
        overrideGroup: '9-12',
        privacyReviewed: true,
      ),
      throwsStateError,
    );
    await expectLater(
      state.createAssessment(studentId: seven.id, privacyReviewed: false),
      throwsStateError,
    );
    expect(
      (await state.createAssessment(
        studentId: seven.id,
        overrideGroup: '9-12',
        overrideReason: 'مبرر تجريبي',
        privacyReviewed: true,
      )).ageGroup,
      '9-12',
    );
  });
  test('offline save survives restart and resumes synchronization', () async {
    final store = FakeStore();
    final state = stateFor(store);
    final server = SyncServer()..offline = true;
    await addStudent(state);
    await state.sync(server.api, 'token');
    expect(state.pendingCount, 1);
    expect(state.syncError, isNotNull);
    final restarted = stateFor(store);
    await restarted.load();
    server.offline = false;
    await restarted.sync(server.api, 'token');
    expect(restarted.pendingCount, 0);
    expect(server.applications, 1);
  });
  test(
    'lost acknowledgement retries exact operation id without duplicate record',
    () async {
      final state = stateFor(FakeStore());
      final server = SyncServer()..loseAcknowledgement = true;
      await addStudent(state);
      await state.sync(server.api, 'token');
      expect(state.pendingCount, 1);
      expect(server.applications, 1);
      await state.sync(server.api, 'token');
      expect(state.pendingCount, 0);
      expect(server.applications, 1);
    },
  );
  test('two devices conflict preserves local variant and explicit resolution archives both', () async {
    final first = stateFor(FakeStore());
    final second = stateFor(FakeStore(), device: 'device-b');
    final server = SyncServer();
    final student = await addStudent(first);
    final assessment = await first.createAssessment(
      studentId: student.id,
      privacyReviewed: true,
    );
    await first.sync(server.api, 'token');
    await second.sync(server.api, 'token');
    await first.saveResult(
      assessmentId: assessment.id,
      itemId: '1a',
      result: const AssessmentItemResult(observation: 'نسخة أولى'),
    );
    await second.saveResult(
      assessmentId: assessment.id,
      itemId: '1a',
      result: const AssessmentItemResult(observation: 'نسخة ثانية'),
    );
    await first.sync(server.api, 'token');
    await second.sync(server.api, 'token');
    expect(second.conflicts, contains(assessment.id));
    expect(
      second.assessmentById(assessment.id).results['1a']!.observation,
      'نسخة ثانية',
    );
    await second.resolveConflict(assessment.id, keepLocal: true);
    await second.sync(server.api, 'token');
    expect(second.conflicts, isEmpty);
    expect(second.pendingCount, 0);
    expect(
      (server.records[assessment.id]!['data']
          as Map)['results']['1a']['observation'],
      'نسخة ثانية',
    );
  });
  test(
    'remote tombstone is retained; missing snapshots do not imply deletion',
    () async {
      final state = stateFor(FakeStore());
      final server = SyncServer();
      final s = await addStudent(state);
      await state.sync(server.api, 'token');
      final record = server.records.remove(s.id)!;
      await state.sync(server.api, 'token');
      expect(state.students, hasLength(1));
      server.records[s.id] = {
        ...record,
        'revision': 2,
        'deletedAt': '2026-11-02T00:00:03Z',
      };
      await state.sync(server.api, 'token');
      expect(state.students, isEmpty);
    },
  );
}

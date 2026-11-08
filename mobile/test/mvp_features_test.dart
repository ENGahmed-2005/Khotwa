import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:khotwa/core/api_client.dart';
import 'package:khotwa/core/app_state.dart';
import 'package:khotwa/core/plan_api.dart';
import 'package:khotwa/features/plan_editor_screen.dart';
import 'package:khotwa/features/progress_screen.dart';
import 'package:khotwa/models/initial_assessment.dart';
import 'package:khotwa/models/intervention_session.dart';

import 'app_state_test.dart' show FakeStore, stateFor, addStudent, SyncServer;
import 'plan_api_test.dart' show syntheticPlan;

InitialDomain syntheticDomain({String level = 'developing'}) => InitialDomain(
  id: 'reading',
  label: 'القراءة والمهارات القرائية',
  currentPerformance: 'يتعرف على بعض الحروف في نشاط اصطناعي',
  strengths: 'يتابع العرض في النشاط',
  needs: 'تدريب إضافي على الحروف',
  skills: [
    InitialSkill(
      id: 'reading.letters',
      label: 'التعرف على الحروف',
      level: level,
      evidence: 'نشاط ملاحظة اصطناعي مسجل',
    ),
  ],
);
Future<PlanRecord> seedPlan(
  AppState state,
  String studentId, {
  bool approved = true,
}) async {
  final value = syntheticPlan(approved: approved);
  (value['data'] as Map)['studentId'] = studentId;
  (value['data'] as Map)['id'] = value['id'];
  value['parentId'] = studentId;
  final plan = PlanRecord.fromJson(value);
  await state.cachePlanRecords([plan]);
  return plan;
}

InterventionSession session(
  String id,
  String studentId, {
  String status = 'completed',
  int total = 5,
  int correct = 4,
  String goalId = 'synthetic-goal',
  String date = '2026-01-03',
}) => InterventionSession(
  id: id,
  studentId: studentId,
  planVersionId: 'synthetic-plan',
  goalId: goalId,
  occurredOn: date,
  createdAt: '2026-01-05T12:00:00Z',
  status: status,
  total: status == 'completed' ? total : null,
  correct: status == 'completed' ? correct : null,
  support: status == 'completed' ? 'verbal' : null,
  engagement: status == 'completed' ? 'وصف تفاعل اصطناعي' : null,
  privacyReviewed: true,
);

void main() {
  test(
    'later form changes cannot mutate durable initial records or queued operations',
    () async {
      final store = FakeStore();
      final state = stateFor(store);
      final student = await addStudent(state);
      final draft = await state.createInitialAssessment(student.id);
      final strategies = [
        {'name': 'عرض بصري', 'result': 'مشاركة في النشاط الاصطناعي'},
      ];
      await state.saveInitialAssessment(
        draft.copyWith(
          alternativeReason: 'ملاحظة تعليمية',
          domains: [syntheticDomain()],
          previousStrategies: strategies,
          privacyReviewed: true,
        ),
      );
      final persisted = store.content;
      strategies.single['result'] = 'تغيير لم يحفظ بعد';
      expect(
        state.initialAssessments.single.previousStrategies.single['result'],
        'مشاركة في النشاط الاصطناعي',
      );
      expect(store.content, persisted);
      await state.markGuideSeen();
      final snapshot = jsonDecode(store.content!) as Map;
      final queued = (snapshot['outbox'] as List).last as Map;
      expect(
        ((queued['data'] as Map)['previousStrategies'] as List)
            .single['result'],
        'مشاركة في النشاط الاصطناعي',
      );
    },
  );
  test(
    'initial manual assessment works outside card ages and approval is immutable',
    () async {
      final store = FakeStore();
      final state = stateFor(store);
      final student = await addStudent(state, age: 15);
      final draft = await state.createInitialAssessment(student.id);
      await expectLater(
        state.saveInitialAssessment(
          draft.copyWith(privacyReviewed: true),
          approve: true,
        ),
        throwsStateError,
      );
      final reviewed = draft.copyWith(
        alternativeReason: 'خارج نطاق البطاقات؛ ملاحظة أداء تعليمية',
        domains: [syntheticDomain()],
        privacyReviewed: true,
      );
      await state.saveInitialAssessment(reviewed, approve: true);
      expect(state.initialAssessments.single.approved, isTrue);
      expect(state.initialAssessments.single.hasDevelopmentNeed, isTrue);
      await expectLater(
        state.saveInitialAssessment(reviewed),
        throwsStateError,
      );
      final restored = stateFor(store);
      await restored.load();
      expect(
        restored
            .initialAssessments
            .single
            .domains
            .single
            .skills
            .single
            .evidence,
        'نشاط ملاحظة اصطناعي مسجل',
      );
    },
  );
  test(
    'all mastered can be reviewed without fabricating a development need',
    () async {
      final state = stateFor(FakeStore());
      final student = await addStudent(state);
      final draft = await state.createInitialAssessment(student.id);
      await state.saveInitialAssessment(
        draft.copyWith(
          alternativeReason: 'ملاحظة مباشرة موثقة',
          domains: [syntheticDomain(level: 'mastered')],
          privacyReviewed: true,
        ),
        approve: true,
      );
      expect(state.initialAssessments.single.hasDevelopmentNeed, isFalse);
    },
  );
  test(
    'initial approval requires evidence and owned approved academic source',
    () async {
      final state = stateFor(FakeStore());
      final student = await addStudent(state);
      final draft = await state.createInitialAssessment(student.id);
      final data = draft.copyWith(
        method: 'academicCards',
        academicAssessmentId: 'unowned',
        domains: [syntheticDomain()],
        privacyReviewed: true,
      );
      await expectLater(
        state.saveInitialAssessment(data, approve: true),
        throwsStateError,
      );
      expect(state.initialAssessments.single.approved, isFalse);
    },
  );
  test(
    'privacy review blocks contacts and clinical labels before durable intake',
    () async {
      final store = FakeStore();
      final state = stateFor(store);
      await expectLater(
        state.createStudent(
          grade: 'الثاني الأساسي',
          ageYears: 7,
          ageMonths: 0,
          consentConfirmed: true,
          referralReason: 'نشاط قراءة',
          privacyReviewed: false,
        ),
        throwsStateError,
      );
      await expectLater(
        state.createStudent(
          grade: 'الثاني الأساسي',
          ageYears: 7,
          ageMonths: 0,
          consentConfirmed: true,
          referralReason: 'contact@example.test',
          privacyReviewed: true,
        ),
        throwsStateError,
      );
      expect(state.students, isEmpty);
      expect(store.content, isNull);
      expect(educationalTextIssue(['تشخيص طبي']), isNotNull);
    },
  );
  test(
    'invalid calendar dates are rejected instead of silently normalized',
    () {
      expect(session('s', 'student', date: '2026-02-31').validate(), isNotNull);
      final initial = const InitialAssessmentRecord(
        id: 'i',
        studentId: 's',
        createdAt: '2026-01-01T00:00:00Z',
        assessedOn: '2026-02-31',
        privacyReviewed: true,
      );
      expect(initial.validate(), isNotNull);
    },
  );
  test(
    'session batch is atomic on disk failure, retry and restart preserve exact IDs',
    () async {
      final store = FakeStore();
      final state = stateFor(store);
      final student = await addStudent(state);
      await seedPlan(state, student.id);
      final before = state.pendingCount;
      final batch = [
        session('one', student.id),
        session('two', student.id, date: '2026-01-02'),
      ];
      store.failWrites = true;
      await expectLater(state.saveSessions(batch), throwsStateError);
      expect(state.sessions, isEmpty);
      expect(state.pendingCount, before);
      store.failWrites = false;
      await state.saveSessions(batch);
      expect(state.sessions, hasLength(2));
      expect(state.pendingCount, before + 2);
      await state.saveSessions(batch);
      expect(state.pendingCount, before + 2);
      final restored = stateFor(store);
      await restored.load();
      expect(restored.sessions.map((s) => s.id), ['one', 'two']);
      expect(restored.sessions.first.accuracy, 80);
    },
  );
  test(
    'invalid second session prevents first session and outbox from committing',
    () async {
      final state = stateFor(FakeStore());
      final student = await addStudent(state);
      await seedPlan(state, student.id);
      final count = state.pendingCount;
      await expectLater(
        state.saveSessions([
          session('one', student.id),
          session('two', student.id, correct: 6),
        ]),
        throwsStateError,
      );
      expect(state.sessions, isEmpty);
      expect(state.pendingCount, count);
    },
  );
  test(
    'sessions cannot reference draft plans, another student or an unknown goal',
    () async {
      final state = stateFor(FakeStore());
      final student = await addStudent(state);
      final other = await addStudent(state);
      await seedPlan(state, student.id, approved: false);
      await expectLater(
        state.saveSessions([session('one', student.id)]),
        throwsStateError,
      );
      await seedPlan(state, student.id);
      await expectLater(
        state.saveSessions([session('two', other.id)]),
        throwsStateError,
      );
      await expectLater(
        state.saveSessions([session('three', student.id, goalId: 'unknown')]),
        throwsStateError,
      );
      expect(state.sessions, isEmpty);
    },
  );
  test(
    'absence/cancellation is never a zero accuracy and attendance excludes cancellation',
    () {
      final sessions = [
        session('one', 's'),
        session('two', 's', status: 'absent'),
        session('three', 's', status: 'cancelled'),
      ];
      expect(sessions.map((s) => s.accuracy), [80, null, null]);
      final result = AttendanceSummary.fromSessions(sessions);
      expect(result.completed, 1);
      expect(result.scheduled, 2);
      expect(result.percent, 50);
      expect(
        criterionPercent({'type': 'trials', 'correct': 4, 'total': 5}),
        80,
      );
      expect(
        criterionPercent({'type': 'independence', 'support': 'verbal'}),
        isNull,
      );
    },
  );
  test(
    'offline sessions synchronize once after lost acknowledgment and restore on another device',
    () async {
      final store = FakeStore();
      final state = stateFor(store);
      final server = SyncServer();
      final student = await addStudent(state);
      await state.sync(server.api, 'synthetic');
      await seedPlan(state, student.id);
      await state.saveSessions([
        session('one', student.id),
        session('two', student.id, date: '2026-01-02'),
      ]);
      server.loseAcknowledgement = true;
      await state.sync(server.api, 'synthetic');
      expect(state.pendingCount, 2);
      final restarted = stateFor(store);
      await restarted.load();
      await restarted.sync(server.api, 'synthetic');
      expect(restarted.pendingCount, 0);
      final other = stateFor(FakeStore(), device: 'other');
      await other.sync(server.api, 'synthetic');
      expect(other.sessions, hasLength(2));
      expect(
        server.records.values.where((r) => r['kind'] == 'session'),
        hasLength(2),
      );
    },
  );
  test(
    'plan edit validates four elements, bounds and retains encrypted local draft separately',
    () async {
      final content = Map<String, dynamic>.from(
        (syntheticPlan()['data'] as Map)['content'] as Map,
      );
      expect(planContentIssue(content), isNull);
      final goal = (content['goals'] as List).single as Map;
      goal['condition'] = '';
      expect(planContentIssue(content), contains('شرط'));
      goal['condition'] = 'بطاقات';
      goal['timeframeWeeks'] = 7;
      expect(planContentIssue(content), contains('مدة'));
      final state = stateFor(FakeStore());
      await state.saveDraft('plan-edit:test', {
        'content': content,
        'operationId': 'retained',
      });
      final restored = state.draftFor('plan-edit:test')!;
      ((restored['content'] as Map)['goals'] as List).clear();
      expect(
        ((state.draftFor('plan-edit:test')!['content'] as Map)['goals']
            as List),
        hasLength(1),
      );
    },
  );
  test(
    'version retry transports same operation and only explicit confirmation; never approves',
    () async {
      final bodies = <String>[];
      final api = PlanApi(
        api: ApiClient(
          baseUrl: 'https://example.test',
          client: MockClient((r) async {
            expect(r.url.path, '/v1/plans/synthetic-plan/versions');
            bodies.add(r.body);
            if (bodies.length == 1) throw Exception('lost response');
            return http.Response(
              jsonEncode({'record': syntheticPlan()}),
              201,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        ),
        tokenForRequest: () => 'synthetic-token',
      );
      final plan = PlanRecord.fromJson(syntheticPlan(approved: true));
      Future<PlanRecord> send(bool confirmed) => api.revise(
        plan,
        operationId: 'same-operation',
        content: plan.content,
        templateOptions: {
          'showStrategies': false,
          'showRecommendations': true,
          'showSessionSchedule': true,
        },
        confirmed: confirmed,
      );
      await expectLater(send(false), throwsA(isA<ApiException>()));
      expect(bodies, isEmpty);
      await expectLater(send(true), throwsA(isA<ApiException>()));
      final draft = await send(true);
      expect(draft.approved, isFalse);
      expect(bodies[0], bodies[1]);
    },
  );
}

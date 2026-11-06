import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:khotwa/core/api_client.dart';
import 'package:khotwa/core/plan_api.dart';

Map<String, dynamic> syntheticPlan({bool approved = false}) => {
  'id': 'synthetic-plan',
  'kind': 'plan',
  'revision': approved ? 2 : 1,
  'deletedAt': null,
  'data': {
    'studentId': 'synthetic-student',
    'version': 1,
    'source': 'ai',
    'status': approved ? 'approved' : 'draft',
    'approvedAt': approved ? '2026-11-05T12:00:00Z' : null,
    'content': {
      'needsSummary': 'تدريب اصطناعي على الحروف',
      'strengthsSummary': 'مشاركة في النشاط الاصطناعي',
      'generalGoal': 'تطوير الأداء في النشاط الاصطناعي',
      'baseline': 'مستوى يحتاج إلى تطوير وفق الإدخال الاصطناعي',
      'durationWeeks': 6,
      'sessionsPerWeek': 2,
      'goals': [
        {
          'id': 'synthetic-goal',
          'skillId': 'reading.letters',
          'behavior': 'يتعرف على الحرف',
          'condition': 'عند عرض بطاقات',
          'criterion': {'type': 'trials', 'correct': 4, 'total': 5},
          'timeframeWeeks': 2,
        },
      ],
      'tools': ['بطاقات'],
      'measurementTools': ['تسجيل المحاولات'],
      'strategies': ['عرض وممارسة'],
      'recommendations': ['مراجعة الأداء'],
      'nextFollowUp': '2026-12-01',
    },
  },
};

PlanPreview syntheticPreview({bool expired = false}) => PlanPreview(
  payload: {
    'skills': [
      {
        'skillId': 'reading.letters',
        'level': 'developing',
        'evidence': 'approvedAcademicAssessment',
      },
    ],
    'durationWeeks': 6,
    'sessionsPerWeek': 2,
    'availableTools': ['cards'],
  },
  hash: 'synthetic-exact-hash',
  token: 'synthetic-signed-preview',
  expiresAt: DateTime.now().toUtc().add(Duration(minutes: expired ? -1 : 10)),
);

void main() {
  test('preview requires synthetic confirmation and an assessed development need before transport', () async {
    var requests = 0;
    final plans = PlanApi(
      api: ApiClient(
        baseUrl: 'https://example.test',
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      ),
      tokenForRequest: () => 'synthetic-token',
    );
    for (final confirmed in [false, true]) {
      await expectLater(
        plans.preview(
          studentId: 'student',
          assessmentId: 'assessment',
          skills: [
            {'skillId': 'reading.letters', 'level': 'mastered'},
          ],
          durationWeeks: 6,
          sessionsPerWeek: 2,
          availableTools: ['cards'],
          syntheticDataConfirmed: confirmed,
        ),
        throwsA(isA<ApiException>()),
      );
    }
    expect(requests, 0);
  });

  test('no generation request without both explicit confirmations', () async {
    var requests = 0;
    final plans = PlanApi(
      api: ApiClient(
        baseUrl: 'https://example.test',
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      ),
      tokenForRequest: () => 'synthetic-token',
    );
    await expectLater(
      plans.generate(
        preview: syntheticPreview(),
        operationId: 'operation',
        confirmed: false,
        syntheticDataConfirmed: true,
      ),
      throwsA(isA<ApiException>()),
    );
    await expectLater(
      plans.generate(
        preview: syntheticPreview(),
        operationId: 'operation',
        confirmed: true,
        syntheticDataConfirmed: false,
      ),
      throwsA(isA<ApiException>()),
    );
    expect(requests, 0);
  });

  test(
    'lost acknowledgment retry retains exact preview and operation identity',
    () async {
      final bodies = <Map<String, dynamic>>[];
      final plans = PlanApi(
        api: ApiClient(
          baseUrl: 'https://example.test',
          client: MockClient((request) async {
            expect(request.url.path, '/v1/ai/generate');
            expect(request.headers['authorization'], 'Bearer synthetic-token');
            bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            if (bodies.length == 1) {
              throw Exception('network response lost');
            }
            return http.Response(
              jsonEncode({'record': syntheticPlan()}),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        ),
        tokenForRequest: () => 'synthetic-token',
      );
      final preview = syntheticPreview();
      await expectLater(
        plans.generate(
          preview: preview,
          operationId: 'same-operation',
          confirmed: true,
          syntheticDataConfirmed: true,
        ),
        throwsA(isA<ApiException>()),
      );
      final result = await plans.generate(
        preview: preview,
        operationId: 'same-operation',
        confirmed: true,
        syntheticDataConfirmed: true,
      );
      expect(result.approved, isFalse);
      expect(bodies.first, bodies.last);
      expect(bodies.last.keys.toSet(), {
        'previewToken',
        'confirmed',
        'confirmedHash',
        'syntheticDataConfirmed',
        'operationId',
      });
      expect(bodies.last['confirmedHash'], preview.hash);
    },
  );

  test('server can recover a committed receipt after preview expiry', () async {
    final plans = PlanApi(
      api: ApiClient(
        baseUrl: 'https://example.test',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'record': syntheticPlan()}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      ),
      tokenForRequest: () => 'synthetic-token',
    );
    final result = await plans.generate(
      preview: syntheticPreview(expired: true),
      operationId: 'already-committed-operation',
      confirmed: true,
      syntheticDataConfirmed: true,
    );
    expect(result.id, 'synthetic-plan');
  });

  test(
    'approval is explicit and sends reviewed revision; never calls generate',
    () async {
      var requests = 0;
      final plans = PlanApi(
        api: ApiClient(
          baseUrl: 'https://example.test',
          client: MockClient((request) async {
            requests++;
            expect(request.url.path, '/v1/plans/synthetic-plan/approve');
            expect(jsonDecode(request.body), {
              'revision': 1,
              'confirmed': true,
            });
            return http.Response(
              jsonEncode({'record': syntheticPlan(approved: true)}),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        ),
        tokenForRequest: () => 'synthetic-token',
      );
      final draft = PlanRecord.fromJson(syntheticPlan());
      await expectLater(
        plans.approve(draft, confirmed: false),
        throwsA(isA<ApiException>()),
      );
      expect(requests, 0);
      final approved = await plans.approve(draft, confirmed: true);
      expect(approved.approved, isTrue);
      await expectLater(
        plans.approve(approved, confirmed: true),
        throwsA(isA<ApiException>()),
      );
      expect(requests, 1);
    },
  );

  test('plan list omits tombstones and requires authentication', () async {
    String? token = 'synthetic-token';
    final plans = PlanApi(
      api: ApiClient(
        baseUrl: 'https://example.test',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'records': [
                syntheticPlan(),
                {...syntheticPlan(), 'deletedAt': '2026-11-05T12:00:00Z'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      ),
      tokenForRequest: () => token,
    );
    expect(await plans.plans(), hasLength(1));
    token = null;
    await expectLater(
      plans.plans(),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'unauthenticated'),
      ),
    );
  });
}

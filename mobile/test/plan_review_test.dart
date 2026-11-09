import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:khotwa/core/api_client.dart';
import 'package:khotwa/core/plan_api.dart';

void main() {
  PlanPreview reviewedPreview() => PlanPreview(
    payload: {
      'skills': [
        {
          'skillId': 'custom.00000000-0000-4000-8000-000000000001',
          'reviewedLabel': 'تمييز الرموز',
          'level': 'developing',
          'evidence': 'approvedAlternativeAssessment',
        },
      ],
    },
    hash: 'a' * 64,
    token: 'synthetic-preview',
    expiresAt: DateTime.now().add(const Duration(minutes: 10)),
    customLabelsRequireConfirmation: true,
    studentReference: 'الطالبة',
  );
  test(
    'custom label preview metadata survives caching without carrying any confirmation',
    () {
      final saved = reviewedPreview().toJson();
      expect(saved.containsKey('customLabelsConfirmed'), isFalse);
      final restored = PlanPreview.fromJson(saved);
      expect(restored.hasCustomLabels, isTrue);
      expect(restored.studentReference, 'الطالبة');
      expect(restored.payload['skills'], (reviewedPreview().payload['skills']));
    },
  );
  test(
    'custom-label generation requires an additional explicit confirmation before HTTP',
    () async {
      var calls = 0;
      final api = PlanApi(
        api: ApiClient(
          baseUrl: 'https://synthetic.example.test',
          client: MockClient((request) async {
            calls++;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['customLabelsConfirmed'], isTrue);
            expect(body.containsKey('payload'), isFalse);
            return http.Response(
              jsonEncode({
                'record': {
                  'id': 'synthetic-plan',
                  'kind': 'plan',
                  'deletedAt': null,
                  'revision': 1,
                  'data': {
                    'studentId': 'synthetic-student',
                    'status': 'draft',
                    'content': {},
                    'presentation': {'studentReference': 'الطالبة'},
                  },
                },
              }),
              201,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        ),
        tokenForRequest: () => 'synthetic-token',
      );
      await expectLater(
        api.generate(
          preview: reviewedPreview(),
          operationId: 'synthetic-operation',
          confirmed: true,
          syntheticDataConfirmed: true,
        ),
        throwsA(isA<ApiException>()),
      );
      expect(calls, 0);
      final plan = await api.generate(
        preview: reviewedPreview(),
        operationId: 'synthetic-operation',
        confirmed: true,
        syntheticDataConfirmed: true,
        customLabelsConfirmed: true,
      );
      expect(calls, 1);
      expect(plan.studentReference, 'الطالبة');
    },
  );
  test(
    'operation cancellation needs its own decision and sends no generation request',
    () async {
      final paths = <String>[];
      final api = PlanApi(
        api: ApiClient(
          baseUrl: 'https://synthetic.example.test',
          client: MockClient((request) async {
            paths.add(request.url.path);
            expect(jsonDecode(request.body), {'confirmed': true});
            return http.Response(
              '{"state":"cancelled"}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
        tokenForRequest: () => 'synthetic-token',
      );
      await expectLater(
        api.cancelOperation('synthetic-operation', confirmed: false),
        throwsA(isA<ApiException>()),
      );
      expect(paths, isEmpty);
      await api.cancelOperation('synthetic-operation', confirmed: true);
      expect(paths, ['/v1/ai/operations/synthetic-operation/cancel']);
    },
  );
}

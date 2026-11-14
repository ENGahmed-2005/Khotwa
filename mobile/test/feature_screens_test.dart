import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:khotwa/core/feature_api.dart';
import 'package:khotwa/features/activities_screen.dart';
import 'package:khotwa/features/reports_screen.dart';

import 'feature_api_test.dart' show account, FeatureMemoryStore;

http.Response jsonResponse(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
Widget rtl(Widget child, {double scale = 1}) => MaterialApp(
  builder: (context, content) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: Directionality(textDirection: TextDirection.rtl, child: content!),
  ),
  home: child,
);

void main() {
  testWidgets(
    'report screen preserves unsaved encrypted header and never restores export consent',
    (tester) async {
      final requests = <http.Request>[];
      final auth = account(
        apiClient: MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/v1/reports/settings') {
            return jsonResponse({
              'revision': 8,
              'settings': {'institutionTitle': 'SERVER HEADER', 'logo': null},
            });
          }
          return jsonResponse(
            request.url.path == '/v1/reports/exports'
                ? {'exports': []}
                : {'records': []},
          );
        }),
      );
      final backing = FeatureMemoryStore();
      final store = FeatureDraftStore(auth, 'report-inputs', store: backing);
      await store.write({
        'institutionTitle': 'LOCAL UNSAVED HEADER',
        'headerDirty': true,
        'revision': 7,
        'format': 'docx',
        'privacyReviewed': true,
      });
      await tester.pumpWidget(
        rtl(ReportsScreen(auth: auth, draftStore: store)),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'LOCAL UNSAVED HEADER',
      );
      await tester.scrollUntilVisible(
        find.text('صيغة الملف'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Word قابل للتعديل'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text(
          'راجعت خلو الترويسة والشعار من بيانات أي طالب، وأوافق على تصدير ملف خارج التخزين المشفّر للتطبيق.',
        ),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      final consent = find.ancestor(
        of: find.text(
          'راجعت خلو الترويسة والشعار من بيانات أي طالب، وأوافق على تصدير ملف خارج التخزين المشفّر للتطبيق.',
        ),
        matching: find.byType(CheckboxListTile),
      );
      expect(tester.widget<CheckboxListTile>(consent).value, isFalse);
      expect(requests.where((request) => request.method != 'GET'), isEmpty);
    },
  );
  testWidgets(
    'report header edits survive offline disposal and reopening without approving an export',
    (tester) async {
      final auth = account(
        apiClient: MockClient(
          (_) async => throw http.ClientException('synthetic offline'),
        ),
      );
      final backing = FeatureMemoryStore();
      final store = FeatureDraftStore(auth, 'report-inputs', store: backing);
      await tester.pumpWidget(
        rtl(ReportsScreen(auth: auth, draftStore: store)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'ترويسة تجربة محفوظة',
      );
      await tester.pumpAndSettle();
      expect((await store.read())['institutionTitle'], 'ترويسة تجربة محفوظة');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        rtl(
          ReportsScreen(
            auth: auth,
            draftStore: FeatureDraftStore(
              auth,
              'report-inputs',
              store: backing,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'ترويسة تجربة محفوظة',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'activity preview restoration retains tool draft but requires new explicit send confirmation',
    (tester) async {
      final plan = {
        'id': '00000000-0000-4000-8000-000000000001',
        'kind': 'plan',
        'revision': 1,
        'deletedAt': null,
        'data': {
          'studentId': '00000000-0000-4000-8000-000000000002',
          'status': 'approved',
          'version': 1,
          'content': {
            'generalGoal': 'هدف تعليمي',
            'goals': [
              {
                'id': '00000000-0000-4000-8000-000000000003',
                'behavior': 'تمييز الحروف',
              },
            ],
          },
        },
      };
      final requests = <http.Request>[];
      final auth = account(
        apiClient: MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/v1/activities/tools') {
            return jsonResponse({
              'configured': true,
              'revision': 3,
              'tools': [
                {'id': 'cards', 'label': 'البطاقات'},
              ],
            });
          }
          return jsonResponse({
            'records': request.url.queryParameters['kind'] == 'plan'
                ? [plan]
                : [],
          });
        }),
      );
      final store = FeatureDraftStore(
        auth,
        'activity-inputs',
        store: FeatureMemoryStore(),
      );
      await store.write({
        'planId': plan['id'],
        'goalId': '00000000-0000-4000-8000-000000000003',
        'toolsDirty': true,
        'toolsRevision': 2,
        'configured': false,
        'tools': [
          {
            'id': 'custom.00000000-0000-4000-8000-000000000004',
            'label': 'أداة مخصصة محفوظة',
          },
        ],
        'toolIds': ['custom.00000000-0000-4000-8000-000000000004'],
        'preview': {
          'payload': {'type': 'cards'},
          'hash': 'test-hash',
          'previewToken': 'test-token',
        },
        'operationId': '00000000-0000-4000-8000-000000000005',
        'confirmed': true,
      });
      await tester.pumpWidget(
        rtl(ActivitiesScreen(auth: auth, draftStore: store)),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('أداة مخصصة محفوظة'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('أداة مخصصة محفوظة'), findsOneWidget);
      const text =
          'أوافق صراحةً على إرسال هذه الحقول المراجعة لتوليد مسودة نشاط.';
      await tester.scrollUntilVisible(
        find.text(text),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.ancestor(
                of: find.text(text),
                matching: find.byType(CheckboxListTile),
              ),
            )
            .value,
        isFalse,
      );
      expect(requests.where((request) => request.method != 'GET'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('report screen stays usable on a phone with doubled text size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = account(
      apiClient: MockClient((request) async {
        if (request.url.path.endsWith('/settings')) {
          return jsonResponse({
            'revision': 0,
            'settings': {'institutionTitle': '', 'logo': null},
          });
        }
        return jsonResponse(
          request.url.path.endsWith('/exports')
              ? {'exports': []}
              : {'records': []},
        );
      }),
    );
    await tester.pumpWidget(rtl(ReportsScreen(auth: auth), scale: 2));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('تصدير وحفظ التقرير'),
      350,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('تصدير وحفظ التقرير'), findsOneWidget);
  });
}

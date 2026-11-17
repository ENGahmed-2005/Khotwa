import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:khotwa/core/auth_state.dart';
import 'package:khotwa/core/khotwa_theme.dart';
import 'package:khotwa/features/students_screen.dart';
import 'package:khotwa/main.dart';
import 'package:khotwa/widgets/specialist_dashboard.dart';
import 'package:khotwa/widgets/khotwa_backdrop.dart';

import 'app_state_test.dart' show FakeStore, SyncServer, stateFor, addStudent;
import 'encrypted_store_test.dart' show MemorySecrets;
import 'mvp_features_test.dart' show seedPlan, session;

const capture = bool.fromEnvironment('CAPTURE_UX');
const captureDirectory = String.fromEnvironment(
  'CAPTURE_UX_DIR',
  defaultValue: '../.artifacts/ux/current',
);
final captureKey = GlobalKey();

Future<AuthState> fixture({bool populated = false}) async {
  final state = stateFor(FakeStore());
  final server = SyncServer();
  if (populated) {
    final student = await addStudent(state);
    await addStudent(state, age: 10);
    await seedPlan(state, student.id);
    await state.saveSessions([session('synthetic-session', student.id)]);
    await state.sync(server.api, 'synthetic-token');
  }
  return AuthState(
      api: server.api,
      secrets: MemorySecrets(),
      storeForOwner: (_) async => FakeStore(),
    )
    ..records = state
    ..ownerId = state.ownerId
    ..token = 'synthetic-token'
    ..email = 'synthetic-specialist@example.test';
}

Future<void> surface(
  WidgetTester tester,
  double width, {
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<void> screenshot(WidgetTester tester, String name) async {
  if (!capture) return;
  await tester.runAsync(() async {
    final context = captureKey.currentContext!;
    await Future.wait([
      precacheImage(
        ResizeImage.resizeIfNeeded(
          960,
          null,
          const AssetImage(KhotwaArtwork.room),
        ),
        context,
      ),
      precacheImage(
        ResizeImage.resizeIfNeeded(
          1280,
          null,
          const AssetImage(KhotwaArtwork.desk),
        ),
        context,
      ),
    ]);
  });
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final boundary =
        captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final picture = await boundary.toImage(pixelRatio: 2);
    final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
    final folder = Directory(captureDirectory)..createSync(recursive: true);
    await File(
      '${folder.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    picture.dispose();
  });
}

Widget app(AuthState auth) => RepaintBoundary(
  key: captureKey,
  child: KhotwaApp(auth: auth),
);

Future<void> reveal(
  WidgetTester tester,
  Finder finder, {
  double delta = 160,
}) async {
  await tester.scrollUntilVisible(
    finder,
    delta,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final arabic = FontLoader('NotoSansArabic')
      ..addFont(rootBundle.load('assets/fonts/NotoSansArabic.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait([arabic.load(), icons.load()]);
  });

  testWidgets(
    'dashboard describes actual owner records and opens the real student form',
    (tester) async {
      await surface(tester, 390);
      final auth = await fixture(populated: true);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(app(auth));
      await tester.pumpAndSettle();
      await screenshot(tester, 'home-390');
      await reveal(tester, find.text('ملفات الطلبة'));
      expect(find.bySemanticsLabel('ملفات الطلبة: 2'), findsOneWidget);
      expect(find.bySemanticsLabel('خطط معتمدة: 1'), findsOneWidget);
      expect(find.bySemanticsLabel('جلسات مسجّلة: 1'), findsOneWidget);
      semantics.dispose();
      await reveal(
        tester,
        find.byKey(const ValueKey('home-add-student')),
        delta: -160,
      );
      await tester.tap(find.byKey(const ValueKey('home-add-student')));
      await tester.pumpAndSettle();
      expect(find.byType(StudentFormScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'all dashboard tools use their actual callbacks and the guide persists completion',
    (tester) async {
      await surface(tester, 390);
      final state = stateFor(FakeStore());
      final actions = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: KhotwaTheme.light,
          home: Scaffold(
            body: Directionality(
              textDirection: TextDirection.rtl,
              child: AnimatedBuilder(
                animation: state,
                builder: (_, _) => SpecialistDashboard(
                  state: state,
                  onStudents: () => actions.add('students'),
                  onAddStudent: () => actions.add('add'),
                  onPlans: () => actions.add('plans'),
                  onSessions: () => actions.add('sessions'),
                  onProgress: () => actions.add('progress'),
                  onActivities: () => actions.add('activities'),
                  onReports: () => actions.add('reports'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var index = 0; index < 2; index++) {
        await reveal(tester, find.text('التالي'));
        await tester.tap(find.text('التالي'));
        await tester.pumpAndSettle();
      }
      await reveal(tester, find.text('فهمت، أبدأ العمل'));
      await tester.tap(find.text('فهمت، أبدأ العمل'));
      await tester.pumpAndSettle();
      expect(state.guideSeen, isTrue);
      for (final key in [
        'students',
        'plans',
        'activities',
        'sessions',
        'reports',
      ]) {
        final tile = find.byKey(ValueKey('home-$key'));
        await reveal(tester, tile);
        await tester.tap(tile);
        await tester.pumpAndSettle();
      }
      expect(actions, [
        'students',
        'plans',
        'activities',
        'sessions',
        'reports',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [320.0, 390.0, 768.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'home and account settings fit ${width.toInt()}px at ${scale}x text',
        (tester) async {
          await surface(tester, width, scale: scale);
          final auth = await fixture();
          await tester.pumpWidget(app(auth));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.drag(
            find.byType(Scrollable).first,
            const Offset(0, -650),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await screenshot(
            tester,
            'home-tools-${width.toInt()}-${scale.toInt()}x',
          );
          await tester.tap(find.text('الطلبة'));
          await tester.pumpAndSettle();
          expect(find.byType(StudentsScreen), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('الإعدادات'));
          await tester.pumpAndSettle();
          expect(find.text('الإعدادات والحساب'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets(
    'login stays usable with a keyboard and large Arabic text on a small phone',
    (tester) async {
      await surface(tester, 320, scale: 2);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      final auth = AuthState(
        api: SyncServer().api,
        secrets: MemorySecrets(),
        storeForOwner: (_) async => FakeStore(),
      );
      await tester.pumpWidget(app(auth));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('إنشاء حساب جديد'));
      await tester.tap(find.text('إنشاء حساب جديد'));
      await tester.pumpAndSettle();
      expect(find.text('إنشاء حساب المختصة'), findsOneWidget);
      final password = find.byType(TextField).at(1);
      await reveal(tester, password);
      await tester.enterText(password, 'synthetic-test-password-only');
      await reveal(tester, find.byTooltip('إظهار كلمة المرور'), delta: -120);
      await tester.tap(find.byTooltip('إظهار كلمة المرور'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(password).obscureText, isFalse);
      expect(
        tester.widget<TextField>(password).controller!.text,
        'synthetic-test-password-only',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'login is readable at phone width with the real password reveal control',
    (tester) async {
      await surface(tester, 390);
      final auth = AuthState(
        api: SyncServer().api,
        secrets: MemorySecrets(),
        storeForOwner: (_) async => FakeStore(),
      );
      await tester.pumpWidget(app(auth));
      await tester.pumpAndSettle();
      await screenshot(tester, 'login-390');
      await reveal(tester, find.byTooltip('إظهار كلمة المرور'));
      await tester.tap(find.byTooltip('إظهار كلمة المرور'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).obscureText,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

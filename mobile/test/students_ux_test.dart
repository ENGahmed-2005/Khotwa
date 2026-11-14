import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:khotwa/core/app_state.dart';
import 'package:khotwa/core/khotwa_theme.dart';
import 'package:khotwa/features/students_screen.dart';
import 'package:khotwa/models/student.dart';

import 'app_state_test.dart' show FakeStore;

AppState studentState(String owner) => AppState(
  FakeStore(),
  draftStore: FakeStore(),
  ownerId: owner,
  deviceId: 'synthetic-device',
);

Future<StudentRecord> student(
  AppState state, {
  String grade = 'الثاني الأساسي',
  int age = 7,
}) => state.createStudent(
  grade: grade,
  ageYears: age,
  ageMonths: 0,
  consentConfirmed: true,
);

Future<void> page(
  WidgetTester tester,
  Widget child, {
  double width = 390,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      key: UniqueKey(),
      theme: KhotwaTheme.light,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, widget) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: Directionality(textDirection: TextDirection.rtl, child: widget!),
      ),
      home: child,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> reveal(
  WidgetTester tester,
  Finder target, {
  double step = 300,
}) async {
  await tester.scrollUntilVisible(
    target.hitTestable(),
    step,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 50,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'search uses actual anonymized codes and grades and clearing restores every file',
    (tester) async {
      final state = studentState('student-search');
      final first = await student(state),
          second = await student(state, grade: 'الثالث الأساسي', age: 9);
      await page(tester, Scaffold(body: StudentsScreen(state: state)));
      final search = find.byKey(const ValueKey('students-search'));
      await tester.enterText(search, first.code.toLowerCase());
      await tester.pumpAndSettle();
      expect(find.text('الطالب ${first.code}'), findsOneWidget);
      expect(find.text('الطالب ${second.code}'), findsNothing);
      expect(find.text('عرض 1 من 2 ملف'), findsOneWidget);
      await tester.enterText(search, 'الثالث');
      await tester.pumpAndSettle();
      expect(find.text('الطالب ${second.code}'), findsOneWidget);
      expect(find.text('الطالب ${first.code}'), findsNothing);
      await tester.enterText(search, 'رمز غير موجود');
      await tester.pumpAndSettle();
      expect(find.text('لم نجد ملفًا مطابقًا'), findsOneWidget);
      expect(find.text('عرض 0 من 2 ملف'), findsOneWidget);
      await tester.tap(find.byTooltip('مسح البحث'));
      await tester.pumpAndSettle();
      expect(find.text('الطالب ${first.code}'), findsOneWidget);
      expect(find.text('الطالب ${second.code}'), findsOneWidget);
      expect(state.students, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty list starts the real form and successful explicit save returns a student card',
    (tester) async {
      final state = studentState('student-create');
      await page(tester, Scaffold(body: StudentsScreen(state: state)));
      expect(find.text('ابدئي بأول ملف طالب'), findsOneWidget);
      await tester.tap(find.text('إضافة ملف طالب'));
      await tester.pumpAndSettle();
      expect(find.text('ملف طالب جديد'), findsOneWidget);
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == 'سبب الإحالة',
        ),
        'ملاحظة أداء تعليمية اصطناعية',
      );
      await reveal(
        tester,
        find.text('أؤكد الحصول على الموافقة المطلوبة وفق سياسة المؤسسة'),
      );
      await tester.tap(
        find.text('أؤكد الحصول على الموافقة المطلوبة وفق سياسة المؤسسة'),
      );
      await reveal(
        tester,
        find.text('راجعت الحقول الحرة وأؤكد خلوها من الهوية والمعلومات الصحية'),
      );
      await tester.tap(
        find.text('راجعت الحقول الحرة وأؤكد خلوها من الهوية والمعلومات الصحية'),
      );
      await reveal(tester, find.text('حفظ الملف محليًا'));
      await tester.tap(find.text('حفظ الملف محليًا'));
      await tester.pumpAndSettle();
      expect(state.students, hasLength(1));
      expect(state.students.single.consentConfirmed, isTrue);
      expect(state.pendingCount, 1);
      expect(find.text('الطالب ${state.students.single.code}'), findsOneWidget);
      expect(find.text('ابدئي بأول ملف طالب'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'student card opens its file and the free assessment is created for that student only',
    (tester) async {
      final state = studentState('student-navigation');
      final first = await student(state, age: 15),
          second = await student(state);
      await page(tester, Scaffold(body: StudentsScreen(state: state)));
      await tester.tap(find.text('الطالب ${first.code}'));
      await tester.pumpAndSettle();
      expect(find.text('ملف ${first.code}'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('بدء تقييم جديد'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      final cardButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'بدء تقييم جديد'),
      );
      expect(cardButton.onPressed, isNull);
      await tester.scrollUntilVisible(
        find.text('بدء تقييم تربوي أولي'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('بدء تقييم تربوي أولي'));
      await tester.pumpAndSettle();
      expect(state.initialAssessmentsFor(first.id), hasLength(1));
      expect(state.initialAssessmentsFor(second.id), isEmpty);
      expect(state.initialAssessmentsFor(first.id).single.approved, isFalse);
      expect(find.text('التقييم الأولي الحر'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [(320.0, 2.0), (390.0, 1.0), (768.0, 1.5)]) {
    testWidgets(
      'student list, file and full intake fit ${size.$1}px at ${size.$2} text scale',
      (tester) async {
        final state = studentState('student-layout-${size.$1}');
        final value = await student(state);
        await page(
          tester,
          Scaffold(body: StudentsScreen(state: state)),
          width: size.$1,
          scale: size.$2,
        );
        expect(
          Directionality.of(tester.element(find.text('ملفات الطلبة'))),
          TextDirection.rtl,
        );
        await reveal(tester, find.text('الطالب ${value.code}'));
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('الطالب ${value.code}'));
        await tester.pumpAndSettle();
        await reveal(tester, find.text('التقييمات المحفوظة'));
        expect(tester.takeException(), isNull);
        await page(
          tester,
          StudentFormScreen(state: state),
          width: size.$1,
          scale: size.$2,
        );
        await reveal(tester, find.text('حفظ الملف محليًا'));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await AppState.flushDraftsForOwner(state.ownerId);
      },
    );
  }
}

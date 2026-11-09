import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:khotwa/core/api_client.dart';
import 'package:khotwa/core/app_state.dart';
import 'package:khotwa/core/auth_state.dart';
import 'package:khotwa/core/form_draft.dart';

import 'app_state_test.dart' show FakeStore;
import 'encrypted_store_test.dart' show MemorySecrets;

class GateStore extends FakeStore {
  Completer<void>? gate, entered;
  void block() {
    gate = Completer<void>();
    entered = Completer<void>();
  }

  @override
  Future<void> write(String data) async {
    final waiting = gate;
    if (waiting != null) {
      gate = null;
      entered!.complete();
      await waiting.future;
    }
    await super.write(data);
  }
}

void main() {
  test(
    'record commit finishes its exact form snapshot even if draft cleanup fails',
    () async {
      final records = FakeStore(), drafts = FakeStore();
      AppState openState() => AppState(
        records,
        draftStore: drafts,
        ownerId: 'draft-completion',
        deviceId: 'synthetic',
      );
      final state = openState();
      final controller = FormDraftController(
        state: state,
        key: 'student-form:new',
      );
      controller.update({'text': 'synthetic completed input'});
      await controller.flush();
      final beforeCleanup = drafts.content;
      drafts.failWrites = true;
      await state.createStudent(
        grade: 'الثاني الأساسي',
        ageYears: 7,
        ageMonths: 0,
        consentConfirmed: true,
        draftKey: controller.key,
      );
      controller.acknowledgeSaved();
      expect(state.students, hasLength(1));
      expect(state.pendingCount, 1);
      expect(state.draftFor(controller.key), isNull);
      expect(drafts.content, beforeCleanup);
      final reopened = openState();
      await reopened.load();
      expect(reopened.students, hasLength(1));
      expect(reopened.pendingCount, 1);
      expect(reopened.draftFor(controller.key), isNull);
      drafts.failWrites = false;
      final newer = FormDraftController(state: reopened, key: controller.key);
      newer.update({'text': 'new synthetic input after the completed save'});
      await newer.flush();
      final secondReopen = openState();
      await secondReopen.load();
      expect(
        secondReopen.draftFor(controller.key)!['text'],
        'new synthetic input after the completed save',
      );
      controller.dispose();
      newer.dispose();
    },
  );
  test(
    'failed record commit leaves its draft recoverable without completing it',
    () async {
      final records = FakeStore()..failWrites = true, drafts = FakeStore();
      final state = AppState(
        records,
        draftStore: drafts,
        ownerId: 'draft-commit-failure',
        deviceId: 'synthetic',
      );
      final controller = FormDraftController(
        state: state,
        key: 'student-form:new',
      );
      controller.update({'text': 'synthetic input pending an explicit save'});
      await controller.flush();
      await expectLater(
        state.createStudent(
          grade: 'الثاني الأساسي',
          ageYears: 7,
          ageMonths: 0,
          consentConfirmed: true,
          draftKey: controller.key,
        ),
        throwsStateError,
      );
      final reopened = AppState(
        records,
        draftStore: drafts,
        ownerId: 'draft-commit-failure',
        deviceId: 'reopened',
      );
      await reopened.load();
      expect(reopened.students, isEmpty);
      expect(reopened.pendingCount, 0);
      expect(
        reopened.draftFor(controller.key)!['text'],
        'synthetic input pending an explicit save',
      );
      controller.dispose();
    },
  );
  test(
    'legacy inline drafts migrate durably and cannot return after discard',
    () async {
      final records = FakeStore(), drafts = FakeStore();
      final legacy = AppState(
        records,
        ownerId: 'draft-migration',
        deviceId: 'synthetic',
      );
      await legacy.saveDraft('form', {'text': 'synthetic legacy draft'});
      final upgraded = AppState(
        records,
        draftStore: drafts,
        ownerId: 'draft-migration',
        deviceId: 'upgraded',
      );
      await upgraded.load();
      expect(upgraded.storageError, isNull);
      expect(upgraded.draftFor('form')!['text'], 'synthetic legacy draft');
      expect((jsonDecode(records.content!) as Map)['drafts'], isEmpty);
      expect(drafts.content, contains('synthetic legacy draft'));
      await upgraded.clearDraft('form');
      final reopened = AppState(
        records,
        draftStore: drafts,
        ownerId: 'draft-migration',
        deviceId: 'reopened',
      );
      await reopened.load();
      expect(reopened.draftFor('form'), isNull);
    },
  );
  test(
    'snapshots copy on editing event and coalesce to newest while disk is busy',
    () async {
      final records = FakeStore(), drafts = GateStore();
      final state = AppState(
        records,
        draftStore: drafts,
        ownerId: 'draft-copy',
        deviceId: 'synthetic',
      );
      final controller = FormDraftController(state: state, key: 'form');
      drafts.block();
      final release = drafts.gate!;
      final first = {
        'nested': {'text': 'first'},
      };
      controller.update(first);
      await drafts.entered!.future;
      (first['nested'] as Map)['text'] = 'caller mutation';
      controller.update({
        'nested': {'text': 'second'},
      });
      controller.update({
        'nested': {'text': 'latest'},
      });
      release.complete();
      await controller.flush();
      expect(state.draftFor('form')!['nested'], {'text': 'latest'});
      expect(records.content, isNull);
      expect(state.pendingCount, 0);
      final reopened = AppState(
        records,
        draftStore: drafts,
        ownerId: 'draft-copy',
        deviceId: 'reopened',
      );
      await reopened.load();
      expect(reopened.draftFor('form')!['nested'], {'text': 'latest'});
      controller.dispose();
    },
  );
  test(
    'failed writes retain latest data for explicit retry; dispose flush is durable',
    () async {
      final records = FakeStore(), drafts = FakeStore()..failWrites = true;
      final state = AppState(
        records,
        draftStore: drafts,
        ownerId: 'draft-retry',
        deviceId: 'synthetic',
      );
      final controller = FormDraftController(state: state, key: 'form');
      controller.update({'text': 'synthetic unsaved input'});
      await expectLater(controller.flush(), throwsStateError);
      expect(controller.dirty, isTrue);
      expect(controller.error, isNotNull);
      drafts.failWrites = false;
      controller.dispose();
      await AppState.flushDraftsForOwner('draft-retry');
      final reopened = AppState(
        records,
        draftStore: drafts,
        ownerId: 'draft-retry',
        deviceId: 'reopened',
      );
      await reopened.load();
      expect(reopened.draftFor('form')!['text'], 'synthetic unsaved input');
    },
  );
  test(
    'dedicated draft file writes proceed while synchronization waits on network',
    () async {
      final network = Completer<http.Response>(), requested = Completer<void>();
      final state = AppState(
        FakeStore(),
        draftStore: FakeStore(),
        ownerId: 'draft-network',
        deviceId: 'synthetic',
      );
      final api = ApiClient(
        baseUrl: 'https://example.test',
        client: MockClient((r) {
          requested.complete();
          return network.future;
        }),
      );
      final syncing = state.sync(api, 'synthetic');
      await requested.future;
      final controller = FormDraftController(state: state, key: 'form');
      controller.update({'text': 'saved while offline'});
      await controller.flush();
      expect(state.draftFor('form')!['text'], 'saved while offline');
      expect(state.syncing, isTrue);
      network.complete(http.Response(jsonEncode({'records': []}), 200));
      await syncing;
      controller.dispose();
    },
  );
  test(
    'switching owner does not publish old input to the new account',
    () async {
      final a = AppState(
        FakeStore(),
        draftStore: FakeStore(),
        ownerId: 'draft-owner-a',
        deviceId: 'synthetic',
      );
      final b = AppState(
        FakeStore(),
        draftStore: FakeStore(),
        ownerId: 'draft-owner-b',
        deviceId: 'synthetic',
      );
      var active = 'draft-owner-a';
      final controller = FormDraftController(
        state: a,
        key: 'form',
        isCurrentOwner: () => active == a.ownerId,
      );
      controller.update({'text': 'account A input'});
      active = 'draft-owner-b';
      controller.update({'text': 'stale event'});
      await controller.flush();
      expect(a.draftFor('form')!['text'], 'account A input');
      expect(b.draftFor('form'), isNull);
      controller.dispose();
    },
  );
  test(
    'same-account reauthentication drains a disposed coalescing writer before loading',
    () async {
      final records = FakeStore(), drafts = GateStore();
      final secrets = MemorySecrets();
      final api = ApiClient(
        baseUrl: 'https://example.test',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'token': 'synthetic-token',
              'expiresAt': '2099-01-01T00:00:00Z',
              'user': {
                'id': 'draft-relogin',
                'email': 'synthetic@example.test',
                'role': 'specialist',
              },
            }),
            200,
          ),
        ),
      );
      final auth = AuthState(
        api: api,
        secrets: secrets,
        storeForOwner: (id) async =>
            id.endsWith('-form-inputs') ? drafts : records,
      );
      await auth.authenticate(
        email: 'synthetic@example.test',
        password: 'SyntheticPass123!',
        register: false,
      );
      final controller = FormDraftController(state: auth.records!, key: 'form');
      drafts.block();
      final release = drafts.gate!;
      controller.update({'text': 'first'});
      await drafts.entered!.future;
      controller.update({'text': 'last before lock'});
      await auth.lock();
      controller.dispose();
      var opened = false;
      final reopening = auth
          .authenticate(
            email: 'synthetic@example.test',
            password: 'SyntheticPass123!',
            register: false,
          )
          .then((_) => opened = true);
      await Future<void>.delayed(Duration.zero);
      expect(opened, isFalse);
      release.complete();
      await reopening;
      expect(auth.records!.draftFor('form')!['text'], 'last before lock');
    },
  );
  test(
    'deletion waits for actual local writes then blocks resurrection of either file',
    () async {
      final records = GateStore(), drafts = GateStore();
      final state = AppState(
        records,
        draftStore: drafts,
        ownerId: 'draft-delete',
        deviceId: 'synthetic',
      );
      records.block();
      final releaseRecords = records.gate!;
      final creating = state.createStudent(
        grade: 'الثاني الأساسي',
        ageYears: 7,
        ageMonths: 0,
        consentConfirmed: true,
      );
      final expected = expectLater(creating, throwsStateError);
      await records.entered!.future;
      drafts.block();
      final releaseDrafts = drafts.gate!;
      final controller = FormDraftController(state: state, key: 'form');
      controller.update({'text': 'pending draft'});
      await drafts.entered!.future;
      final deleting = state.deleteLocalAfterAccountDeletion();
      releaseRecords.complete();
      releaseDrafts.complete();
      await deleting;
      await expected;
      await expectLater(
        state.saveDraft('form', {'text': 'late write'}),
        throwsStateError,
      );
      expect(records.content, isNull);
      expect(drafts.content, isNull);
      expect(state.students, isEmpty);
      controller.dispose();
    },
  );
  test(
    'account ownership is verified when opening the separate form file',
    () async {
      final drafts = FakeStore();
      final a = AppState(
        FakeStore(),
        draftStore: drafts,
        ownerId: 'draft-isolation-a',
        deviceId: 'synthetic',
      );
      await a.saveDraft('form', {'text': 'account A'});
      final b = AppState(
        FakeStore(),
        draftStore: drafts,
        ownerId: 'draft-isolation-b',
        deviceId: 'synthetic',
      );
      await b.load();
      expect(b.storageError, isNotNull);
      expect(b.draftFor('form'), isNull);
      await expectLater(
        b.saveDraft('form', {'text': 'account B'}),
        throwsStateError,
      );
    },
  );
}

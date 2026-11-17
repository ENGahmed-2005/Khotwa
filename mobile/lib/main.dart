import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/api_client.dart';
import 'core/auth_state.dart';
import 'core/export_cache.dart';
import 'core/khotwa_theme.dart';
import 'core/secure_local_store.dart';
import 'features/home_screen.dart';
import 'features/auth_screen.dart';
import 'features/activities_screen.dart';
import 'features/reports_screen.dart';
import 'widgets/khotwa_backdrop.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) WidgetsBinding.instance.ensureSemantics();
  final SecretStore secrets = kIsWeb
      ? PreviewSecretStore()
      : const DeviceSecretStore();
  final auth = AuthState(
    api: ApiClient(
      baseUrl: const String.fromEnvironment(
        'API_BASE_URL',
        defaultValue: 'https://localhost:3000',
      ),
      allowDebugHttp:
          kDebugMode ||
          (kIsWeb && const bool.fromEnvironment('ALLOW_SYNTHETIC_WEB_PREVIEW')),
    ),
    secrets: secrets,
    storeForOwner: (owner) => EncryptedFileStore.forOwner(owner, secrets),
    clearExportsForOwner: (owner) => clearExportFiles(ownerId: owner),
    clearStaleExports: () => clearExportFiles(),
  );
  await auth.restore();
  runApp(KhotwaApp(auth: auth));
}

class KhotwaApp extends StatelessWidget {
  const KhotwaApp({super.key, required this.auth});

  final AuthState auth;

  @override
  Widget build(BuildContext context) =>
      AnimatedBuilder(animation: auth, builder: (context, _) => _application());

  Widget _application() {
    return MaterialApp(
      key: ValueKey('session:${auth.ownerId ?? 'locked'}'),
      title: 'خطوة',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: KhotwaTheme.light,
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: KhotwaBackdrop(
          welcome: !auth.signedIn,
          child: Column(
            children: [
              if (auth.cleanupWarning != null)
                Material(
                  color: const Color(0xFFFFF6E5),
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(auth.cleanupWarning!),
                    ),
                  ),
                ),
              Expanded(child: child ?? const SizedBox.shrink()),
            ],
          ),
        ),
      ),
      home: AnimatedBuilder(
        animation: auth,
        builder: (context, _) => !auth.signedIn
            ? AuthScreen(auth: auth)
            : auth.records!.storageError == null
            ? HomeScreen(
                key: ValueKey(auth.ownerId),
                state: auth.records!,
                auth: auth,
                activitiesBuilder: (_) => ActivitiesScreen(auth: auth),
                reportsBuilder: (_) => ReportsScreen(auth: auth),
              )
            : StorageFailureScreen(message: auth.records!.storageError!),
      ),
    );
  }
}

class StorageFailureScreen extends StatelessWidget {
  const StorageFailureScreen({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 58),
            const SizedBox(height: 16),
            Text(
              'تعذّر فتح التخزين الآمن',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            const Text('لحماية بيانات الطلبة، لن يعمل التطبيق دون تخزين آمن.'),
            const SizedBox(height: 8),
            SelectableText(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    ),
  );
}

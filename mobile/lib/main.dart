import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/api_client.dart';
import 'core/auth_state.dart';
import 'core/secure_local_store.dart';
import 'features/home_screen.dart';
import 'features/auth_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) WidgetsBinding.instance.ensureSemantics();
  final SecretStore secrets = kIsWeb ? PreviewSecretStore() : const DeviceSecretStore();
  final auth = AuthState(api: ApiClient(baseUrl: const String.fromEnvironment('API_BASE_URL', defaultValue: 'https://localhost:3000'), allowDebugHttp: kDebugMode || (kIsWeb && const bool.fromEnvironment('ALLOW_SYNTHETIC_WEB_PREVIEW'))), secrets: secrets, storeForOwner: (owner) => EncryptedFileStore.forOwner(owner, secrets));
  await auth.restore();
  runApp(KhotwaApp(auth: auth));
}

class KhotwaApp extends StatelessWidget {
  const KhotwaApp({super.key, required this.auth});

  final AuthState auth;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'خطوة',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF6FAFB),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0A6B78),
          primary: const Color(0xFF0A6B78),
          secondary: const Color(0xFF267E5E),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF6FAFB),
          centerTitle: true,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          margin: const EdgeInsets.symmetric(vertical: 5),
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Color(0xFFE2ECEF)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        ),
      ),
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child ?? const SizedBox.shrink(),
      ),
      home: AnimatedBuilder(animation: auth, builder: (context, _) => !auth.signedIn ? AuthScreen(auth: auth) : auth.records!.storageError == null
          ? HomeScreen(key: ValueKey(auth.ownerId), state: auth.records!, auth: auth)
          : StorageFailureScreen(message: auth.records!.storageError!)),
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
                Text('تعذّر فتح التخزين الآمن',
                    style: Theme.of(context).textTheme.headlineSmall),
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

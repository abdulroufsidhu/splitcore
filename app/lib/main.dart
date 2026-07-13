import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import 'screens/home.dart';
import 'screens/login.dart';
import 'theme.dart';

/// Default PocketBase URL: 10.0.2.2 is the Android emulator's alias for the
/// host machine's localhost, where `cd server && go run .` serves :8090.
const _defaultPocketbaseUrl = String.fromEnvironment(
  'POCKETBASE_URL',
  defaultValue: 'http://10.0.2.2:8090',
);

/// Bare soname on Android/iOS (resolved from the app's bundled native libs
/// via the OS loader — see splitcore_sdk's bindings.dart), an absolute path
/// on desktop for local dev against splitcore/build/out/linux.
String _libraryPath() {
  if (Platform.isAndroid || Platform.isIOS) return 'libsplitcore.so';
  return const String.fromEnvironment('SPLITCORE_LIB_PATH', defaultValue: 'libsplitcore.so');
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SlicePayApp());
}

class SlicePayApp extends StatefulWidget {
  const SlicePayApp({super.key});

  @override
  State<SlicePayApp> createState() => _SlicePayAppState();
}

class _SlicePayAppState extends State<SlicePayApp> {
  late final Future<SplitcoreSdk> _sdkFuture = _initSdk();
  final ValueNotifier<AppUser?> currentUser = ValueNotifier(null);

  Future<SplitcoreSdk> _initSdk() async {
    final prefs = await SharedPreferences.getInstance();
    final authStore = AsyncAuthStore(
      save: (data) async => prefs.setString('pb_auth', data),
      initial: prefs.getString('pb_auth'),
    );
    final sdk = SplitcoreSdk.initialize(
      pocketbaseUrl: _defaultPocketbaseUrl,
      libraryPath: _libraryPath(),
      authStore: authStore,
    );
    currentUser.value = sdk.auth.currentUser;
    return sdk;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SlicePay',
      debugShowCheckedModeBanner: false,
      theme: sliceTheme(),
      home: FutureBuilder<SplitcoreSdk>(
        future: _sdkFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Scaffold(
              body: Center(child: Text('Failed to start: ${snapshot.error}')),
            );
          }
          final sdk = snapshot.data;
          if (sdk == null) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          return ValueListenableBuilder<AppUser?>(
            valueListenable: currentUser,
            builder: (context, user, _) {
              if (user == null) {
                return LoginScreen(sdk: sdk, onSignedIn: (u) => currentUser.value = u);
              }
              return HomeScreen(
                sdk: sdk,
                me: user,
                onSignedOut: () {
                  sdk.auth.signOut();
                  currentUser.value = null;
                },
              );
            },
          );
        },
      ),
    );
  }
}

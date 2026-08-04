import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import 'config.dart';
import 'screens/home.dart';
import 'screens/login.dart';
import 'theme.dart';

/// Bare soname on Android/iOS (resolved from the app's bundled native libs
/// via the OS loader — see splitcore_sdk's bindings.dart), an absolute path
/// on desktop for local dev against splitcore/build/out/linux.
String _libraryPath() {
  if (Platform.isAndroid || Platform.isIOS) return 'libsplitcore.so';
  return const String.fromEnvironment('SPLITCORE_LIB_PATH', defaultValue: 'libsplitcore.so');
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Both font families are bundled (see pubspec.yaml assets/fonts) —
  // never hit the network for them, so there's no fallback-font flash and
  // no first-launch failure when offline.
  GoogleFonts.config.allowRuntimeFetching = false;
  runApp(const SlicePayApp());
}

/// Session persistence for the SDK, backed by shared_preferences. Keeping
/// this here rather than taking a PocketBase AuthStore is what lets the app
/// drop `package:pocketbase` entirely.
class _PrefsTokenStore implements TokenStore {
  _PrefsTokenStore(this._prefs);

  final SharedPreferences _prefs;
  static const _key = 'pb_auth';

  @override
  String? read() => _prefs.getString(_key);

  @override
  Future<void> write(String data) => _prefs.setString(_key, data);
}

class SlicePayApp extends StatefulWidget {
  const SlicePayApp({super.key});

  @override
  State<SlicePayApp> createState() => _SlicePayAppState();
}

class _SlicePayAppState extends State<SlicePayApp> with WidgetsBindingObserver {
  late final Future<SplitcoreSdk> _sdkFuture = _initSdk();
  final ValueNotifier<AppUser?> currentUser = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // A token can expire while the app sits backgrounded; without this the
  // first request after resuming just 401s with no recovery path. Refresh
  // eagerly on resume (and once at startup, right after loading it below)
  // instead of waiting for a call to fail.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshSession();
  }

  Future<void> _refreshSession() async {
    if (currentUser.value == null) return;
    final sdk = await _sdkFuture;
    final refreshed = await sdk.auth.tryRefresh();
    currentUser.value = refreshed;
  }

  Future<SplitcoreSdk> _initSdk() async {
    // Resolve prefs first: TokenStore.read is synchronous because the SDK
    // needs the stored session while constructing its client.
    final prefs = await SharedPreferences.getInstance();
    final sdk = SplitcoreSdk.initialize(
      pocketbaseUrl: defaultBackendUrl(),
      libraryPath: _libraryPath(),
      tokenStore: _PrefsTokenStore(prefs),
    );
    currentUser.value = sdk.auth.currentUser;
    unawaited(_refreshSession());
    return sdk;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SlicePay',
      debugShowCheckedModeBanner: false,
      theme: sliceLightTheme(),
      darkTheme: sliceDarkTheme(),
      themeMode: ThemeMode.system,
      home: FutureBuilder<SplitcoreSdk>(
        future: _sdkFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Scaffold(body: Center(child: Text('Failed to start: ${snapshot.error}')));
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
                onProfileUpdated: (u) => currentUser.value = u,
              );
            },
          );
        },
      ),
    );
  }
}

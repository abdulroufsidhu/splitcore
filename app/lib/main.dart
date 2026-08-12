import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import 'config.dart';
import 'connectivity.dart';
import 'screens/login.dart';
import 'screens/shell.dart';
import 'theme.dart';

/// Bare soname on Android/iOS (resolved from the app's bundled native libs
/// via the OS loader — see splitcore_sdk's bindings.dart), an absolute path
/// on desktop for local dev against splitcore/build/out/linux. On Windows the
/// bare name resolves against the .exe's own directory, where the release
/// workflow drops splitcore.dll.
String _libraryPath() {
  if (Platform.isAndroid || Platform.isIOS) return 'libsplitcore.so';
  const fallback = String.fromEnvironment('SPLITCORE_LIB_PATH');
  if (fallback.isNotEmpty) return fallback;
  if (Platform.isWindows) return 'splitcore.dll';
  if (Platform.isMacOS) return 'libsplitcore.dylib';
  return 'libsplitcore.so';
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

  /// Reaches the root navigator from the sign-out callback, which has no
  /// BuildContext of its own — see [_signOut].
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

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

  /// Ends the session and returns the user to the login screen.
  ///
  /// Clearing [currentUser] swaps what [MaterialApp.home] builds, but
  /// anything pushed on top of it — the account screen, a modal sheet — is
  /// a route in the navigator stack, and a root swap does not touch the
  /// stack. Without the pop, signing out from account settings left the
  /// user sitting on account settings until they thought to press back.
  void _signOut(SplitcoreSdk sdk) {
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);
    sdk.auth.signOut();
    currentUser.value = null;
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
    final dir = await getApplicationSupportDirectory();
    final sdk = SplitcoreSdk.initialize(
      pocketbaseUrl: defaultBackendUrl(),
      libraryPath: _libraryPath(),
      // The local mirror every screen reads from. Persisted, so relaunching
      // without a connection still shows the user their groups.
      databasePath: '${dir.path}/splitcore.db',
      tokenStore: _PrefsTokenStore(prefs),
      connectivity: ConnectivityPlusMonitor(),
    );
    currentUser.value = sdk.auth.currentUser;
    unawaited(_refreshSession());
    // Nothing is on screen until the first pull, so kick one off rather than
    // waiting for a connectivity transition that may never come — the app is
    // usually launched with the network already up.
    unawaited(sdk.sync.now());
    return sdk;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SlicePay',
      navigatorKey: _navigatorKey,
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
                return LoginScreen(
                  sdk: sdk,
                  onSignedIn: (u) {
                    currentUser.value = u;
                    // The pull kicked off in _initSdk ran before anyone was
                    // signed in, so it fetched nothing. Without this the
                    // first thing a user sees after signing in is "no
                    // groups yet", and their data only appears once they
                    // think to pull to refresh.
                    unawaited(sdk.sync.now().catchError((_) {}));
                  },
                );
              }
              return AppShell(
                sdk: sdk,
                me: user,
                onSignedOut: () => _signOut(sdk),
                onProfileUpdated: (u) => currentUser.value = u,
              );
            },
          );
        },
      ),
    );
  }
}

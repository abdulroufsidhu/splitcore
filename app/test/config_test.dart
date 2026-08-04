import 'package:flutter_test/flutter_test.dart';

import 'package:splitcore_app/config.dart';

void main() {
  test('an explicit --dart-define wins on every platform', () {
    expect(
      resolveBackendUrl(override: 'https://api.example.com', isAndroid: true, isIos: false),
      'https://api.example.com',
    );
    expect(
      resolveBackendUrl(override: 'https://api.example.com', isAndroid: false, isIos: false),
      'https://api.example.com',
    );
  });

  test('Android falls back to the emulator host alias, not a LAN address', () {
    final url = resolveBackendUrl(override: '', isAndroid: true, isIos: false);
    expect(url, 'http://10.0.2.2:8090');
  });

  test('iOS simulator and desktop fall back to localhost', () {
    expect(resolveBackendUrl(override: '', isAndroid: false, isIos: true), 'http://127.0.0.1:8090');
    expect(resolveBackendUrl(override: '', isAndroid: false, isIos: false), 'http://127.0.0.1:8090');
  });

  test('no fallback is a machine-specific address', () {
    for (final url in [
      resolveBackendUrl(override: '', isAndroid: true, isIos: false),
      resolveBackendUrl(override: '', isAndroid: false, isIos: false),
    ]) {
      expect(url.contains('192.168.'), isFalse, reason: 'LAN address baked into a default: $url');
    }
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:splitcore_app/config.dart';

void main() {
  test('an explicit --dart-define wins', () {
    expect(resolveBackendUrl(override: 'http://127.0.0.1:8090'), 'http://127.0.0.1:8090');
  });

  test('no override means the deployed server over https', () {
    expect(resolveBackendUrl(override: ''), 'https://splitcore.orgolink.ch');
  });

  test('the default is neither a machine-specific address nor cleartext', () {
    final url = resolveBackendUrl(override: '');
    expect(url.startsWith('https://'), isTrue, reason: 'cleartext default: $url');
    expect(url.contains('192.168.'), isFalse, reason: 'LAN address baked into a default: $url');
    expect(url.contains('127.0.0.1'), isFalse, reason: 'loopback baked into a default: $url');
  });
}

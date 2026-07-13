import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Spawns the real PocketBase server (../server) as a subprocess on an
/// ephemeral port with an isolated temp data dir, for integration tests
/// that exercise the actual wire contract rather than a mock.
class PbTestServer {
  PbTestServer._(this.baseUrl, this._process, this._dataDir);

  final String baseUrl;
  final Process _process;
  final Directory _dataDir;

  static Future<PbTestServer> start() async {
    final port = await _findFreePort();
    final dataDir = await Directory.systemTemp.createTemp('splitcore_pb_test_');
    final serverDir = p.normalize(p.join(Directory.current.path, '..', 'server'));

    final process = await Process.start(
      'go',
      ['run', '.', 'serve', '--http=127.0.0.1:$port', '--dir=${dataDir.path}'],
      workingDirectory: serverDir,
    );
    // PocketBase logs heavily on startup (SQL + request logs). If nobody
    // drains these streams, the OS pipe buffer fills and the child blocks
    // on write before it ever finishes starting — must drain unconditionally.
    process.stdout.drain<void>();
    process.stderr.drain<void>();

    final baseUrl = 'http://127.0.0.1:$port';
    await _waitUntilHealthy(baseUrl, process);

    return PbTestServer._(baseUrl, process, dataDir);
  }

  Future<void> stop() async {
    _process.kill(ProcessSignal.sigterm);
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return _process.exitCode;
      },
    );
    await _dataDir.delete(recursive: true);
  }

  static Future<int> _findFreePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  static Future<void> _waitUntilHealthy(String baseUrl, Process process) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final response = await http
            .get(Uri.parse('$baseUrl/api/health'))
            .timeout(const Duration(seconds: 2));
        if (response.statusCode == 200) return;
      } catch (e) {
        lastError = e;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    process.kill();
    throw StateError('PocketBase test server did not become healthy: $lastError');
  }
}

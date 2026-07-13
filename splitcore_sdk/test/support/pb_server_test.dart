import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'pb_server.dart';

void main() {
  test('starts a real PocketBase server and responds on /api/health', () async {
    final server = await PbTestServer.start();
    addTearDown(server.stop);

    final response = await http.get(Uri.parse('${server.baseUrl}/api/health'));

    expect(response.statusCode, 200);
  });

  test('each started server gets its own isolated data dir and port', () async {
    final a = await PbTestServer.start();
    addTearDown(a.stop);
    final b = await PbTestServer.start();
    addTearDown(b.stop);

    expect(a.baseUrl, isNot(equals(b.baseUrl)));
  });
}

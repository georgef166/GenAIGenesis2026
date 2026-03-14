import 'dart:io';

import 'package:genai_server/src/meshy_proxy_app.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> main() async {
  final apiKey = Platform.environment['MESHY_API_KEY']?.trim();
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln(
      'MESHY_API_KEY must be set before starting the Meshy proxy.',
    );
    exitCode = 64;
    return;
  }

  final port = int.tryParse(Platform.environment['PORT'] ?? '8080') ?? 8080;
  final app = MeshyProxyApp(meshyApi: MeshyHttpApi(apiKey: apiKey));

  final server = await shelf_io.serve(
    const Pipeline().addMiddleware(logRequests()).addHandler(app.handler),
    InternetAddress.anyIPv4,
    port,
  );

  stdout.writeln(
    'Meshy proxy listening on http://${server.address.address}:${server.port}',
  );
}

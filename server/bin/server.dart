import 'dart:io';

import 'package:genai_server/src/meshy_proxy_app.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> main() async {
  final backendUrl = Platform.environment['GENAI_BACKEND_URL']?.trim();
  final backendUri = backendUrl == null || backendUrl.isEmpty
      ? null
      : Uri.tryParse(backendUrl);
  if (backendUri == null || !backendUri.hasScheme || backendUri.host.isEmpty) {
    stderr.writeln(
      'GENAI_BACKEND_URL must be set to the generation service URL '
      '(for example http://127.0.0.1:8770) before starting the proxy.',
    );
    exitCode = 64;
    return;
  }

  final objectBackendUrl = Platform.environment['GENAI_OBJECT_BACKEND_URL']
      ?.trim();
  final objectBackendUri = objectBackendUrl == null || objectBackendUrl.isEmpty
      ? null
      : Uri.tryParse(objectBackendUrl);
  if (objectBackendUrl != null &&
      objectBackendUrl.isNotEmpty &&
      (objectBackendUri == null ||
          !objectBackendUri.hasScheme ||
          objectBackendUri.host.isEmpty)) {
    stderr.writeln(
      'GENAI_OBJECT_BACKEND_URL must be an absolute URL '
      '(for example http://127.0.0.1:8771).',
    );
    exitCode = 64;
    return;
  }

  final port = int.tryParse(Platform.environment['PORT'] ?? '8080') ?? 8080;
  final app = MeshyProxyApp(
    meshyApi: TencentHttpApi(baseUri: backendUri),
    objectApi: objectBackendUri == null
        ? null
        : Hunyuan3dHttpApi(baseUri: objectBackendUri),
  );

  final server = await shelf_io.serve(
    const Pipeline().addMiddleware(logRequests()).addHandler(app.handler),
    InternetAddress.anyIPv4,
    port,
  );

  stdout.writeln(
    'Generation proxy listening on '
    'http://${server.address.address}:${server.port} '
    '(world: $backendUri, object: ${objectBackendUri ?? 'not configured'})',
  );
}

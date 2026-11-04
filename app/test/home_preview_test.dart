import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:neruds_control_center/app_config.dart';
import 'package:neruds_control_center/app_session.dart';
import 'package:neruds_control_center/bridge_http.dart' as bridge;
import 'package:neruds_control_center/home_preview_page.dart';
import 'package:neruds_control_center/manage_service.dart';

http.Response _json(Object v) =>
    http.Response.bytes(utf8.encode(jsonEncode(v)), 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    AppConfig.configureForTesting(bridgeUrl: 'https://bridge.example.test');
    AppSession.instance.setSession(
      tokenValue: 'test-token',
      usernameValue: 'ext',
    );
  });

  tearDown(() async {
    bridge.resetClientForTesting();
    AppSession.instance.clear();
    AppConfig.configureForTesting();
  });

  testWidgets('prévia compõe seções com itens publicados do /manage',
      (tester) async {
    ManageService.resetSchemasCache();
    bridge.setClientForTesting(MockClient((request) async {
      final path = request.url.path;
      debugPrint('REQ $path');
      if (path == '/manage/noticia') {
        return _json({
          'items': [
            {'nid': 1, 'uuid': 'u1', 'title': 'Notícia fresca', 'status': true},
          ],
        });
      }
      return _json({'items': []});
    }));
    await tester.pumpWidget(
      const MaterialApp(home: HomePreviewPage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Últimas Notícias'), findsOneWidget);
    expect(find.text('Publicações Científicas'), findsOneWidget);
    expect(find.textContaining('Notícia fresca'), findsOneWidget);
    expect(find.text('Abrir site'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

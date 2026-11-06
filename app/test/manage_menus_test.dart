import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:neruds_control_center/app_config.dart';
import 'package:neruds_control_center/app_session.dart';
import 'package:neruds_control_center/bridge_http.dart' as bridge;
import 'package:neruds_control_center/manage_menus_page.dart';

http.Response _json(Object v) =>
    http.Response.bytes(utf8.encode(jsonEncode(v)), 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppConfig.configureForTesting(bridgeUrl: 'https://bridge.example.test');
    AppSession.instance.setSession(
      tokenValue: 'test-token',
      usernameValue: 'ext',
    );
  });

  tearDown(() {
    bridge.resetClientForTesting();
    AppSession.instance.clear();
    AppConfig.configureForTesting();
  });

  testWidgets('menus listam itens e toggle chama PATCH', (tester) async {
    var patched = false;
    bridge.setClientForTesting(MockClient((request) async {
      if (request.url.path == '/menus' && request.method == 'GET') {
        return _json({
          'menus': [
            {'id': 'main', 'label': 'Navegação principal'},
          ],
        });
      }
      if (request.url.path == '/menus/main') {
        return _json({
          'items': [
            {
              'uuid': 'u1',
              'menu': 'main',
              'title': 'Início',
              'uri': 'internal:/',
              'enabled': true,
              'weight': 0,
            },
          ],
        });
      }
      if (request.url.path == '/menus/items/u1' &&
          request.method == 'PATCH') {
        patched = true;
        return _json({'ok': true});
      }
      return _json({});
    }));
    await tester.pumpWidget(
      const MaterialApp(home: ManageMenusPage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Início'), findsOneWidget);
    expect(find.text('Novo item'), findsOneWidget);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(patched, isTrue);
    expect(tester.takeException(), isNull);
  });
}

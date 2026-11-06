import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:neruds_control_center/app_config.dart';
import 'package:neruds_control_center/app_session.dart';
import 'package:neruds_control_center/bridge_http.dart' as bridge;
import 'package:neruds_control_center/manage_list_page.dart';
import 'package:neruds_control_center/manage_models.dart';

http.Response json_(Map<String, dynamic> body, [int code = 200]) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      code,
      headers: {'content-type': 'application/json'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    AppConfig.configureForTesting(bridgeUrl: 'https://bridge.example.test');
    AppSession.instance.setSession(tokenValue: 't', usernameValue: 'u');
  });
  tearDown(() async {
    bridge.resetClientForTesting();
    AppSession.instance.clear();
    AppConfig.configureForTesting();
  });

  testWidgets('listagem mobile 390px renderiza rich cards', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    bridge.setClientForTesting(MockClient((request) async {
      if (request.url.path == '/manage/noticia') {
        return json_({
          'items': [
            {'nid': 1, 'uuid': 'u1', 'title': 'Notícia um', 'status': true},
            {'nid': 2, 'uuid': 'u2', 'title': 'Notícia dois', 'status': false},
          ],
          'has_next': false,
        });
      }
      return http.Response('nf', 404);
    }));
    final bundle = ManageBundle.fromJson('noticia', {
      'label': 'Notícias', 'label_singular': 'Notícia', 'fields': [],
    }, canCreate: true);
    await tester.pumpWidget(MaterialApp(home: ManageListPage(bundle: bundle)));
    await tester.pumpAndSettle();
    expect(find.text('Notícia um'), findsOneWidget);
    expect(find.text('Notícia dois'), findsOneWidget);
    // confirma que o cartão aparece (não um bloco cinza)
    expect(tester.takeException(), isNull);
  });
}

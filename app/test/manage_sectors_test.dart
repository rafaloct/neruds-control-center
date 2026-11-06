import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:neruds_control_center/app_config.dart';
import 'package:neruds_control_center/app_session.dart';
import 'package:neruds_control_center/bridge_http.dart' as bridge;
import 'package:neruds_control_center/manage_sectors_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    AppConfig.configureForTesting(bridgeUrl: 'https://bridge.example.test');
    bridge.setClientForTesting(MockClient((request) async {
      if (request.url.path == '/manage/schemas') {
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'schemas': {
              'grupo_estudos': {
                'label': 'Grupos de estudos',
                'label_singular': 'Grupo',
                'icon': 'groups',
                'fields': [],
              },
              'projeto_pesquisa_extensao': {
                'label': 'Projetos',
                'label_singular': 'Projeto',
                'icon': 'folder',
                'fields': [],
              },
            },
            'can_create': {
              'grupo_estudos': true,
              'projeto_pesquisa_extensao': false,
            },
          })),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('not found', 404);
    }));
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

  testWidgets('grid lista setores com permissão de criação',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ManageSectorsPage())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Grupos de estudos'), findsOneWidget);
    expect(find.text('Projetos'), findsOneWidget);
    expect(find.text('Criar e gerenciar'), findsOneWidget);
    expect(find.text('Somente gerenciar'), findsOneWidget);
  });
}

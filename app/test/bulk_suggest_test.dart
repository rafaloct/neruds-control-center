import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:neruds_control_center/app_config.dart';
import 'package:neruds_control_center/app_session.dart';
import 'package:neruds_control_center/bridge_http.dart' as bridge;
import 'package:neruds_control_center/bulk_suggest_sheet.dart';
import 'package:neruds_control_center/manage_service.dart';
import 'package:neruds_control_center/portal_read.dart';

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
    ManageService.resetSchemasCache();
  });

  tearDown(() {
    bridge.resetClientForTesting();
    AppSession.instance.clear();
    AppConfig.configureForTesting();
  });

  testWidgets('sugestão em massa gera rascunhos e aplica parcial',
      (tester) async {
    var assists = 0;
    var savedFields = <dynamic>[];
    bridge.setClientForTesting(MockClient((request) async {
      switch (request.url.path) {
        case '/manage/schemas':
          return _json({
            'can_create': {},
            'schemas': {
              'projeto_pesquisa_extensao': {
                'label': 'Projetos',
                'label_singular': 'Projeto',
                'fields': [
                  {'name': 'title', 'label': 'Título', 'kind': 'text'},
                  {
                    'name': 'field_resumo',
                    'label': 'Resumo',
                    'kind': 'longtext',
                  },
                  {
                    'name': 'field_coordenador',
                    'label': 'Coordenador',
                    'kind': 'text',
                  },
                ],
              },
            },
          });
        case '/manage/projeto_pesquisa_extensao/22':
          if (request.method == 'PATCH') {
            final body = jsonDecode(request.body) as Map;
            savedFields =
                ((body['values'] as Map).keys).toList();
            return _json({'ok': true});
          }
          return _json({'status': true});
        case '/ai/assist':
          assists++;
          return _json({'ok': true, 'result': 'Rascunho $assists.'});
        default:
          return _json({});
      }
    }));
    final node = GapNode(
      nid: 22,
      type: 'projeto_pesquisa_extensao',
      title: 'Projeto Teste',
      missing: ['Resumo', 'Coordenador'],
      missingFields: ['field_resumo', 'field_coordenador'],
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BulkSuggestSheet(node: node, fieldWeight: (_) => 3),
      ),
    ));
    await tester.pumpAndSettle();
    // Só longtext é elegível: 'field_coordenador' (text/string curta)
    // não recebe sugestão — o save inteiro era recusado com um
    // parágrafo que excede o máximo de 255 do campo.
    expect(assists, 1);
    expect(find.textContaining('Rascunho'), findsWidgets);
    expect(find.text('Coordenador'), findsNothing);
    await tester.tap(find.textContaining('Aplicar'));
    await tester.pumpAndSettle();
    expect(savedFields.toSet(), {'field_resumo'});
    expect(tester.takeException(), isNull);
  });
}

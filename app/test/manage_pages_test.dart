import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:neruds_control_center/app_config.dart';
import 'package:neruds_control_center/app_session.dart';
import 'package:neruds_control_center/bridge_http.dart' as bridge;
import 'package:neruds_control_center/manage_form_page.dart';
import 'package:neruds_control_center/manage_list_page.dart';
import 'package:neruds_control_center/manage_models.dart';
import 'package:neruds_control_center/manage_taxonomy_page.dart';

http.Response json_(Map<String, dynamic> body, [int code = 200]) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      code,
      headers: {'content-type': 'application/json'},
    );

Map<String, dynamic> bundleSchema() => {
      'label': 'Notícias',
      'label_singular': 'Notícia',
      'icon': 'newspaper',
      'fields': [
        {'name': 'title', 'label': 'Título', 'kind': 'text', 'required': true},
        {
          'name': 'field_data_noticia',
          'label': 'Data',
          'kind': 'date',
          'required': true
        },
      ],
      'steps': [
        {'id': 'basics', 'label': 'Informações básicas'},
        {'id': 'review', 'label': 'Revisão e salvar'},
      ],
    };

/// Schema real de notícia (produção) — cobre reference/image/file/longtext.
Map<String, dynamic> noticiaSchema() => {
      'label': 'Notícias',
      'label_singular': 'Notícia',
      'icon': 'newspaper',
      'fields': [
        {'name': 'title', 'label': 'Título', 'kind': 'text', 'required': true, 'group': 'basics'},
        {'name': 'field_resumo_noticia', 'label': 'Resumo', 'kind': 'longtext', 'group': 'content'},
        {'name': 'body', 'label': 'Texto', 'kind': 'longtext', 'group': 'content'},
        {'name': 'field_data_noticia', 'label': 'Data da notícia', 'kind': 'date', 'required': true, 'group': 'basics'},
        {'name': 'field_autor_noticia', 'label': 'Autor', 'kind': 'text', 'group': 'basics'},
        {'name': 'field_imagem_destaque', 'label': 'Imagem', 'kind': 'image', 'group': 'media'},
        {'name': 'field_pdf', 'label': 'PDFs', 'kind': 'file', 'multiple': true, 'group': 'media'},
        {'name': 'field_tags', 'label': 'Tags', 'kind': 'reference', 'multiple': true, 'target': 'taxonomy_term:tags', 'group': 'refs'},
      ],
      'steps': [
        {'id': 'basics', 'label': 'Informações básicas'},
        {'id': 'content', 'label': 'Conteúdo'},
        {'id': 'refs', 'label': 'Vínculos'},
        {'id': 'media', 'label': 'Mídia'},
        {'id': 'review', 'label': 'Revisão e salvar'},
      ],
    };

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

  testWidgets('listagem renderiza itens reais do bridge', (tester) async {
    bridge.setClientForTesting(MockClient((request) async {
      if (request.url.path == '/manage/noticia') {
        return json_({
          'items': [
            {
              'nid': 42,
              'uuid': 'u-42',
              'title': 'Oficina de agroecologia',
              'status': true,
              'changed': '2026-11-03T10:00:00+00:00',
            },
            {
              'nid': 43,
              'uuid': 'u-43',
              'title': 'Rascunho interno',
              'status': false,
            },
          ],
          'has_next': false,
        });
      }
      return http.Response('not found', 404);
    }));
    final bundle = ManageBundle.fromJson(
      'noticia',
      bundleSchema(),
      canCreate: true,
    );
    await tester.pumpWidget(MaterialApp(home: ManageListPage(bundle: bundle)));
    await tester.pumpAndSettle();
    expect(find.text('Oficina de agroecologia'), findsOneWidget);
    expect(find.text('Rascunho interno'), findsOneWidget);
    expect(find.text('Publicado'), findsOneWidget);
    expect(find.text('Rascunho'), findsOneWidget);
  });

  testWidgets('edição injeta valores do detail no wizard', (tester) async {
    bridge.setClientForTesting(MockClient((request) async {
      if (request.url.path == '/manage/noticia/42') {
        return json_({
          'nid': 42,
          'uuid': 'u-42',
          'title': 'Oficina de agroecologia',
          'status': false,
          'values': {
            'title': 'Oficina de agroecologia',
            'field_data_noticia': {'value': '2026-10-15'},
          },
          'relationships': {},
        });
      }
      return http.Response('not found', 404);
    }));
    final bundle = ManageBundle.fromJson(
      'noticia',
      bundleSchema(),
      canCreate: true,
    );
    await tester.pumpWidget(
      MaterialApp(home: ManageFormPage(bundle: bundle, nid: 42)),
    );
    await tester.pumpAndSettle();
    // O wizard deve mostrar o passo inicial com o título preenchido.
    expect(
      find.widgetWithText(TextFormField, 'Oficina de agroecologia'),
      findsOneWidget,
    );
  });

  testWidgets('wizard com schema completo renderiza todos os passos',
      (tester) async {
    bridge.setClientForTesting(MockClient((request) async {
      if (request.url.path.contains('/manage/options')) {
        return json_({'options': []});
      }
      if (request.url.path == '/manage/noticia/42') {
        return json_({
          'nid': 42,
          'uuid': 'u-42',
          'title': 'Notícia real',
          'status': true,
          'values': {
            'title': 'Notícia real',
            'body': {'value': '<p>Texto</p>', 'format': 'plain_text'},
            'field_data_noticia': {'value': '2026-10-15'},
            'field_resumo_noticia': {'value': 'resumo'},
            'field_autor_noticia': 'Maria',
          },
          'relationships': {
            'field_tags': {
              'data': [
                {'type': 'taxonomy_term--tags', 'id': 't-1'},
              ]
            },
          },
        });
      }
      return http.Response('not found', 404);
    }));
    final bundle = ManageBundle.fromJson(
      'noticia',
      noticiaSchema(),
      canCreate: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          FlutterQuillLocalizations.delegate,
        ],
        home: ManageFormPage(bundle: bundle, nid: 42),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Informações básicas'), findsWidgets);
    await tester.tap(find.text('Avançar').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Avançar').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Avançar').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Avançar').first);
    await tester.pumpAndSettle();
    expect(find.text('Salvar'), findsOneWidget);
  });

  testWidgets('taxonomia lista termos e usa tid para ações',
      (tester) async {
    final calls = <String>[];
    bridge.setClientForTesting(MockClient((request) async {
      calls.add('${request.method} ${request.url.path}');
      if (request.url.path == '/manage/taxonomy') {
        return json_({
          'vocabularies': [
            {'vid': 'tags', 'label': 'Tags'},
          ]
        });
      }
      if (request.url.path == '/manage/taxonomy/tags') {
        return json_({
          'items': [
            {'tid': 7, 'uuid': 't-7', 'title': 'agroecologia', 'status': true},
          ]
        });
      }
      return http.Response('not found', 404);
    }));
    await tester.pumpWidget(
      const MaterialApp(home: ManageTaxonomyPage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('agroecologia'), findsOneWidget);
    // Tap no cartão abre o diálogo; salvar deve chamar PATCH no tid
    // real (não em 0).
    await tester.tap(find.text('agroecologia'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salvar'));
    await tester.pumpAndSettle();
    expect(
      calls.any((c) => c == 'PATCH /manage/taxonomy/tags/7'),
      isTrue,
      reason: 'edição deve usar o tid do termo, não 0 — $calls',
    );
  });
}

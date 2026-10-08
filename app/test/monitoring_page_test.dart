import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as upstream;
import 'package:http/testing.dart';
import 'package:neruds_control_center/app_config.dart';
import 'package:neruds_control_center/app_session.dart';
import 'package:neruds_control_center/bridge_http.dart' as http;
import 'package:neruds_control_center/main.dart';

upstream.Response _json(Object value, [int status = 200]) => upstream.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void _session([List<String> roles = const ['extensionista']]) {
  AppSession.instance.setSession(
    tokenValue: 'fixture-monitoring',
    usernameValue: 'extensionista.test',
    rolesValue: roles,
  );
}

void _mockBridge({upstream.Response? Function(upstream.Request)? extra}) {
  http.setClientForTesting(
    MockClient((request) async {
      final custom = extra?.call(request);
      if (custom != null) return custom;
      if (request.url.path.startsWith('/portal/nodes/') &&
          request.url.path.endsWith('/lacunas')) {
        return _json({
          'found': true,
          'nid': 50,
          'missing_fields': ['field_resumo'],
          'missing_labels': ['Resumo'],
        });
      }
      switch (request.url.path) {
        case '/portal/snapshot':
          return _json({
            'online': true,
            'portal_url': 'https://portal.example.test',
            'content_types': ['page', 'noticia'],
            'latest_news': [],
          });
        case '/portal/projetos':
          return _json({
            'fetched_at': '2026-10-07T15:00:00+00:00',
            'projetos': [
              {
                'nid': 20,
                'title': 'Projeto Agrovila',
                'coordinator': 'Maria Silva',
                'start': '2026-01-10',
                'status': ['Em andamento'],
                'kind': ['Extensão'],
                'view_url': 'https://portal.example.test/projetos/agrovila',
                'edit_url': 'https://portal.example.test/node/20/edit',
              },
            ],
            'acoes': [
              {
                'nid': 30,
                'title': 'Ação em Augustinópolis',
                'local': 'Escola Municipal',
                'participants': 40,
                'municipality': ['Augustinópolis'],
                'kind': ['Curso'],
                'view_url': 'https://portal.example.test/acao/x',
                'edit_url': 'https://portal.example.test/node/30/edit',
              },
            ],
            'listing_url': 'https://portal.example.test/projetos',
            'map_url': 'https://portal.example.test/mapa-projetos',
          });
        case '/portal/eventos':
          return _json({
            'fetched_at': '2026-10-07T15:00:00+00:00',
            'events': [
              {
                'nid': 40,
                'title': 'Congresso Regional',
                'days_until': 30,
                'past': false,
                'call_open': true,
                'submission_url': 'https://ex.org/sub',
                'view_url': 'https://portal.example.test/eventos/c',
                'edit_url': 'https://portal.example.test/node/40/edit',
              },
            ],
            'listing_url': 'https://portal.example.test/eventos',
          });
        case '/portal/lacunas':
          final tipo = request.url.queryParameters['tipo'];
          return _json({
            'fetched_at': '2026-10-07T15:00:00+00:00',
            'types': [
              {
                'type': tipo ?? 'publicacao_cientifica',
                'label': 'Tipo',
                'published': 10,
                'listing_url': 'https://portal.example.test/lista',
                'fields': [
                  {
                    'field': 'field_resumo',
                    'label': 'Resumo',
                    'missing': 3,
                    'nodes': [
                      {
                        'nid': 50,
                        'title': 'Ficha incompleta $tipo',
                        'view_url': 'https://portal.example.test/node/50',
                        'edit_url': 'https://portal.example.test/node/50/edit',
                      },
                    ],
                  },
                ],
              },
            ],
          });
        case '/portal/feeds':
          return _json({
            'fetched_at': '2026-10-07T15:00:00+00:00',
            'sections': {
              'noticias': {
                'ok': true,
                'items': [
                  {
                    'title': 'Notícia recente',
                    'link': 'https://portal.example.test/noticias/1',
                    'published': '2026-10-07T10:00:00+00:00',
                  },
                ],
              },
            },
          });
        case '/missions':
          return _json([]);
      }
      return _json({'items': []});
    }),
  );
}

void main() {
  setUp(() {
    AppSession.instance.clear();
    AppConfig.configureForTesting(
      bridgeUrl: 'https://bridge.example.test',
      portalUrl: 'https://portal.example.test',
    );
    _mockBridge();
  });

  tearDown(() {
    AppSession.instance.clear();
    AppConfig.configureForTesting();
    http.resetClientForTesting();
  });

  Future<void> openMonitoring(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1300, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const NerudsControlApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Monitoramento'));
    await tester.pumpAndSettle();
  }

  testWidgets('monitoring tab requires sign-in', (tester) async {
    await openMonitoring(tester);
    expect(find.text('Monitoramento'), findsWidgets);
    expect(find.text('Entrar com minha conta'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('monitoring shows real axes when authenticated', (tester) async {
    _session();
    await openMonitoring(tester);

    expect(find.text('Projeto Agrovila'), findsOneWidget);
    expect(find.text('Ação em Augustinópolis'), findsOneWidget);
    expect(find.textContaining('Coord.: Maria Silva'), findsOneWidget);

    await tester.tap(find.text('Eventos'));
    await tester.pumpAndSettle();
    expect(find.text('Congresso Regional'), findsOneWidget);
    expect(find.textContaining('chamada aberta'), findsOneWidget);

    await tester.tap(find.text('Publicações'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Ficha incompleta'), findsOneWidget);
    expect(find.textContaining('Faltam: Resumo'), findsOneWidget);

    await tester.tap(find.text('Notícias'));
    await tester.pumpAndSettle();
    expect(find.text('Notícia recente'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nova ficha respects session roles', (tester) async {
    _session();
    await openMonitoring(tester);

    await tester.tap(find.text('Nova ficha'));
    await tester.pumpAndSettle();

    // extensionista can create notícia/relatório, not other bundles.
    final noticia = tester.widget<MenuItemButton>(
      find.widgetWithText(MenuItemButton, 'Notícia'),
    );
    expect(noticia.onPressed, isNotNull);
    final projeto = tester.widget<MenuItemButton>(
      find.widgetWithText(MenuItemButton, 'Projeto de pesquisa e extensão'),
    );
    expect(projeto.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('gap card creates a mission task with the real gap', (
    tester,
  ) async {
    Map<String, dynamic>? posted;
    _mockBridge(
      extra: (request) {
        if (request.url.path == '/missions' && request.method == 'GET') {
          return _json([
            {'id': 1, 'title': 'Gestão do Portal'},
          ]);
        }
        if (request.url.path == '/missions/1/tasks' &&
            request.method == 'POST') {
          posted = Map<String, dynamic>.from(
            jsonDecode(utf8.decode(request.bodyBytes)) as Map,
          );
          return _json({'id': 99}, 201);
        }
        return null;
      },
    );
    _session();
    await openMonitoring(tester);

    await tester.tap(find.text('Publicações'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('gap-task-50')));
    await tester.pumpAndSettle();
    expect(find.text('Criar tarefa a partir da lacuna'), findsOneWidget);
    expect(find.textContaining('Faltam: Resumo'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('gap-task-confirm')));
    await tester.pumpAndSettle();

    expect(posted, isNotNull);
    expect(posted?['gap_bundle'], 'publicacao_cientifica');
    expect(posted?['gap_fields'], ['field_resumo']);
    expect(posted?['public_url'], 'https://portal.example.test/node/50');
    expect(posted?['edit_url'], 'https://portal.example.test/node/50/edit');
    expect(posted?['responsible'], 'extensionista.test');
    expect(
      find.text('Tarefa criada na missão — acompanhe na aba Inventário.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('gap task records the fresh ficha gaps, not the clipped sample', (
    tester,
  ) async {
    Map<String, dynamic>? posted;
    _mockBridge(
      extra: (request) {
        if (request.url.path == '/missions' && request.method == 'GET') {
          return _json([
            {'id': 1, 'title': 'Gestão do Portal'},
          ]);
        }
        if (request.url.path == '/portal/nodes/50/lacunas') {
          // The aggregated report clipped this node out of other fields'
          // samples; the fresh check reports all currently-missing ones.
          return _json({
            'found': true,
            'nid': 50,
            'missing_fields': ['field_resumo', 'field_doi'],
            'missing_labels': ['Resumo', 'DOI'],
          });
        }
        if (request.url.path == '/missions/1/tasks' &&
            request.method == 'POST') {
          posted = Map<String, dynamic>.from(
            jsonDecode(utf8.decode(request.bodyBytes)) as Map,
          );
          return _json({'id': 99}, 201);
        }
        return null;
      },
    );
    _session();
    await openMonitoring(tester);

    await tester.tap(find.text('Publicações'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('gap-task-50')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Faltam: Resumo, DOI'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('gap-task-confirm')));
    await tester.pumpAndSettle();

    expect(posted?['gap_fields'], ['field_resumo', 'field_doi']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('gap task skips creation when the ficha is already filled', (
    tester,
  ) async {
    var posted = false;
    _mockBridge(
      extra: (request) {
        if (request.url.path == '/missions' && request.method == 'GET') {
          return _json([
            {'id': 1, 'title': 'Gestão do Portal'},
          ]);
        }
        if (request.url.path == '/portal/nodes/50/lacunas') {
          return _json({
            'found': true,
            'nid': 50,
            'missing_fields': <String>[],
            'missing_labels': <String>[],
          });
        }
        if (request.url.path == '/missions/1/tasks' &&
            request.method == 'POST') {
          posted = true;
          return _json({'id': 99}, 201);
        }
        return null;
      },
    );
    _session();
    await openMonitoring(tester);

    await tester.tap(find.text('Publicações'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('gap-task-50')));
    await tester.pumpAndSettle();

    expect(posted, isFalse);
    expect(
      find.textContaining('já estão preenchidos no portal'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

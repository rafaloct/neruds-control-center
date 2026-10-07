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

void _session() {
  AppSession.instance.setSession(
    tokenValue: 'fixture-attention',
    usernameValue: 'research.test',
  );
}

void main() {
  setUp(() {
    AppSession.instance.clear();
    AppConfig.configureForTesting(bridgeUrl: 'https://bridge.example.test');
    http.setClientForTesting(
      MockClient((request) async {
        switch (request.url.path) {
          case '/portal/snapshot':
            return _json({
              'online': true,
              'portal_url': 'https://portal.example.test',
              'content_types': ['page', 'noticia'],
              'latest_news': [],
            });
          case '/portal/eventos':
            return _json({
              'fetched_at': '2026-10-07T15:00:00+00:00',
              'events': [
                {
                  'nid': 10,
                  'title': 'Congresso de Extensão Rural',
                  'date': '2999-05-10T09:00:00+00:00',
                  'days_until': 900,
                  'past': false,
                  'local': 'Palmas',
                  'signup_url': 'https://ex.org/insc',
                  'view_url': 'https://portal.example.test/eventos/x',
                  'edit_url': 'https://portal.example.test/node/10/edit',
                },
              ],
              'listing_url': 'https://portal.example.test/eventos',
            });
          case '/portal/lacunas':
            return _json({
              'fetched_at': '2026-10-07T15:00:00+00:00',
              'types': [
                {
                  'type': 'publicacao_cientifica',
                  'label': 'Publicação Científica',
                  'published': 169,
                  'listing_url': 'https://portal.example.test/publicacoes',
                  'fields': [
                    {
                      'field': 'field_resumo_publicacao',
                      'label': 'Resumo',
                      'kind': 'attribute',
                      'missing': 137,
                      'nodes': [],
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
                      'nid': 1,
                      'title': 'Notícia nova no portal',
                      'link': 'https://portal.example.test/noticias/a',
                      'published': '2026-10-07T10:00:00+00:00',
                    },
                  ],
                },
              },
            });
          case '/content/news/drafts':
            return _json({'items': [{'nid': 5}], 'can_review': true});
          case '/missions':
            return _json([]);
        }
        return _json({'items': []});
      }),
    );
  });

  tearDown(() {
    AppSession.instance.clear();
    AppConfig.configureForTesting();
    http.resetClientForTesting();
  });

  testWidgets('home shows the sign-in prompt when not authenticated', (
    tester,
  ) async {
    await tester.pumpWidget(const NerudsControlApp());
    await tester.pumpAndSettle();
    expect(find.text('Precisa de atenção'), findsOneWidget);
    expect(find.text('Entrar com minha conta'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('attention panel shows real sections when authenticated', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1300, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    _session();
    await tester.pumpWidget(const NerudsControlApp());
    await tester.pumpAndSettle();

    expect(find.text('Prazos de eventos'), findsOneWidget);
    expect(find.text('Congresso de Extensão Rural'), findsOneWidget);
    expect(find.textContaining('em 900 dias'), findsOneWidget);

    expect(find.text('Revisão editorial'), findsOneWidget);
    expect(find.textContaining('1 rascunho aguarda'), findsOneWidget);

    expect(find.text('Lacunas do inventário'), findsOneWidget);
    expect(find.text('Publicação Científica · Resumo'), findsOneWidget);
    expect(find.textContaining('137 fichas sem'), findsOneWidget);

    expect(find.text('Novidades do portal'), findsOneWidget);
    expect(find.text('Notícia nova no portal'), findsOneWidget);

    expect(find.textContaining('Dados de'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sections survive individual endpoint failures', (tester) async {
    tester.view.physicalSize = const Size(1300, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    http.setClientForTesting(
      MockClient((request) async {
        if (request.url.path == '/portal/snapshot') {
          return _json({'online': true, 'latest_news': []});
        }
        if (request.url.path == '/portal/eventos') return _json({}, 500);
        if (request.url.path == '/portal/lacunas') {
          return _json({'fetched_at': '2026-10-07T15:00:00Z', 'types': []});
        }
        if (request.url.path == '/portal/feeds') {
          return _json({
            'fetched_at': '2026-10-07T15:00:00Z',
            'sections': {
              'eventos': {'ok': false, 'items': []},
            },
          });
        }
        if (request.url.path == '/content/news/drafts') {
          return _json({'items': []});
        }
        return _json({'items': []});
      }),
    );
    _session();
    await tester.pumpWidget(const NerudsControlApp());
    await tester.pumpAndSettle();
    // failed section explains itself, the others still render
    expect(find.text('Prazos de eventos'), findsOneWidget);
    expect(find.text('Lacunas do inventário'), findsOneWidget);
    expect(find.text('Nenhum rascunho aguardando revisão.'), findsOneWidget);
    // a feed subsection that failed on the bridge is surfaced, not silent
    expect(
      find.textContaining('Seções indisponíveis nesta consulta: eventos'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

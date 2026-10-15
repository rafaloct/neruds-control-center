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

void _session({bool reviewer = false, String username = 'research.test'}) {
  AppSession.instance.setSession(
    tokenValue: 'fixture-$username',
    usernameValue: username,
    canReviewValue: reviewer,
  );
}

/// Attention fixtures for each endpoint the home load consults. Sections not
/// listed resolve to empty data, keeping each test focused on one signal.
void _mockBridge({
  List<Object> events = const [],
  List<Object> gapTypes = const [],
  List<Object> drafts = const [],
}) {
  http.setClientForTesting(
    MockClient((request) async {
      switch (request.url.path) {
        case '/portal/snapshot':
          return _json({
            'online': true,
            'portal_url': 'https://portal.example.test',
            'latest_news': [],
          });
        case '/portal/eventos':
          return _json({
            'fetched_at': '2026-10-15T15:00:00Z',
            'events': events,
          });
        case '/portal/lacunas':
          return _json({
            'fetched_at': '2026-10-15T15:00:00Z',
            'types': gapTypes,
          });
        case '/portal/feeds':
          return _json({'fetched_at': '2026-10-15T15:00:00Z', 'sections': {}});
        case '/content/news/drafts':
          return _json({'items': drafts});
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
    AppConfig.configureForTesting(bridgeUrl: 'https://bridge.example.test');
    _mockBridge();
  });
  tearDown(() {
    AppSession.instance.clear();
    AppConfig.configureForTesting();
    http.resetClientForTesting();
  });

  testWidgets('signed-out home guides the first step into sign-in', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1300, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const NerudsControlApp());
    await tester.pumpAndSettle();

    expect(find.text('Comece por aqui'), findsOneWidget);
    expect(find.text('Entre com a sua conta'), findsOneWidget);
    expect(find.text('Veja o que precisa de atenção'), findsOneWidget);
    expect(
      find.text('Escolha uma tarefa e registre o que fez'),
      findsOneWidget,
    );
    expect(find.text('O que faço agora?'), findsOneWidget);

    await tester.tap(
      find.widgetWithText(FilledButton, 'Entrar com minha conta').first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Entrar no NERUDS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('review queue is the next action for a reviewer', (tester) async {
    tester.view.physicalSize = const Size(1300, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    _mockBridge(
      drafts: [
        {'nid': 5},
        {'nid': 8},
      ],
    );
    _session(reviewer: true);
    await tester.pumpWidget(const NerudsControlApp());
    await tester.pumpAndSettle();

    expect(
      find.text('2 rascunhos aguardam revisão antes da publicação.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Revisar rascunhos pendentes'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('news-title')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a near event deadline outranks routine work', (tester) async {
    tester.view.physicalSize = const Size(1300, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    _mockBridge(
      events: [
        {
          'nid': 10,
          'title': 'Chamada de trabalhos da semana de extensão',
          'days_until': 6,
          'past': false,
          'published': true,
        },
      ],
      gapTypes: [
        {
          'type': 'publicacao_cientifica',
          'label': 'Publicação Científica',
          'fields': [
            {'field': 'field_resumo', 'label': 'Resumo', 'missing': 137},
          ],
        },
      ],
    );
    _session();
    await tester.pumpWidget(const NerudsControlApp());
    await tester.pumpAndSettle();

    expect(
      find.text(
        'O prazo de "Chamada de trabalhos da semana de extensão" '
        'é em 6 dias.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Ver prazos em Monitoramento'));
    await tester.pumpAndSettle();
    expect(find.text('O trabalho do núcleo, em continuidade'), findsNothing);
    expect(find.text('Monitoramento'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inventory gaps become the next action when nothing is urgent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1300, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    _mockBridge(
      gapTypes: [
        {
          'type': 'publicacao_cientifica',
          'label': 'Publicação Científica',
          'fields': [
            {'field': 'field_resumo', 'label': 'Resumo', 'missing': 137},
          ],
        },
      ],
    );
    _session();
    await tester.pumpWidget(const NerudsControlApp());
    await tester.pumpAndSettle();

    expect(
      find.text('137 fichas de Publicação Científica estão sem Resumo.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Completar fichas do inventário'));
    await tester.pumpAndSettle();
    expect(find.text('Trabalho do núcleo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty board recommends the opportunities box', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1300, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    _session();
    await tester.pumpWidget(const NerudsControlApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Examinar oportunidades'));
    await tester.pumpAndSettle();
    expect(find.text('Caixa de oportunidades'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('steps expose position and state to screen readers', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    _mockBridge();
    _session();
    await tester.pumpWidget(const NerudsControlApp());
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel('Passo 1 de 3: Entre com a sua conta — concluído'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        'Passo 2 de 3: Veja o que precisa de atenção — concluído',
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        'Passo 3 de 3: Escolha uma tarefa e registre o que fez — pendente',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('signing out returns the card to the first step', (tester) async {
    _session();
    await tester.pumpWidget(const NerudsControlApp());
    await tester.pumpAndSettle();
    expect(find.text('Examinar oportunidades'), findsOneWidget);

    AppSession.instance.clear();
    await tester.pumpAndSettle();
    expect(find.text('O que faço agora?'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Entrar com minha conta'),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the card fits a narrow screen with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(const NerudsControlApp());
    await tester.pumpAndSettle();

    expect(find.text('Comece por aqui'), findsOneWidget);
    expect(find.text('O que faço agora?'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

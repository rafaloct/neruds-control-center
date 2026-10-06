import 'dart:async';
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

void _session({bool admin = false, String username = 'research.test'}) {
  AppSession.instance.setSession(
    tokenValue: 'fixture-$username',
    usernameValue: username,
    canAdminUsersValue: admin,
  );
}

void main() {
  setUp(() {
    AppSession.instance.clear();
    AppConfig.configureForTesting(bridgeUrl: 'https://bridge.example.test');
    http.setClientForTesting(
      MockClient((request) async {
        if (request.url.path == '/portal/snapshot') {
          return _json({
            'online': true,
            'portal_url': 'https://portal.example.test',
            'content_types': ['page', 'noticia'],
            'latest_news': [],
          });
        }
        if (request.url.path == '/missions') return _json([]);
        if (request.url.path == '/auth/login') {
          return _json({
            'token': 'fixture-signed-in',
            'username': 'research.test',
            'roles': ['extensionista'],
          });
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

  testWidgets('a first task opens a shared individual sign-in', (tester) async {
    await tester.pumpWidget(const NerudsControlApp());
    await tester.pumpAndSettle();
    expect(find.text('O trabalho do núcleo, em continuidade'), findsOneWidget);
    await tester.tap(find.text('Conteúdo').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entrar com minha conta'));
    await tester.pumpAndSettle();
    expect(find.text('Entrar no NERUDS'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Usuário'),
      'research.test',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Senha'),
      'fixture-only',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Entrar'));
    await tester.pumpAndSettle();
    expect(AppSession.instance.authenticated, isTrue);
    expect(find.byKey(const Key('news-title')), findsOneWidget);
    expect(find.text('Administração'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('draft survives tab changes and desktop-to-narrow resize', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1250, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    _session();
    await tester.pumpWidget(const NerudsControlApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conteúdo'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('news-title')),
      'Proposta em andamento',
    );
    await tester.tap(find.text('Inventário'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conteúdo'));
    await tester.pumpAndSettle();
    expect(find.text('Proposta em andamento'), findsOneWidget);
    tester.view.physicalSize = const Size(400, 900);
    await tester.pumpAndSettle();
    expect(find.text('Proposta em andamento'), findsOneWidget);
    expect(tester.takeException(), isNull);

    AppSession.instance.expire();
    await tester.pumpAndSettle();
    _session();
    await tester.pumpAndSettle();
    expect(find.text('Proposta em andamento'), findsOneWidget);
    _session(username: 'colleague.test');
    await tester.pumpAndSettle();
    expect(find.text('Proposta em andamento'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('administration follows capability and clears when access ends', (
    tester,
  ) async {
    _session(admin: true);
    await tester.pumpWidget(const NerudsControlApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Administração'));
    await tester.pumpAndSettle();
    expect(find.text('Usuários e papéis'), findsOneWidget);
    AppSession.instance.expire();
    await tester.pumpAndSettle();
    expect(find.text('Usuários e papéis'), findsNothing);
    expect(find.text('Administração'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'home and account prompt fit a narrow screen with enlarged text',
    (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(const NerudsControlApp());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Conteúdo'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Entrar com minha conta'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Entrar no NERUDS'), findsOneWidget);
    },
  );
  testWidgets('pending sign-out freezes editing and a failed exit resumes it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pending = Completer<upstream.Response>();
    http.setClientForTesting(
      MockClient((request) async {
        if (request.url.path == '/auth/logout') return pending.future;
        if (request.url.path == '/portal/snapshot') {
          return _json({'online': true, 'latest_news': []});
        }
        return _json({'items': []});
      }),
    );
    _session();
    await tester.pumpWidget(const NerudsControlApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conteúdo'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('news-title')),
      'Rascunho a preservar',
    );
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sair da conta'));
    // The pending-exit indicator deliberately keeps animating behind the dialog.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Descartar e continuar'));
    await tester.pump();
    expect(find.text('Encerrando a sessão'), findsOneWidget);
    final editGuard = find.ancestor(
      of: find.byKey(const Key('news-title')),
      matching: find.byType(AbsorbPointer),
    );
    expect(
      tester
          .widgetList<AbsorbPointer>(editGuard)
          .any((widget) => widget.absorbing),
      isTrue,
    );
    final focusGuard = find.ancestor(
      of: find.byKey(const Key('news-title')),
      matching: find.byType(ExcludeFocus),
    );
    expect(
      tester
          .widgetList<ExcludeFocus>(focusGuard)
          .any((widget) => widget.excluding),
      isTrue,
    );
    pending.complete(_json({}, 503));
    await tester.pumpAndSettle();
    expect(find.text('Encerrando a sessão'), findsNothing);
    expect(find.text('Rascunho a preservar'), findsOneWidget);
    expect(AppSession.instance.authenticated, isTrue);
    expect(tester.takeException(), isNull);
  });
}

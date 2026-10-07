import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as upstream;
import 'package:http/testing.dart';
import 'package:neruds_control_center/app_config.dart';
import 'package:neruds_control_center/app_session.dart';
import 'package:neruds_control_center/bridge_http.dart' as http;
import 'package:neruds_control_center/drupal_api.dart';
import 'package:neruds_control_center/session_widgets.dart';
import 'package:neruds_control_center/unsaved_work.dart';

void _signIn(String token, [String username = 'research.test']) {
  AppSession.instance.setSession(
    tokenValue: token,
    usernameValue: username,
    canReviewValue: true,
    canAdminUsersValue: true,
  );
}

upstream.Response _json(Object value, [int status = 200]) => upstream.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  setUp(() {
    AppSession.instance.clear();
    AppConfig.configureForTesting(bridgeUrl: 'https://bridge.example.test');
  });
  tearDown(() {
    AppSession.instance.clear();
    AppConfig.configureForTesting();
    http.resetClientForTesting();
  });

  test(
    'expiry preserves draft identity, explicit exit and user switch do not',
    () {
      _signIn('first');
      final epoch = AppSession.instance.identityEpoch;
      AppSession.instance.expire();
      expect(AppSession.instance.authenticated, isFalse);
      expect(AppSession.instance.canAdminUsers, isFalse);
      expect(AppSession.instance.roles, isEmpty);
      expect(AppSession.instance.identityEpoch, epoch);
      _signIn('renewed');
      expect(AppSession.instance.identityEpoch, epoch);
      _signIn('different', 'colleague.test');
      expect(AppSession.instance.identityEpoch, greaterThan(epoch));
      final next = AppSession.instance.identityEpoch;
      AppSession.instance.clear();
      expect(AppSession.instance.identityEpoch, greaterThan(next));
      expect(AppSession.instance.reauthenticationUsername, isNull);
    },
  );

  test(
    'only a 401 for the current bearer expires the active session',
    () async {
      final pending = Completer<upstream.Response>();
      http.setClientForTesting(MockClient((_) => pending.future));
      _signIn('old');
      final request = http.get(
        AppConfig.endpoint('/missions'),
        headers: AppSession.instance.authHeaders,
      );
      _signIn('new');
      pending.complete(_json({}, 401));
      await request;
      expect(AppSession.instance.token, 'new');

      http.setClientForTesting(MockClient((_) async => _json({}, 401)));
      await http.post(
        AppConfig.endpoint('/auth/login'),
        body: '{}',
        headers: {'Content-Type': 'application/json'},
      );
      expect(AppSession.instance.token, 'new');

      await http.get(
        AppConfig.endpoint('/missions'),
        headers: AppSession.instance.authHeaders,
      );
      expect(AppSession.instance.authenticated, isFalse);
      expect(AppSession.instance.expired, isTrue);
    },
  );

  test(
    'configuration appends a service prefix and rejects credentials/schemes',
    () {
      AppConfig.configureForTesting(
        bridgeUrl: 'https://bridge.example.test/service/',
      );
      expect(
        AppConfig.endpoint('/missions').toString(),
        'https://bridge.example.test/service/missions',
      );
      expect(AppConfig.webUri('javascript:alert(1)'), isNull);
      expect(AppConfig.webUri('https://person:password@example.test'), isNull);
      expect(() => AppConfig.endpoint('//elsewhere.test'), throwsArgumentError);
      AppConfig.configureForTesting(bridgeUrl: '');
      expect(
        () => AppConfig.endpoint('/auth/login'),
        throwsA(isA<AppConfigurationException>()),
      );
    },
  );

  test(
    'remote bridge requires TLS while explicit loopback supports local QA',
    () {
      for (final address in const [
        'http://bridge.example.test',
        'http://192.0.2.10:8787',
        'http://localhost.example.test:8787',
        'http://127.0.0.1.example.test:8787',
      ]) {
        AppConfig.configureForTesting(bridgeUrl: address);
        expect(AppConfig.isConfigured, isFalse, reason: address);
        expect(
          () => AppConfig.endpoint('/auth/login'),
          throwsA(isA<AppConfigurationException>()),
          reason: address,
        );
      }
      for (final address in const [
        'https://bridge.example.test/service',
        'http://localhost:8787',
        'http://127.0.0.1:8787',
        'http://[::1]:8787',
      ]) {
        AppConfig.configureForTesting(bridgeUrl: address);
        expect(AppConfig.isConfigured, isTrue, reason: address);
        expect(AppConfig.endpoint('/auth/login').path, endsWith('/auth/login'));
      }
      expect(AppConfig.webUri('http://portal.example.test'), isNotNull);
    },
  );

  testWidgets('an unsafe bridge cannot receive sign-in credentials', (
    tester,
  ) async {
    AppConfig.configureForTesting(bridgeUrl: 'http://bridge.example.test');
    var calls = 0;
    http.setClientForTesting(
      MockClient((request) async {
        calls++;
        return _json({'token': 'unexpected-token', 'username': 'qa.editor'});
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSignInDialog(context),
              child: const Text('Abrir entrada'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Abrir entrada'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'qa.editor');
    await tester.enterText(
      find.byType(TextFormField).at(1),
      'synthetic-password',
    );
    await tester.tap(find.text('Entrar'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(AppSession.instance.authenticated, isFalse);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('configurada'), findsOneWidget);
  });

  test(
    'snapshot also rejects a plaintext remote bridge before a request',
    () async {
      var calls = 0;
      http.setClientForTesting(
        MockClient((request) async {
          calls++;
          return _json({'online': true});
        }),
      );
      final snapshot = await DrupalApi(
        bridgeUrl: 'http://bridge.example.test',
      ).loadSnapshot();
      expect(calls, 0);
      expect(snapshot.online, isFalse);
      expect(snapshot.error, isNotNull);
    },
  );

  test(
    'snapshot catches asynchronous failures without exposing an endpoint',
    () async {
      http.setClientForTesting(
        MockClient((_) async {
          throw upstream.ClientException(
            'private service detail should stay private',
          );
        }),
      );
      final result = await DrupalApi().loadSnapshot();
      expect(result.online, isFalse);
      expect(result.latestNews, isEmpty);
      expect(result.error, contains('conectar'));
      expect(result.error, isNot(contains('private')));
      expect(result.error, isNot(contains('example.test')));
    },
  );

  test(
    'snapshot retains actual labels and public links, hides unpublished news',
    () async {
      http.setClientForTesting(
        MockClient(
          (_) async => _json({
            'online': true,
            'portal_url': 'https://portal.example.test',
            'content_types': ['page', 'noticia'],
            'content_type_labels': {'page': 'Página institucional'},
            'latest_news': [
              {
                'title': 'Chamada revisada',
                'published': true,
                'public_url': 'https://portal.example.test/node/20',
              },
              {'title': 'Rascunho privado', 'published': false},
            ],
          }),
        ),
      );
      final result = await DrupalApi().loadSnapshot();
      expect(result.contentTypes, contains('page'));
      expect(result.contentTypeLabels['page'], 'Página institucional');
      expect(
        result.latestNews.single['public_url'],
        'https://portal.example.test/node/20',
      );
      expect(AppConfig.portalUrl, 'https://portal.example.test');
    },
  );

  testWidgets('canceling sign-out keeps unsaved work and sends no logout', (
    tester,
  ) async {
    var calls = 0;
    final owner = Object();
    UnsavedWork.instance.setDirty(owner, true);
    addTearDown(() => UnsavedWork.instance.remove(owner));
    _signIn('active');
    http.setClientForTesting(
      MockClient((_) async {
        calls++;
        return _json({'ok': true});
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => signOut(context),
              child: const Text('Sair'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Sair'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continuar trabalhando'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(AppSession.instance.authenticated, isTrue);
    expect(UnsavedWork.instance.hasChanges, isTrue);
  });

  testWidgets(
    'sign-out requires service confirmation before clearing identity',
    (tester) async {
      _signIn('active');
      var status = 503;
      var calls = 0;
      http.setClientForTesting(
        MockClient((request) async {
          calls++;
          expect(request.url.path, '/auth/logout');
          expect(request.method, 'POST');
          expect(request.headers['Authorization'], 'Bearer active');
          return _json({'ok': status == 200}, status);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => signOut(context),
                child: const Text('Sair'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Sair'));
      await tester.pumpAndSettle();
      expect(AppSession.instance.authenticated, isTrue);
      expect(find.textContaining('não confirmou a saída'), findsOneWidget);
      status = 200;
      await tester.tap(find.text('Sair'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(AppSession.instance.authenticated, isFalse);
      expect(AppSession.instance.reauthenticationUsername, isNull);
    },
  );
}

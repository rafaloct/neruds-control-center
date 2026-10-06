import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as upstream;
import 'package:http/testing.dart';
import 'package:neruds_control_center/app_config.dart';
import 'package:neruds_control_center/app_session.dart';
import 'package:neruds_control_center/bridge_http.dart' as http;
import 'package:neruds_control_center/identity_page.dart';

upstream.Response _json(Object value, [int status = 200]) => upstream.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> _account(int uid, String name, String mail) => {
  'uid': uid,
  'name': name,
  'mail': mail,
  'active': true,
  'last_access': 0,
  'open_tasks': 2,
  'pending_drafts': 0,
};

final _accounts = [
  _account(11, 'extension.first', 'first@example.test'),
  _account(12, 'extension.next', 'next@example.test'),
];

upstream.Response _readFixture(upstream.Request request) {
  if (request.method == 'GET' && request.url.path == '/identity/roster') {
    return _json({'accounts': _accounts});
  }
  if (request.method == 'GET' && request.url.path == '/identity/events') {
    return _json({'items': []});
  }
  return _json({'detail': 'Solicitação inesperada no teste.'}, 404);
}

Future<void> _mount(WidgetTester tester, {double width = 1000}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: IdentityPage())),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(
  WidgetTester tester,
  Finder finder, {
  bool settle = true,
}) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }
}

Future<void> _openProvision(WidgetTester tester) async {
  await _tap(tester, find.text('Criar conta extensionista'));
  await tester.enterText(find.byType(TextFormField).at(0), 'extension.new');
  await tester.enterText(
    find.byType(TextFormField).at(1),
    'person.one@example.test',
  );
}

Future<void> _openAccountAction(WidgetTester tester, String action) async {
  await _tap(tester, find.byTooltip('Ações da conta extension.first'));
  // The reset dialog keeps the page busy until the result is dismissed.
  await _tap(tester, find.text(action), settle: false);
}

Future<void> _checkSecretExpires(
  WidgetTester tester, {
  required String secret,
  required String copyLabel,
}) async {
  expect(find.text(secret), findsOneWidget);
  expect(find.text(copyLabel), findsOneWidget);
  AppSession.instance.expire();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  expect(find.text('Sessão encerrada'), findsOneWidget);
  expect(find.text(secret), findsNothing);
  expect(find.text(copyLabel), findsNothing);

  AppSession.instance.setSession(
    tokenValue: 'replacement-admin-token',
    usernameValue: 'another.admin',
    canAdminUsersValue: true,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  expect(find.text(secret), findsNothing);
  expect(find.text(copyLabel), findsNothing);
  await _tap(tester, find.text('Fechar'));
}

void main() {
  setUp(() {
    AppSession.instance.clear();
    AppSession.instance.setSession(
      tokenValue: 'identity-test-token',
      usernameValue: 'admin.test',
      canAdminUsersValue: true,
    );
    AppConfig.configureForTesting(bridgeUrl: 'https://bridge.example.test');
  });
  tearDown(() {
    AppSession.instance.clear();
    AppConfig.configureForTesting();
    http.resetClientForTesting();
  });

  testWidgets(
    'e-mail comum chega ao POST e senha temporária some ao expirar ou trocar conta',
    (tester) async {
      const secret = 'TEMPORARY-TEST-ONLY';
      final requests = <Map<String, dynamic>>[];
      http.setClientForTesting(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path == '/identity/accounts') {
            requests.add(
              Map<String, dynamic>.from(jsonDecode(request.body) as Map),
            );
            return _json({
              'drupal': {'temporary_password': secret},
            }, 201);
          }
          return _readFixture(request);
        }),
      );
      await _mount(tester, width: 400);
      await _openProvision(tester);
      await _tap(tester, find.text('Criar conta'));

      expect(requests, [
        {'name': 'extension.new', 'mail': 'person.one@example.test'},
      ]);
      expect(find.text('Informe um e-mail válido.'), findsNothing);
      expect(find.text('Conta criada'), findsOneWidget);
      await _checkSecretExpires(
        tester,
        secret: secret,
        copyLabel: 'Copiar senha',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '503 no cadastro mantém usuário e e-mail para uma nova tentativa',
    (tester) async {
      final requests = <Map<String, dynamic>>[];
      var status = 503;
      http.setClientForTesting(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path == '/identity/accounts') {
            requests.add(
              Map<String, dynamic>.from(jsonDecode(request.body) as Map),
            );
            return status == 503
                ? _json({'detail': 'Cadastro indisponível neste momento.'}, 503)
                : _json({'drupal': {}}, 201);
          }
          return _readFixture(request);
        }),
      );
      await _mount(tester);
      await _openProvision(tester);
      await _tap(tester, find.text('Criar conta'));

      expect(requests, hasLength(1));
      expect(find.text('Cadastro indisponível neste momento.'), findsOneWidget);
      expect(find.text('Conta criada'), findsNothing);
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).at(0))
            .controller!
            .text,
        'extension.new',
      );
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).at(1))
            .controller!
            .text,
        'person.one@example.test',
      );

      status = 201;
      await _tap(tester, find.text('Criar conta'));
      expect(requests, hasLength(2));
      expect(requests[1], requests[0]);
      expect(find.text('Conta criada'), findsOneWidget);
      await _tap(tester, find.text('Fechar'));
    },
  );

  testWidgets('link de recuperação desaparece quando a sessão expira', (
    tester,
  ) async {
    const secret = 'https://portal.example.test/user/reset/synthetic-test-only';
    http.setClientForTesting(
      MockClient((request) async {
        if (request.method == 'POST' &&
            request.url.path == '/identity/accounts/11/password-reset') {
          return _json({'reset_url': secret});
        }
        return _readFixture(request);
      }),
    );
    await _mount(tester);
    await _openAccountAction(tester, 'Gerar link de reset de senha');
    await _checkSecretExpires(tester, secret: secret, copyLabel: 'Copiar link');
  });

  testWidgets(
    '503 no encerramento mantém observação e destino até confirmação',
    (tester) async {
      final requests = <Map<String, dynamic>>[];
      var status = 503;
      http.setClientForTesting(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path == '/identity/accounts/11/offboarding') {
            requests.add(
              Map<String, dynamic>.from(jsonDecode(request.body) as Map),
            );
            return status == 503
                ? _json({
                    'detail': 'Encerramento indisponível neste momento.',
                  }, 503)
                : _json({'tasks_transferred': 2, 'advisories': []});
          }
          return _readFixture(request);
        }),
      );
      await _mount(tester, width: 400);
      await _openAccountAction(tester, 'Offboarding (fim da bolsa)');
      final destination = find.byType(DropdownButtonFormField<String>);
      await _tap(tester, destination);
      await _tap(tester, find.text('extension.next').last);
      await tester.enterText(
        find.byKey(const Key('offboarding-note')),
        'Continuar a conferência das fontes na ficha existente.',
      );
      await _tap(tester, find.text('Encerrar acesso'));

      expect(requests, [
        {
          'transfer_to': 'extension.next',
          'note': 'Continuar a conferência das fontes na ficha existente.',
        },
      ]);
      expect(
        find.text('Encerramento indisponível neste momento.'),
        findsOneWidget,
      );
      expect(find.text('Encerramento registrado'), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('offboarding-note')))
            .controller!
            .text,
        'Continuar a conferência das fontes na ficha existente.',
      );
      expect(
        tester.state<FormFieldState<String>>(destination).value,
        'extension.next',
      );

      status = 200;
      await _tap(tester, find.text('Encerrar acesso'));
      expect(requests, hasLength(2));
      expect(requests[1], requests[0]);
      expect(find.text('Encerramento registrado'), findsOneWidget);
      await _tap(tester, find.text('Entendi'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('falha de roster não vira equipe ou histórico vazio', (
    tester,
  ) async {
    var rosterStatus = 503;
    var historyCalls = 0;
    http.setClientForTesting(
      MockClient((request) async {
        if (request.url.path == '/identity/roster') {
          return rosterStatus == 503
              ? _json({'detail': 'Equipe indisponível nesta consulta.'}, 503)
              : _json({'accounts': []});
        }
        if (request.url.path == '/identity/events') {
          historyCalls++;
          return _json({'items': []});
        }
        return _readFixture(request);
      }),
    );
    await _mount(tester);
    expect(find.text('A consulta à equipe falhou'), findsOneWidget);
    expect(find.text('Equipe indisponível nesta consulta.'), findsOneWidget);
    expect(find.text('O histórico não pôde ser consultado.'), findsOneWidget);
    expect(find.text('Nenhuma conta extensionista.'), findsNothing);
    expect(find.text('Nenhum evento registrado.'), findsNothing);
    expect(historyCalls, 0);

    rosterStatus = 200;
    await _tap(tester, find.text('Atualizar equipe'));
    expect(historyCalls, 1);
    expect(find.text('A consulta à equipe falhou'), findsNothing);
    expect(find.text('Nenhuma conta extensionista.'), findsOneWidget);
    expect(find.text('Nenhum evento registrado.'), findsOneWidget);
  });

  testWidgets('falha só do histórico mantém equipe e permite nova consulta', (
    tester,
  ) async {
    var historyStatus = 503;
    http.setClientForTesting(
      MockClient((request) async {
        if (request.url.path == '/identity/events') {
          return historyStatus == 503
              ? _json({'detail': 'Histórico indisponível.'}, 503)
              : _json({'items': []});
        }
        return _readFixture(request);
      }),
    );
    await _mount(tester);
    expect(find.text('extension.first — first@example.test'), findsOneWidget);
    expect(
      find.text('Não foi possível consultar o histórico. Tente novamente.'),
      findsOneWidget,
    );
    expect(find.text('Nenhum evento registrado.'), findsNothing);
    expect(find.text('A consulta à equipe falhou'), findsNothing);

    historyStatus = 200;
    await _tap(tester, find.text('Atualizar equipe'));
    expect(find.text('Nenhum evento registrado.'), findsOneWidget);
    expect(
      find.text('Não foi possível consultar o histórico. Tente novamente.'),
      findsNothing,
    );
  });
}

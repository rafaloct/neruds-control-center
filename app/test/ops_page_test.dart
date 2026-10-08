import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as upstream;
import 'package:http/testing.dart';
import 'package:neruds_control_center/app_config.dart';
import 'package:neruds_control_center/app_session.dart';
import 'package:neruds_control_center/bridge_http.dart' as http;
import 'package:neruds_control_center/ops_page.dart';

upstream.Response _json(Object value, [int status = 200]) => upstream.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> _status() => {
  'time': '2026-10-08T12:00:00+00:00',
  'version': '0.5.0',
  'uptime_seconds': 3720,
  'probes': [
    {'name': 'drupal_portal', 'ok': true, 'http_status': 200, 'duration_ms': 120.0},
    {'name': 'tailscale_serve', 'ok': true, 'http_status': 200, 'duration_ms': 30.0},
    {'name': 'posteio_smtp', 'ok': false, 'error': 'SocketException', 'duration_ms': 5.0},
    {'name': 'mission_db', 'ok': true, 'duration_ms': 1.0},
  ],
  'backup': {
    'keep': 14,
    'count': 3,
    'latest': {
      'file': 'missions-20261008-110000.sqlite3',
      'size_bytes': 1024,
      'created_at': '2026-10-08T11:00:00+00:00',
    },
  },
};

void _adminSession() {
  AppSession.instance.setSession(
    tokenValue: 'fixture-ops',
    usernameValue: 'coordenador.test',
    canAdminUsersValue: true,
  );
}

Widget _wrap() => const MaterialApp(home: Scaffold(body: OpsPage()));

void main() {
  setUp(() {
    AppSession.instance.clear();
    AppConfig.configureForTesting(bridgeUrl: 'https://bridge.example.test');
    _adminSession();
  });

  tearDown(() {
    http.resetClientForTesting();
    AppSession.instance.clear();
  });

  testWidgets('renderiza probes e último backup', (tester) async {
    http.setClientForTesting(
      MockClient((request) async {
        expect(request.url.path, '/ops/status');
        return _json(_status());
      }),
    );

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('Portal Drupal (neruds.org)'), findsOneWidget);
    expect(find.text('Tailscale Serve'), findsOneWidget);
    expect(find.text('E-mail Poste.io (SMTP)'), findsOneWidget);
    expect(find.textContaining('Falhou'), findsOneWidget);
    expect(find.textContaining('missions-20261008-110000.sqlite3'), findsOneWidget);
    expect(find.text('Bridge ativo há'), findsOneWidget);
  });

  testWidgets('botão faz backup sob demanda', (tester) async {
    var backupCalls = 0;
    http.setClientForTesting(
      MockClient((request) async {
        if (request.url.path == '/ops/backup' && request.method == 'POST') {
          backupCalls++;
          return _json({'ok': true, 'file': 'missions-x.sqlite3', 'size_bytes': 10});
        }
        return _json(_status());
      }),
    );

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Fazer backup agora'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fazer backup agora'));
    await tester.pumpAndSettle();

    expect(backupCalls, 1);
    expect(find.textContaining('Backup gravado'), findsOneWidget);
  });

  testWidgets('mostra erro quando o status falha', (tester) async {
    http.setClientForTesting(
      MockClient((request) async => _json({'detail': 'negado'}, 403)),
    );

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('Status indisponível'), findsOneWidget);
    expect(find.text('Tentar de novo'), findsOneWidget);
  });
}

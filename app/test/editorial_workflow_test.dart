import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as upstream;
import 'package:http/testing.dart';
import 'package:neruds_control_center/app_config.dart';
import 'package:neruds_control_center/app_session.dart';
import 'package:neruds_control_center/bridge_http.dart' as http;
import 'package:neruds_control_center/editorial_page.dart';
import 'package:neruds_control_center/unsaved_work.dart';

void _signIn({
  String username = 'editor.test',
  bool review = false,
  bool publish = false,
}) {
  AppSession.instance.setSession(
    tokenValue: 'test-session-$username',
    usernameValue: username,
    canReviewValue: review,
    canPublishValue: publish,
  );
}

upstream.Response _json(Object value, [int status = 200]) => upstream.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Future<void> _mount(WidgetTester tester, {double width = 1100}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: EditorialPage())),
  );
  await tester.pumpAndSettle();
}

Future<void> _compose(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('news-title')),
    'Chamada de pesquisa',
  );
  await tester.enterText(
    find.byKey(const Key('news-summary')),
    'Resumo conferido.',
  );
  await tester.ensureVisible(find.byKey(const Key('news-body')));
  await tester.enterText(
    find.byKey(const Key('news-body')),
    'Texto com autoria e fonte confirmadas.\nFonte: https://example.org/chamada',
  );
}

Future<void> _next(WidgetTester tester) async {
  final button = find.byKey(const Key('news-next'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

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

  testWidgets(
    'expiração preserva redação e saída explícita remove trabalho da conta',
    (tester) async {
      http.setClientForTesting(
        MockClient((request) async {
          if (request.method == 'POST') {
            return _json({'detail': 'Sessão expirada'}, 401);
          }
          return _json({'items': []});
        }),
      );
      _signIn();
      await _mount(tester, width: 400);
      await _compose(tester);
      expect(tester.takeException(), isNull);
      expect(UnsavedWork.instance.hasChanges, isTrue);
      await _next(tester);
      expect(find.textContaining('Texto com autoria'), findsOneWidget);
      await _next(tester);
      expect(find.text('Destino: Notícias do portal NERUDS'), findsOneWidget);
      await _next(tester);
      expect(AppSession.instance.authenticated, isFalse);

      _signIn();
      await tester.pumpAndSettle();
      expect(find.text('Destino: Notícias do portal NERUDS'), findsOneWidget);
      await tester.ensureVisible(find.text('Voltar ao texto'));
      await tester.tap(find.text('Voltar ao texto'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Voltar ao texto'));
      await tester.tap(find.text('Voltar ao texto'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('news-title')))
            .controller!
            .text,
        'Chamada de pesquisa',
      );
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('news-body')))
            .controller!
            .text,
        contains('Fonte: https://'),
      );
      expect(UnsavedWork.instance.hasChanges, isTrue);

      AppSession.instance.clear();
      _signIn(username: 'another.test');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('news-title')))
            .controller!
            .text,
        isEmpty,
      );
      expect(UnsavedWork.instance.hasChanges, isFalse);
    },
  );

  testWidgets(
    'envio falho mantém texto e só confirmação de salvamento limpa formulário',
    (tester) async {
      int createStatus = 503;
      final sent = <Map<String, dynamic>>[];
      http.setClientForTesting(
        MockClient((request) async {
          if (request.method == 'POST') {
            sent.add(
              Map<String, dynamic>.from(jsonDecode(request.body) as Map),
            );
            if (createStatus == 503) {
              return _json({
                'detail': 'Portal temporariamente indisponível',
              }, 503);
            }
            return _json({
              'id': 123,
              'published': false,
              'edit_url': 'https://portal.example.test/node/123/edit',
              'public_url': 'https://portal.example.test/node/123',
            }, 201);
          }
          return _json({'items': []});
        }),
      );
      _signIn();
      await _mount(tester);
      await _compose(tester);
      await _next(tester);
      await _next(tester);
      await _next(tester);
      expect(sent, hasLength(1));
      expect(sent.single['body'], contains('Texto com autoria'));
      expect(UnsavedWork.instance.hasChanges, isTrue);
      expect(find.text('Destino: Notícias do portal NERUDS'), findsOneWidget);

      createStatus = 201;
      await _next(tester);
      expect(sent, hasLength(2));
      expect(sent[1], equals(sent[0]));
      expect(find.text('Rascunho salvo'), findsOneWidget);
      expect(UnsavedWork.instance.hasChanges, isFalse);
      await tester.tap(find.text('Redigir notícia'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('news-title')))
            .controller!
            .text,
        isEmpty,
      );
    },
  );

  testWidgets('fila expõe texto e ações seguem permissão e publicação real', (
    tester,
  ) async {
    var status = 'pending';
    http.setClientForTesting(
      MockClient(
        (request) async => _json({
          'items': [
            {
              'nid': 77,
              'title': 'Projeto com fonte conferida',
              'summary': 'Resumo para revisão.',
              'body': 'Texto completo que a equipe precisa conferir.',
              'status': status,
              'published': status == 'published',
              'is_owner': false,
              'edit_url': 'https://portal.example.test/node/77/edit',
              'public_url': 'https://portal.example.test/projeto',
              'review': {'author': 'author.test', 'review_status': 'pending'},
            },
          ],
        }),
      ),
    );
    _signIn();
    await _mount(tester, width: 400);
    await tester.tap(find.text('Revisão e publicação').first);
    await tester.pumpAndSettle();
    expect(
      find.text('Texto completo que a equipe precisa conferir.'),
      findsOneWidget,
    );
    expect(find.text('Editar a ficha existente'), findsOneWidget);
    expect(find.text('Aprovar revisão'), findsNothing);
    expect(find.text('Publicar'), findsNothing);

    _signIn(review: true, publish: true);
    await tester.pumpAndSettle();
    expect(find.text('Aprovar revisão'), findsOneWidget);
    expect(find.text('Publicar'), findsNothing);

    status = 'published';
    _signIn(review: true, publish: true);
    await tester.pumpAndSettle();
    expect(find.text('Conferir página pública'), findsOneWidget);
    expect(find.text('Aprovar revisão'), findsNothing);
    expect(find.text('Solicitar ajustes'), findsNothing);
    expect(find.text('Publicar'), findsNothing);
  });

  testWidgets('aprovação apresenta corpo e exige orientação para devolver', (
    tester,
  ) async {
    final decisions = <Map<String, dynamic>>[];
    http.setClientForTesting(
      MockClient((request) async {
        if (request.method == 'PATCH') {
          decisions.add(
            Map<String, dynamic>.from(jsonDecode(request.body) as Map),
          );
          return _json({'ok': true});
        }
        return _json({
          'items': [
            {
              'nid': 77,
              'title': 'Notícia em revisão',
              'body': 'Conteúdo que deve ser lido antes da decisão.',
              'status': 'pending',
              'is_owner': false,
              'review': {'author': 'author.test', 'review_status': 'pending'},
            },
          ],
        });
      }),
    );
    _signIn(review: true);
    await _mount(tester);
    await tester.tap(find.text('Revisão e publicação').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Solicitar ajustes'));
    await tester.tap(find.text('Solicitar ajustes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Registrar ajustes'));
    await tester.pumpAndSettle();
    expect(decisions, isEmpty);
    expect(
      find.text('Indique uma próxima ação para quem escreveu.'),
      findsOneWidget,
    );
    await tester.enterText(
      find.byType(TextField).last,
      'Confirmar a data na fonte.',
    );
    await tester.tap(find.text('Registrar ajustes'));
    await tester.pumpAndSettle();
    expect(decisions.single, {
      'status': 'changes_requested',
      'note': 'Confirmar a data na fonte.',
    });
  });
}

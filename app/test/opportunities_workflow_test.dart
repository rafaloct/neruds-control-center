import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as upstream;
import 'package:http/testing.dart';
import 'package:neruds_control_center/app_config.dart';
import 'package:neruds_control_center/app_session.dart';
import 'package:neruds_control_center/bridge_http.dart' as http;
import 'package:neruds_control_center/opportunities_page.dart';
import 'package:neruds_control_center/unsaved_work.dart';
import 'package:neruds_control_center/workflow_widgets.dart';

upstream.Response _json(Object value, [int status = 200]) => upstream.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> _item({bool linked = false}) => {
  'id': 9,
  'title': 'Chamada para pesquisa e extensão',
  'summary': 'Chamada com prazo confirmado na fonte.',
  'url': 'https://example.org/chamada',
  'source_name': 'Instituição de pesquisa',
  'category': 'Edital',
  'status': linked ? 'aprovado_pauta' : 'verificado',
  'decision_note': 'Fonte consultada.',
  'deadline_at': '2027-12-31',
  'fit_tags': ['pesquisa'],
  'is_duplicate': false,
  'events': [],
  if (linked) 'drupal_draft_id': 321,
  if (linked) 'edit_url': 'https://portal.example.test/node/321/edit',
  if (linked) 'public_url': 'https://portal.example.test/node/321',
};

Future<void> _mount(
  WidgetTester tester,
  Widget child, {
  double width = 1100,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text));
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    AppSession.instance.clear();
    AppSession.instance.setSession(
      tokenValue: 'test-session',
      usernameValue: 'curator.test',
      canReviewValue: true,
    );
    AppConfig.configureForTesting(bridgeUrl: 'https://bridge.example.test');
  });
  tearDown(() {
    AppSession.instance.clear();
    AppConfig.configureForTesting();
    http.resetClientForTesting();
  });

  testWidgets('vínculo existente impede outra criação e regressão de estado', (
    tester,
  ) async {
    var mutations = 0;
    http.setClientForTesting(
      MockClient((request) async {
        if (request.method != 'GET') mutations++;
        return _json(_item(linked: true));
      }),
    );
    await _mount(tester, const OpportunityDialog(itemId: 9));
    expect(find.text('Esta pauta já tem uma ficha no portal'), findsOneWidget);
    expect(find.text('Abrir ficha para revisão'), findsOneWidget);
    expect(find.text('Preparar rascunho de notícia'), findsNothing);
    expect(find.text('Salvar em triagem'), findsNothing);
    expect(find.text('Aprovar como pauta'), findsNothing);
    expect(find.text('Descartar pauta'), findsNothing);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('op-deadline')))
          .enabled,
      isFalse,
    );
    expect(mutations, 0);
  });

  testWidgets(
    'arquivar pauta vinculada preserva nota e ficha sem liberar recriação',
    (tester) async {
      AppSession.instance.setSession(
        tokenValue: 'test-session',
        usernameValue: 'curator.test',
        canReviewValue: false,
      );
      var current = _item(linked: true);
      final decisions = <Map<String, dynamic>>[];
      var creates = 0;
      http.setClientForTesting(
        MockClient((request) async {
          if (request.method == 'POST') creates++;
          if (request.method == 'PATCH') {
            expect(request.url.path, '/opportunities/items/9/decision');
            final decision = Map<String, dynamic>.from(
              jsonDecode(request.body) as Map,
            );
            decisions.add(decision);
            current = {...current, 'status': decision['status']};
          }
          return _json(current);
        }),
      );
      await _mount(tester, const OpportunityDialog(itemId: 9), width: 400);
      await tester.scrollUntilVisible(
        find.text('Arquivar oportunidade'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await _tap(tester, 'Arquivar oportunidade');
      expect(decisions.single, {
        'status': 'arquivado',
        'note': 'Fonte consultada.',
      });
      expect(creates, 0);
      expect(find.text('Arquivar oportunidade'), findsNothing);
      expect(find.text('Preparar rascunho de notícia'), findsNothing);
      expect(find.text('Salvar em triagem'), findsNothing);
      expect(find.text('Aprovar como pauta'), findsNothing);
      expect(find.text('Descartar pauta'), findsNothing);

      await tester.scrollUntilVisible(
        find.text('Abrir ficha para revisão'),
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      final links = tester.widgetList<PortalLinkButton>(
        find.byType(PortalLinkButton),
      );
      expect(
        links.any(
          (link) =>
              link.editing &&
              link.url == 'https://portal.example.test/node/321/edit',
        ),
        isTrue,
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('op-note')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      final note = tester.widget<TextFormField>(
        find.byKey(const Key('op-note')),
      );
      expect(note.controller!.text, 'Fonte consultada.');
      expect(note.enabled, isFalse);
      expect(UnsavedWork.instance.hasChanges, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('falha ao arquivar mantém vínculo e permite repetir só arquivo', (
    tester,
  ) async {
    var decisions = 0;
    var creates = 0;
    http.setClientForTesting(
      MockClient((request) async {
        if (request.method == 'POST') creates++;
        if (request.method == 'PATCH') {
          decisions++;
          expect(jsonDecode(request.body)['status'], 'arquivado');
          return _json({'detail': 'Serviço indisponível'}, 503);
        }
        return _json(_item(linked: true));
      }),
    );
    await _mount(tester, const OpportunityDialog(itemId: 9));
    await _tap(tester, 'Arquivar oportunidade');
    expect(decisions, 1);
    expect(creates, 0);
    expect(find.text('Arquivar oportunidade'), findsOneWidget);
    expect(find.text('Abrir ficha para revisão'), findsOneWidget);
    expect(find.text('Preparar rascunho de notícia'), findsNothing);
    expect(find.text('Salvar em triagem'), findsNothing);
    expect(
      find.textContaining('As alterações foram mantidas.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'conflito de rascunho conduz ao vínculo existente sem repetir POST',
    (tester) async {
      const detail =
          'Esta oportunidade já possui um rascunho Drupal. '
          'Abra o registro existente no portal.';
      var linked = false;
      var creates = 0;
      http.setClientForTesting(
        MockClient((request) async {
          if (request.method == 'POST') {
            creates++;
            linked = true;
            return _json({'detail': detail}, 409);
          }
          return _json({..._item(linked: linked), 'status': 'aprovado_pauta'});
        }),
      );
      await _mount(tester, const OpportunityDialog(itemId: 9));
      await _tap(tester, 'Preparar rascunho de notícia');
      await _tap(tester, 'Criar rascunho vinculado');
      expect(creates, 1);
      expect(find.text(detail), findsOneWidget);
      expect(find.text('Abrir ficha para revisão'), findsOneWidget);
      expect(find.text('Preparar rascunho de notícia'), findsNothing);
      expect(find.text('Salvar em triagem'), findsNothing);
      expect(find.text('Arquivar oportunidade'), findsOneWidget);
    },
  );

  testWidgets(
    'limpar prazo envia remoção explícita e só save limpa alterações',
    (tester) async {
      var current = _item();
      final decisions = <Map<String, dynamic>>[];
      http.setClientForTesting(
        MockClient((request) async {
          if (request.method == 'PATCH') {
            final value = Map<String, dynamic>.from(
              jsonDecode(request.body) as Map,
            );
            decisions.add(value);
            current = {
              ...current,
              'status': value['status'],
              'decision_note': value['note'],
              'deadline_at': value['deadline_at'] == ''
                  ? null
                  : value['deadline_at'],
              'fit_tags': value['fit_tags'],
            };
            return _json(current);
          }
          return _json(current);
        }),
      );
      await _mount(tester, const OpportunityDialog(itemId: 9));
      await tester.ensureVisible(find.byKey(const Key('op-deadline')));
      await tester.enterText(find.byKey(const Key('op-deadline')), '');
      await tester.ensureVisible(find.byKey(const Key('op-note')));
      await tester.enterText(
        find.byKey(const Key('op-note')),
        'Fonte retirou o prazo anterior.',
      );
      expect(UnsavedWork.instance.hasChanges, isTrue);
      await _tap(tester, 'Salvar em triagem');
      expect(decisions.single['deadline_at'], '');
      expect(decisions.single['note'], 'Fonte retirou o prazo anterior.');
      expect(UnsavedWork.instance.hasChanges, isFalse);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('op-deadline')))
            .controller!
            .text,
        isEmpty,
      );
    },
  );

  testWidgets(
    'falha da curadoria preserva preenchimento para corrigir ou repetir',
    (tester) async {
      http.setClientForTesting(
        MockClient(
          (request) async => request.method == 'PATCH'
              ? _json({'detail': 'Não foi possível salvar agora.'}, 503)
              : _json(_item()),
        ),
      );
      await _mount(tester, const OpportunityDialog(itemId: 9));
      await tester.ensureVisible(find.byKey(const Key('op-note')));
      await tester.enterText(
        find.byKey(const Key('op-note')),
        'Próxima ação confirmada.',
      );
      await _tap(tester, 'Salvar em triagem');
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('op-note')))
            .controller!
            .text,
        'Próxima ação confirmada.',
      );
      expect(UnsavedWork.instance.hasChanges, isTrue);
      expect(
        find.textContaining('As alterações foram mantidas.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('cabeçalho de oportunidades cabe em tela estreita sem overflow', (
    tester,
  ) async {
    http.setClientForTesting(
      MockClient((request) async {
        if (request.url.path.endsWith('/sources')) return _json([]);
        if (request.url.path.endsWith('/dashboard')) {
          return _json({
            'by_status': {},
            'active_sources': 0,
            'total_items': 0,
          });
        }
        return _json({'items': []});
      }),
    );
    await _mount(tester, const OpportunitiesPage(), width: 390);
    expect(find.text('Registrar oportunidade'), findsOneWidget);
    expect(find.text('Adicionar fonte'), findsOneWidget);
    expect(find.text('Buscar novidades'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('captura manual não fecha nem perde campos se o portal falhar', (
    tester,
  ) async {
    var mutations = 0;
    http.setClientForTesting(
      MockClient((request) async {
        mutations++;
        return _json({'detail': 'Serviço indisponível, tente novamente.'}, 503);
      }),
    );
    await _mount(tester, const ManualOpportunityDialog());
    final title = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'Título da oportunidade',
    );
    final url = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'Link da fonte oficial',
    );
    await tester.enterText(title, 'Vaga de estágio em pesquisa');
    await tester.enterText(url, 'https://example.org/vaga');
    await _tap(tester, 'Enviar para triagem');
    expect(mutations, 1);
    expect(
      tester.widget<TextField>(title).controller!.text,
      'Vaga de estágio em pesquisa',
    );
    expect(
      tester.widget<TextField>(url).controller!.text,
      'https://example.org/vaga',
    );
    expect(
      find.textContaining('Seu preenchimento foi mantido.'),
      findsOneWidget,
    );
    expect(UnsavedWork.instance.hasChanges, isTrue);
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as transport;
import 'package:http/testing.dart';
import 'package:neruds_control_center/app_session.dart';
import 'package:neruds_control_center/app_config.dart';
import 'package:neruds_control_center/bridge_http.dart' as bridge;
import 'package:neruds_control_center/mission_page.dart';
import 'package:neruds_control_center/unsaved_work.dart';

const workflow = [
  'Triagem',
  'Em pesquisa',
  'Evidência registrada',
  'Revisão cruzada',
  'Aguardando validação',
  'Conferência pública',
  'Concluído',
  'Bloqueado',
];

Map<String, dynamic> taskFixture() => {
  'id': 41,
  'mission_id': 7,
  'title': 'Conferir projeto territorial',
  'content_type': 'Projeto',
  'suggested_area': 'Pesquisa e extensão',
  'priority': 'P1',
  'current_stage': 'Em pesquisa',
  'primary_owner': 'extensionista.1',
  'cross_reviewer': 'extensionista.2',
  'internal_deadline': '',
  'consultation_date': '',
  'public_check_ok': false,
  'public_url': 'https://portal.example.org/projetos/territorio',
  'edit_url': 'https://portal.example.org/node/41/edit',
  'source_record_id': '41',
  'spreadsheet_row': 12,
  'gaps': 'Confirmar os resultados recentes.',
  'action': 'Confrontar a página com o relatório validado.',
  'where_to_search': 'Relatório institucional.',
  'sources': 'Acervo do núcleo.',
  'suggested_query': 'Projeto territorial resultados',
  'evidence': '',
  'confirmed_source': '',
  'observations': '',
  'checklists': {
    'pesquisa': [
      {
        'item_order': 1,
        'item': 'Identificar fonte oficial',
        'criterion': 'Conferir a origem.',
        'completed': false,
      },
    ],
    'publicacao': [],
  },
  'evidence_files': <Map<String, dynamic>>[],
  'events': <Map<String, dynamic>>[],
};

transport.Response jsonResponse(Object value, [int status = 200]) =>
    transport.Response(
      jsonEncode(value),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

void signIn() {
  AppConfig.configureForTesting(
    bridgeUrl: 'https://bridge.example.org',
    portalUrl: 'https://portal.example.org',
  );
  AppSession.instance.clear();
  AppSession.instance.setSession(
    tokenValue: 'fixture-token',
    usernameValue: 'extensionista.1',
    rolesValue: const ['extensionista'],
  );
}

void wideSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> reveal(WidgetTester tester, Key key) async {
  final target = find.byKey(key);
  for (var attempt = 0; attempt < 14 && target.evaluate().isEmpty; attempt++) {
    await tester.drag(
      find.byKey(const PageStorageKey('mission-task-form')),
      const Offset(0, -350),
    );
    await tester.pumpAndSettle();
  }
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<void> openTask(
  WidgetTester tester, {
  MissionEvidencePicker? picker,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => FilledButton(
            key: const ValueKey('open-task'),
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => MissionTaskDialog(
                taskId: 41,
                workflow: workflow,
                evidencePicker: picker,
              ),
            ),
            child: const Text('Abrir tarefa'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-task')));
  await tester.pumpAndSettle();
}

Map<String, dynamic> workItemFixture() => {
  'id': 71,
  'title': 'Organizar fontes da atividade',
  'section': 'diario_extensao',
  'responsible': 'extensionista.1',
  'spreadsheet_row': 3,
  'completed': false,
  'status': 'Em andamento',
  'evidence': '',
  'note': '',
  'payload': <String, dynamic>{},
  'events': <Map<String, dynamic>>[],
};

String detailPath(bool workItem) =>
    workItem ? '/mission-work-items/71' : '/mission-tasks/41';
Key saveKey(bool workItem) =>
    ValueKey(workItem ? 'mission-work-item-save' : 'mission-task-save');
Key fieldKey(bool workItem) =>
    ValueKey(workItem ? 'mission-work-item-note' : 'mission-evidence-text');
Key closeKey(bool workItem) =>
    ValueKey(workItem ? 'mission-work-item-close' : 'mission-task-close');
Finder dialogFinder(bool workItem) =>
    find.byType(workItem ? MissionWorkItemDialog : MissionTaskDialog);

Future<void> openSessionDialog(
  WidgetTester tester,
  bool workItem, {
  bool settle = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => FilledButton(
            key: const ValueKey('open-session-dialog'),
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => workItem
                  ? const MissionWorkItemDialog(workItemId: 71)
                  : const MissionTaskDialog(taskId: 41),
            ),
            child: const Text('Abrir registro'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-session-dialog')));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<TextEditingController> enterSessionDraft(
  WidgetTester tester,
  bool workItem,
) async {
  if (!workItem) {
    await tester.tap(find.byKey(const ValueKey('mission-task-step-1')));
    await tester.pumpAndSettle();
    await reveal(tester, fieldKey(false));
  } else {
    await tester.ensureVisible(find.byKey(fieldKey(true)));
  }
  await tester.enterText(
    find.byKey(fieldKey(workItem)),
    'Texto reservado da primeira pessoa.',
  );
  await tester.pumpAndSettle();
  return tester.widget<TextField>(find.byKey(fieldKey(workItem))).controller!;
}

Future<void> signInWithinDialog(
  WidgetTester tester, {
  String username = 'extensionista.1',
  bool discard = false,
}) async {
  await tester.tap(find.text('Entrar com minha conta'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Usuário'),
    username,
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Senha'),
    'synthetic-only',
  );
  await tester.tap(find.widgetWithText(FilledButton, 'Entrar'));
  await tester.pumpAndSettle();
  if (discard) {
    await tester.tap(find.text('Descartar e continuar'));
    await tester.pumpAndSettle();
  }
}

void main() {
  setUp(signIn);
  tearDown(() {
    bridge.resetClientForTesting();
    AppConfig.configureForTesting();
    AppSession.instance.clear();
  });

  testWidgets('carrega missão real e filtra por responsável e tipo', (
    tester,
  ) async {
    wideSurface(tester);
    final requests = <Uri>[];
    bridge.setClientForTesting(
      MockClient((request) async {
        requests.add(request.url);
        switch (request.url.path) {
          case '/missions':
            return jsonResponse([
              {
                'id': 7,
                'title': 'Inventário institucional',
                'workflow': workflow,
              },
            ]);
          case '/missions/7/dashboard':
            return jsonResponse({
              'id': 7,
              'title': 'Inventário institucional',
              'workflow': workflow,
              'total_tasks': 1,
              'overall_total': 1,
              'overall_concluded': 0,
              'overdue': 0,
              'upcoming': 0,
              'by_owner': {'extensionista.1': 1, 'extensionista.2': 0},
              'by_type': {'Projeto': 1, 'Publicação': 0},
            });
          case '/missions/7/tasks':
            return jsonResponse({
              'total': 1,
              'items': [taskFixture()],
            });
          case '/missions/7/work-items':
            return jsonResponse({'items': []});
          case '/missions/7/saved-filters':
            return jsonResponse([]);
          case '/missions/7/automation':
            return jsonResponse({
              'suggested_tasks': [],
              'missing_evidence': {'count': 0},
              'possible_duplicates': {'count': 0},
              'url_check': {'broken': 0},
            });
          default:
            throw StateError('Rota inesperada: ${request.url.path}');
        }
      }),
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: MissionPage())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Inventário institucional'), findsOneWidget);
    expect(requests.any((url) => url.path.contains('/missions/1/')), isFalse);
    expect(find.text('1 de 1 registros nesta seleção'), findsOneWidget);
    expect(find.text('Área: Pesquisa e extensão'), findsOneWidget);

    final owner = find.byKey(const ValueKey('mission-owner-null'));
    await tester.ensureVisible(owner);
    await tester.tap(owner);
    await tester.pumpAndSettle();
    await tester.tap(find.text('extensionista.1').last);
    await tester.pumpAndSettle();
    expect(
      requests
          .lastWhere((url) => url.path.endsWith('/tasks'))
          .queryParameters['owner'],
      'extensionista.1',
    );

    final type = find.byKey(const ValueKey('mission-content-type-null'));
    await tester.ensureVisible(type);
    await tester.tap(type);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Projeto').last);
    await tester.pumpAndSettle();
    final taskQuery = requests.lastWhere((url) => url.path.endsWith('/tasks'));
    expect(taskQuery.queryParameters['content_type'], 'Projeto');
    expect(taskQuery.queryParameters['owner'], 'extensionista.1');
    expect(taskQuery.queryParameters['limit'], '50');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'checklist e upload preservam texto; salvar envia só alterações',
    (tester) async {
      wideSurface(tester);
      final task = taskFixture();
      Map<String, dynamic>? savedPatch;
      var uploads = 0;
      bridge.setClientForTesting(
        MockClient((request) async {
          if (request.url.path == '/mission-tasks/41' &&
              request.method == 'GET') {
            return jsonResponse(task);
          }
          if (request.url.path == '/mission-tasks/41/checklists/pesquisa/1') {
            final check = (task['checklists'] as Map)['pesquisa'] as List;
            (check.first as Map)['completed'] = true;
            return jsonResponse(task);
          }
          if (request.url.path == '/mission-tasks/41/evidence-files') {
            uploads++;
            final file = {
              'id': 9,
              'filename': 'evidencia.txt',
              'uploaded_by': 'extensionista.1',
              'size_bytes': 3,
              'sha256': 'a' * 64,
            };
            (task['evidence_files'] as List).add(file);
            return jsonResponse(file, 201);
          }
          if (request.url.path == '/mission-tasks/41' &&
              request.method == 'PATCH') {
            savedPatch = Map<String, dynamic>.from(jsonDecode(request.body));
            task.addAll(savedPatch!);
            return jsonResponse(task);
          }
          throw StateError(
            'Rota inesperada: ${request.method} ${request.url.path}',
          );
        }),
      );
      await openTask(
        tester,
        picker: () async => MissionEvidenceSelection(
          name: 'evidencia.txt',
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('mission-task-step-1')));
      await tester.pumpAndSettle();
      await reveal(tester, const ValueKey('mission-evidence-text'));
      final evidence = tester
          .widget<TextField>(
            find.byKey(const ValueKey('mission-evidence-text')),
          )
          .controller!;
      await tester.enterText(
        find.byKey(const ValueKey('mission-evidence-text')),
        'O relatório confirma três resultados.',
      );
      await reveal(tester, const ValueKey('mission-proposal'));
      final proposal = tester
          .widget<TextField>(find.byKey(const ValueKey('mission-proposal')))
          .controller!;
      await tester.enterText(
        find.byKey(const ValueKey('mission-proposal')),
        'Atualizar o resumo após revisão.',
      );
      expect(UnsavedWork.instance.hasChanges, isTrue);

      await reveal(tester, const ValueKey('mission-check-pesquisa-1'));
      await tester.tap(find.byKey(const ValueKey('mission-check-pesquisa-1')));
      await tester.pumpAndSettle();
      expect(evidence.text, 'O relatório confirma três resultados.');
      expect(proposal.text, 'Atualizar o resumo após revisão.');

      await tester.drag(
        find.byKey(const PageStorageKey('mission-task-form')),
        const Offset(0, 450),
      );
      await tester.pumpAndSettle();
      await reveal(tester, const ValueKey('mission-upload-evidence'));
      // Await the wired button action outside fakeAsync so multipart streams
      // finish before assertions; no native picker or live HTTP is involved.
      final uploadAction = tester
          .widget<TextButton>(
            find.byKey(const ValueKey('mission-upload-evidence')),
          )
          .onPressed!;
      await tester.runAsync(() => (uploadAction as Future<void> Function())());
      await tester.pumpAndSettle();
      expect(uploads, 1);
      expect(evidence.text, 'O relatório confirma três resultados.');
      expect(proposal.text, 'Atualizar o resumo após revisão.');
      expect(UnsavedWork.instance.hasChanges, isTrue);

      await tester.tap(find.byKey(const ValueKey('mission-task-save')));
      await tester.pumpAndSettle();
      expect(savedPatch, {
        'evidence': 'O relatório confirma três resultados.',
        'observations': 'Atualizar o resumo após revisão.',
      });
      expect(UnsavedWork.instance.hasChanges, isFalse);
      expect(
        find.text(
          'Registro da tarefa salvo. O conteúdo do portal não foi alterado.',
        ),
        findsAtLeastNWidgets(1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'saída pede descarte e permite continuar sem perder a evidência',
    (tester) async {
      wideSurface(tester);
      bridge.setClientForTesting(
        MockClient((_) async => jsonResponse(taskFixture())),
      );
      await openTask(tester);
      await tester.tap(find.byKey(const ValueKey('mission-task-step-1')));
      await tester.pumpAndSettle();
      await reveal(tester, const ValueKey('mission-evidence-text'));
      final controller = tester
          .widget<TextField>(
            find.byKey(const ValueKey('mission-evidence-text')),
          )
          .controller!;
      await tester.enterText(
        find.byKey(const ValueKey('mission-evidence-text')),
        'Pesquisa ainda em redação.',
      );
      await tester.tap(find.byKey(const ValueKey('mission-task-close')));
      await tester.pumpAndSettle();
      expect(find.text('Você tem alterações não salvas'), findsOneWidget);
      await tester.tap(find.text('Continuar preenchendo'));
      await tester.pumpAndSettle();
      expect(controller.text, 'Pesquisa ainda em redação.');
      expect(UnsavedWork.instance.hasChanges, isTrue);
      await tester.tap(find.byKey(const ValueKey('mission-task-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mission-confirm-discard')));
      await tester.pumpAndSettle();
      expect(find.byType(MissionTaskDialog), findsNothing);
      expect(UnsavedWork.instance.hasChanges, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('falha de consulta encerra carregamento e oferece retomada', (
    tester,
  ) async {
    wideSurface(tester);
    bridge.setClientForTesting(
      MockClient(
        (_) async =>
            jsonResponse({'detail': 'Portal indisponível para consulta.'}, 503),
      ),
    );
    await openTask(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Tentar novamente'), findsOneWidget);
    expect(find.byKey(const ValueKey('mission-task-save')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('mission-task-save')))
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final workItem in [false, true]) {
    final label = workItem ? 'atividade' : 'tarefa';

    testWidgets('$label: 401 permite renovar a mesma conta sem perder texto', (
      tester,
    ) async {
      wideSurface(tester);
      final data = workItem ? workItemFixture() : taskFixture();
      final changes = <Map<String, dynamic>>[];
      final tokens = <String?>[];
      bridge.setClientForTesting(
        MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return jsonResponse({
              'token': 'renewed-token',
              'username': 'extensionista.1',
              'roles': ['extensionista'],
            });
          }
          expect(request.url.path, detailPath(workItem));
          if (request.method == 'PATCH') {
            changes.add(Map<String, dynamic>.from(jsonDecode(request.body)));
            tokens.add(request.headers['Authorization']);
            if (changes.length == 1) {
              return jsonResponse({'detail': 'Sessão expirada'}, 401);
            }
            data.addAll(changes.last);
          }
          return jsonResponse(data);
        }),
      );
      await openSessionDialog(tester, workItem);
      final controller = await enterSessionDraft(tester, workItem);
      await tester.tap(find.byKey(saveKey(workItem)));
      await tester.pumpAndSettle();
      expect(AppSession.instance.authenticated, isFalse);
      expect(controller.text, 'Texto reservado da primeira pessoa.');
      expect(UnsavedWork.instance.hasChanges, isTrue);
      expect(
        find.text('Entre para retomar este preenchimento'),
        findsOneWidget,
      );

      await signInWithinDialog(tester);
      expect(dialogFinder(workItem), findsOneWidget);
      expect(find.text('Entrar no NERUDS'), findsNothing);
      expect(controller.text, 'Texto reservado da primeira pessoa.');
      expect(UnsavedWork.instance.hasChanges, isTrue);
      await tester.tap(find.byKey(saveKey(workItem)));
      await tester.pumpAndSettle();
      expect(changes, hasLength(2));
      expect(changes.last, changes.first);
      expect(tokens, ['Bearer fixture-token', 'Bearer renewed-token']);
      expect(UnsavedWork.instance.hasChanges, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      '$label: outra conta encerra a ficha sem fechar o login errado',
      (tester) async {
        wideSurface(tester);
        var writes = 0;
        bridge.setClientForTesting(
          MockClient((request) async {
            if (request.url.path == '/auth/login') {
              return jsonResponse({
                'token': 'colleague-token',
                'username': 'colleague.test',
                'roles': ['extensionista'],
              });
            }
            if (request.method == 'PATCH') {
              writes++;
              return jsonResponse({'detail': 'Sessão expirada'}, 401);
            }
            return jsonResponse(workItem ? workItemFixture() : taskFixture());
          }),
        );
        await openSessionDialog(tester, workItem);
        final controller = await enterSessionDraft(tester, workItem);
        await tester.tap(find.byKey(saveKey(workItem)));
        await tester.pumpAndSettle();
        await signInWithinDialog(
          tester,
          username: 'colleague.test',
          discard: true,
        );
        expect(AppSession.instance.username, 'colleague.test');
        expect(find.text('Entrar no NERUDS'), findsNothing);
        expect(dialogFinder(workItem), findsOneWidget);
        expect(
          find.byKey(const ValueKey('mission-session-ended')),
          findsOneWidget,
        );
        expect(controller.text, isEmpty);
        expect(find.byKey(fieldKey(workItem)), findsNothing);
        expect(UnsavedWork.instance.hasChanges, isFalse);
        expect(
          tester.widget<FilledButton>(find.byKey(saveKey(workItem))).onPressed,
          isNull,
        );
        expect(writes, 1);

        await tester.tap(find.byKey(closeKey(workItem)));
        await tester.pumpAndSettle();
        expect(dialogFinder(workItem), findsNothing);
        expect(
          find.byKey(const ValueKey('open-session-dialog')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    for (final scenario in ['load-other', 'save-other', 'save-renewed']) {
      testWidgets('$label: ignora resposta atrasada em $scenario', (
        tester,
      ) async {
        wideSurface(tester);
        final pending = Completer<transport.Response>();
        final loading = scenario == 'load-other';
        final data = workItem ? workItemFixture() : taskFixture();
        bridge.setClientForTesting(
          MockClient((request) async {
            if (loading || request.method == 'PATCH') return pending.future;
            return jsonResponse(data);
          }),
        );
        await openSessionDialog(tester, workItem, settle: !loading);
        TextEditingController? controller;
        if (!loading) {
          controller = await enterSessionDraft(tester, workItem);
          await tester.tap(find.byKey(saveKey(workItem)));
          await tester.pump();
        }
        final samePerson = scenario == 'save-renewed';
        AppSession.instance.expire();
        AppSession.instance.setSession(
          tokenValue: 'next-session-token',
          usernameValue: samePerson ? 'extensionista.1' : 'colleague.test',
          rolesValue: const ['extensionista'],
        );
        await tester.pump();
        pending.complete(
          jsonResponse({
            ...data,
            'title': 'Resposta privada antiga',
            'evidence': 'Resposta privada antiga',
            'note': 'Resposta privada antiga',
          }),
        );
        await tester.pumpAndSettle();

        expect(find.text('Resposta privada antiga'), findsNothing);
        expect(dialogFinder(workItem), findsOneWidget);
        if (samePerson) {
          expect(controller!.text, 'Texto reservado da primeira pessoa.');
          expect(UnsavedWork.instance.hasChanges, isTrue);
          expect(
            tester
                .widget<FilledButton>(find.byKey(saveKey(workItem)))
                .onPressed,
            isNotNull,
          );
        } else {
          expect(
            find.byKey(const ValueKey('mission-session-ended')),
            findsOneWidget,
          );
          if (controller != null) expect(controller.text, isEmpty);
          expect(UnsavedWork.instance.hasChanges, isFalse);
          expect(
            tester
                .widget<FilledButton>(find.byKey(saveKey(workItem)))
                .onPressed,
            isNull,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets(
    'troca de conta durante seletor não envia arquivo da sessão anterior',
    (tester) async {
      wideSurface(tester);
      final selection = Completer<MissionEvidenceSelection?>();
      var uploads = 0;
      bridge.setClientForTesting(
        MockClient((request) async {
          if (request.method == 'POST') uploads++;
          return jsonResponse(taskFixture());
        }),
      );
      await openTask(tester, picker: () => selection.future);
      final controller = await enterSessionDraft(tester, false);
      await reveal(tester, const ValueKey('mission-upload-evidence'));
      await tester.tap(find.byKey(const ValueKey('mission-upload-evidence')));
      await tester.pump();
      AppSession.instance.setSession(
        tokenValue: 'colleague-token',
        usernameValue: 'colleague.test',
      );
      selection.complete(
        MissionEvidenceSelection(
          name: 'private-fixture.txt',
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
      );
      await tester.pumpAndSettle();
      expect(uploads, 0);
      expect(controller.text, isEmpty);
      expect(
        find.byKey(const ValueKey('mission-session-ended')),
        findsOneWidget,
      );
      expect(UnsavedWork.instance.hasChanges, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

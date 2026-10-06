import 'package:flutter_test/flutter_test.dart';
import 'package:neruds_control_center/main.dart';

void main() {
  testWidgets('abre painel e fluxo editorial', (tester) async {
    await tester.pumpWidget(const NerudsControlApp());
    await tester.pump();

    expect(find.text('NERUDS Control Center'), findsOneWidget);
    expect(find.text('Visão geral'), findsOneWidget);

    await tester.tap(find.text('Conteúdo'));
    await tester.pumpAndSettle();

    expect(find.text('Conteúdo do portal'), findsOneWidget);
    expect(find.text('Usuário do portal *'), findsOneWidget);
    expect(find.text('Senha *'), findsOneWidget);
    expect(find.text('Entrar'), findsOneWidget);
  });

  testWidgets('restringe administração sem sessão autorizada', (tester) async {
    await tester.pumpWidget(const NerudsControlApp());
    await tester.pump();

    await tester.tap(find.text('Administração'));
    await tester.pumpAndSettle();

    expect(find.text('Acesso restrito'), findsOneWidget);
    expect(
      find.text('Entre no portal para acessar a Administração.'),
      findsOneWidget,
    );
  });

  testWidgets('expõe missão e oportunidades com autenticação obrigatória', (
    tester,
  ) async {
    await tester.pumpWidget(const NerudsControlApp());
    await tester.pump();

    await tester.tap(find.text('Missão'));
    await tester.pumpAndSettle();
    expect(find.text('Missão do estagiário'), findsOneWidget);
    expect(find.text('Entre no portal para iniciar'), findsOneWidget);

    await tester.tap(find.text('Oportunidades'));
    await tester.pumpAndSettle();
    expect(find.text('Oportunidades'), findsAtLeastNWidgets(1));
    expect(find.text('Entre no portal para fazer curadoria'), findsOneWidget);
  });
}

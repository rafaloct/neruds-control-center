import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neruds_control_center/manage_rich_text.dart';

void main() {
  testWidgets('toolbar do ManageRichTextField tem botões habilitados',
      (tester) async {
    final controller = QuillController.basic();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          FlutterQuillLocalizations.delegate,
        ],
        
        home: Scaffold(
          body: ManageRichTextField(
            label: 'Descrição',
            controller: controller,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final buttons = tester
        .widgetList<IconButton>(find.byType(IconButton))
        .toList();
    final enabled = buttons.where((b) => b.onPressed != null).length;
    // Depuração: mostra estado de cada botão
    for (final b in buttons) {
      debugPrint(
        'icon=${(b.icon is Icon ? (b.icon as Icon).icon : b.icon)} '
        'enabled=${b.onPressed != null} tooltip=${b.tooltip}',
      );
    }
    expect(buttons.length, greaterThanOrEqualTo(7));
    expect(enabled, greaterThan(0),
        reason: 'todos os botões da toolbar estão disabled');
  });
}

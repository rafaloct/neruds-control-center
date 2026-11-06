import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill_delta_from_html/flutter_quill_delta_from_html.dart';
import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:vsc_quill_delta_to_html/vsc_quill_delta_to_html.dart';

/// Editor WYSIWYG para campos `longtext` do schema dinâmico.
///
/// Data binding com o Drupal (JSON:API entrega/espera HTML):
/// - entrada: `htmlToDelta()` converte o HTML armazenado no portal para o
///   documento interno do Quill;
/// - saída: `deltaToHtml()` serializa o documento de volta para HTML limpo
///   (negrito, itálico, sublinhado, listas e links — os botões habilitados).
class ManageRichTextField extends StatefulWidget {
  const ManageRichTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
  });

  final QuillController controller;
  final String label;
  final String? hint;

  /// HTML -> Delta (conteúdo existente vindo do portal).
  static Delta htmlToDelta(String html) {
    if (html.trim().isEmpty) return Delta()..insert('\n');
    try {
      return _withoutEmbeds(HtmlToDelta().convert(html));
    } catch (_) {
      // HTML malformado: preserva como texto plano em vez de quebrar o form.
      return Delta()..insert('$html\n');
    }
  }

  /// Substitui embeds (imagens, vídeos) por um marcador de texto — o
  /// editor configurado não tem embed builders e travaria sem isso.
  static Delta _withoutEmbeds(Delta delta) {
    final clean = Delta();
    for (final op in delta.toList()) {
      if (op.key != Operation.insertKey || op.data is String) {
        clean.push(op);
      } else {
        // Embed (imagem/vídeo/anexo) — o editor não tem embed builders.
        clean.insert('[conteúdo incorporado]\n');
      }
    }
    if (clean.isEmpty) clean.insert('\n');
    return clean;
  }

  /// Delta -> HTML (valor a enviar ao bridge no save).
  static String deltaToHtml(QuillController controller) {
    final ops = controller.document.toDelta().toJson();
    if (ops.length == 1 &&
        (ops.first['insert'] as Object? ?? '') == '\n') {
      return '';
    }
    return QuillDeltaToHtmlConverter(ops).convert();
  }

  @override
  State<ManageRichTextField> createState() => _ManageRichTextFieldState();
}

class _ManageRichTextFieldState extends State<ManageRichTextField> {
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderSide =
        BorderSide(color: theme.colorScheme.outlineVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: theme.textTheme.titleSmall),
        if (widget.hint != null) ...[
          const SizedBox(height: 2),
          Text(widget.hint!, style: theme.textTheme.bodySmall),
        ],
        const SizedBox(height: 6),
        // Toolbar em linha única com rolagem horizontal — cabe em telas
        // estreitas sem overflow.
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: .5),
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(8),
            ),
            border: Border(
              left: borderSide,
              right: borderSide,
              top: borderSide,
            ),
          ),
          child: QuillSimpleToolbar(
            controller: widget.controller,
            config: QuillSimpleToolbarConfig(
              // Ícones com cor explícita — o default do tema deixava os
              // botões quase invisíveis sobre surfaceContainerHighest.
              buttonOptions: QuillSimpleToolbarButtonOptions(
                base: QuillToolbarBaseButtonOptions(
                  iconTheme: QuillIconTheme(
                    iconButtonUnselectedData: IconButtonData(
                      color: theme.colorScheme.onSurfaceVariant,
                      disabledColor:
                          theme.colorScheme.onSurface.withValues(alpha: .38),
                    ),
                    iconButtonSelectedData: IconButtonData(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
              multiRowsDisplay: false,
              toolbarSectionSpacing: 2,
              toolbarRunSpacing: 0,
              showBoldButton: true,
              showItalicButton: true,
              showUnderLineButton: true,
              showListNumbers: true,
              showListBullets: true,
              showLink: true,
              showUndo: true,
              showRedo: true,
              showFontFamily: false,
              showFontSize: false,
              showColorButton: false,
              showBackgroundColorButton: false,
              showHeaderStyle: false,
              showStrikeThrough: false,
              showSubscript: false,
              showSuperscript: false,
              showListCheck: false,
              showCodeBlock: false,
              showInlineCode: false,
              showQuote: false,
              showIndent: false,
              showClearFormat: false,
              showSearchButton: false,
              showDirection: false,
              showAlignmentButtons: false,
              showLeftAlignment: false,
              showCenterAlignment: false,
              showRightAlignment: false,
              showJustifyAlignment: false,
              showSmallButton: false,
              embedButtons: [],
            ),
          ),
        ),
        Container(
          constraints: const BoxConstraints(minHeight: 160, maxHeight: 260),
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(8),
            ),
          ),
          child: QuillEditor.basic(
            controller: widget.controller,
            focusNode: _focusNode,
            scrollController: _scrollController,
            config: QuillEditorConfig(
              padding: const EdgeInsets.all(12),
              placeholder: widget.hint ?? 'Escreva aqui…',
            ),
          ),
        ),
      ],
    );
  }
}

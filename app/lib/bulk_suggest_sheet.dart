import 'package:flutter/material.dart';

import 'manage_models.dart';
import 'manage_service.dart';
import 'portal_read.dart';

/// Sugestão em massa com IA — pega as top-3 lacunas críticas da ficha,
/// gera rascunho de cada via /ai/assist e deixa o operador revisar e
/// aplicar tudo em um único clique. Apenas campos de texto (text e
/// longtext) entram; referências, datas e anexos seguem no wizard.
class BulkSuggestSheet extends StatefulWidget {
  const BulkSuggestSheet({
    super.key,
    required this.node,
    required this.fieldWeight,
  });

  final GapNode node;

  /// Peso por nome de campo (mesma tabela da tela de monitoramento).
  final int Function(String fieldName) fieldWeight;

  /// Kinds em que a sugestão de IA faz sentido (prosa).
  static const _proseKinds = {'text', 'longtext'};

  @override
  State<BulkSuggestSheet> createState() => _BulkSuggestSheetState();
}

class _FieldSuggestion {
  _FieldSuggestion({required this.spec, required this.fieldName});

  final ManageField spec;
  final String fieldName;
  String? suggestion;
  String? error;
  bool loading = false;
  bool selected = true;
}

class _BulkSuggestSheetState extends State<BulkSuggestSheet> {
  List<_FieldSuggestion> _items = const [];
  bool _loading = true;
  bool _applying = false;
  String? _error;
  bool? _published;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    final node = widget.node;
    if (node.nid == null) {
      setState(() {
        _loading = false;
        _error = 'Esta ficha não tem vínculo com o portal.';
      });
      return;
    }
    try {
      final results = await Future.wait([
        ManageService.schemas(),
        ManageService.detail(node.type, node.nid!),
      ]);
      if (!mounted) return;
      final bundles = results[0] as List<ManageBundle>;
      final detail = results[1] as Map<String, dynamic>;
      _published = detail['status'] == true;
      final schema = bundles.where((b) => b.name == node.type).firstOrNull;
      if (schema == null) {
        setState(() {
          _loading = false;
          _error = 'O setor ${node.type} não é gerenciável no app.';
        });
        return;
      }
      // Top-3 lacunas por peso, só campos de prosa.
      final pairs = <({String label, String name, int w})>[
        for (var i = 0; i < node.missingFields.length; i++)
          (
            label: i < node.missing.length
                ? node.missing[i]
                : node.missingFields[i],
            name: node.missingFields[i],
            w: widget.fieldWeight(node.missingFields[i]),
          ),
      ]..sort((a, b) => b.w.compareTo(a.w));
      final items = <_FieldSuggestion>[
        for (final p in pairs)
          if (schema.fields.any((f) => f.name == p.name))
            if (BulkSuggestSheet._proseKinds
                .contains(schema.fields
                    .firstWhere((f) => f.name == p.name)
                    .kind))
              _FieldSuggestion(
                spec: schema.fields.firstWhere((f) => f.name == p.name),
                fieldName: p.name,
              ),
      ].take(3).toList();
      if (items.isEmpty) {
        setState(() {
          _loading = false;
          _error =
              'Nenhuma lacuna de texto nesta ficha pode ser sugerida '
              'por IA (referências, datas e anexos seguem no wizard).';
        });
        return;
      }
      setState(() {
        _items = items;
        _loading = false;
      });
      _generateAll();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Não foi possível preparar as sugestões.';
      });
    }
  }

  Future<void> _generateAll() async {
    for (final item in _items) {
      if (!mounted) return;
      setState(() => item.loading = true);
      try {
        final result = await ManageService.aiAssist(
          'draft',
          text: 'Campo "${item.spec.label}" precisa de rascunho.',
          context: 'Tipo: ${widget.node.type}. '
              'Título do item: ${widget.node.title}.',
        );
        if (!mounted) return;
        setState(() {
          item.loading = false;
          item.suggestion = result;
          item.error = result.trim().isEmpty ? 'Sem sugestão.' : null;
          if (result.trim().isEmpty) item.selected = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          item.loading = false;
          item.error = 'A IA não respondeu — tente novamente.';
          item.selected = false;
        });
      }
    }
  }

  dynamic _serialize(_FieldSuggestion item) {
    final text = item.suggestion ?? '';
    if (item.spec.kind == 'longtext') {
      final html = '<p>${text.replaceAll('\n', '</p><p>')}</p>';
      return {'value': html, 'format': 'basic_html'};
    }
    return text;
  }

  Future<void> _apply() async {
    final chosen = _items
        .where((i) => i.selected && i.suggestion != null)
        .toList();
    if (chosen.isEmpty || widget.node.nid == null) return;
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      final values = <String, dynamic>{
        for (final item in chosen) item.fieldName: _serialize(item),
      };
      await ManageService.save(
        widget.node.type,
        nid: widget.node.nid,
        values: values,
        published: _published ?? false,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _applying = false;
        _error = 'O portal recusou o salvamento das sugestões.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _items
        .where((i) => i.selected && i.suggestion != null)
        .length;
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Sugerir com IA',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              widget.node.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null && _items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final item in _items) _suggestionCard(item),
                  ],
                ),
              ),
            if (_error != null && _items.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _applying
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: const Text('Cancelar'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    icon: _applying
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.check, size: 18),
                    label: Text('Aplicar $ready'),
                    onPressed: (_applying || ready == 0) ? null : _apply,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _suggestionCard(_FieldSuggestion item) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: CheckboxListTile(
        value: item.selected && item.suggestion != null,
        onChanged: item.suggestion == null
            ? null
            : (v) => setState(() => item.selected = v ?? false),
        title: Text(
          item.spec.label,
          style: theme.textTheme.titleSmall,
        ),
        subtitle: item.loading
            ? const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(),
              )
            : item.error != null
                ? Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      item.error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      item.suggestion ?? '',
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
        controlAffinity: ListTileControlAffinity.leading,
      ),
    );
  }
}

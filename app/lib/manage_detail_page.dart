import 'package:flutter/material.dart';
import 'package:flutter_quill_delta_from_html/flutter_quill_delta_from_html.dart';

import 'app_config.dart';
import 'manage_form_page.dart';
import 'manage_models.dart';
import 'manage_rich_list.dart';
import 'manage_service.dart';
import 'workflow_widgets.dart';

/// Ficha interna de um item — detalhe completo dentro do app, sem
/// delegar ao Drupal. Campos agrupados pelos mesmos grupos do wizard;
/// "Ver página pública" fica como ação secundária (comparação real).
class ManageDetailPage extends StatefulWidget {
  const ManageDetailPage({
    super.key,
    required this.bundle,
    required this.nid,
  });

  final ManageBundle bundle;
  final int nid;

  @override
  State<ManageDetailPage> createState() => _ManageDetailPageState();
}

class _ManageDetailPageState extends State<ManageDetailPage> {
  Map<String, dynamic> _detail = const {};
  bool _loading = true;
  String? _error;
  final Map<String, List<ManageOption>> _refOptions = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await ManageService.detail(
        widget.bundle.name,
        widget.nid,
      );
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
      _resolveRefs(detail);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Não foi possível carregar a ficha.';
        _loading = false;
      });
    }
  }

  /// Resolve rótulos de referências (uuid → título do termo/entidade).
  Future<void> _resolveRefs(Map<String, dynamic> detail) async {
    final rels = Map<String, dynamic>.from(
      detail['relationships'] as Map? ?? {},
    );
    for (final f in widget.bundle.fields) {
      if (f.kind != 'reference' || f.target == null) continue;
      final uuids = _uuids(rels[f.name]);
      if (uuids.isEmpty) continue;
      try {
        final options = await ManageService.options(f.target!);
        if (!mounted) return;
        setState(() => _refOptions[f.name] = options);
      } catch (_) {
        // Sem permissão para o endpoint de opções — mostra o uuid cru.
      }
    }
  }

  List<String> _uuids(dynamic rel) {
    if (rel is! Map) return const [];
    final data = rel['data'];
    if (data is List) {
      return data
          .whereType<Map>()
          .map((e) => e['id']?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
    }
    if (data is Map) {
      final id = data['id']?.toString() ?? '';
      return id.isEmpty ? const [] : [id];
    }
    return const [];
  }

  String _refLabel(String name) {
    final rels = Map<String, dynamic>.from(
      _detail['relationships'] as Map? ?? {},
    );
    final uuids = _uuids(rels[name]);
    if (uuids.isEmpty) return '—';
    final options = _refOptions[name] ?? const [];
    final labels = uuids
        .map((u) {
          final hit = options.where((o) => o.uuid == u).firstOrNull;
          return hit?.label ?? u.substring(0, 8);
        })
        .toList();
    return labels.join(', ');
  }

  String _displayValue(ManageField f) {
    final values =
        Map<String, dynamic>.from(_detail['values'] as Map? ?? {});
    final raw = values[f.name];
    switch (f.kind) {
      case 'bool':
        return (raw == true) ? 'Sim' : 'Não';
      case 'date':
        final d = _parseDate(raw);
        return d == null
            ? '—'
            : '${d.day.toString().padLeft(2, '0')}/'
                '${d.month.toString().padLeft(2, '0')}/${d.year}';
      case 'daterange':
        if (raw is Map) {
          final s = _parseDate(raw['value']);
          final e = _parseDate(raw['end_value']);
          String fmt(DateTime d) =>
              '${d.day.toString().padLeft(2, '0')}/'
              '${d.month.toString().padLeft(2, '0')}/${d.year}';
          return '${s == null ? '—' : fmt(s)} → ${e == null ? '—' : fmt(e)}';
        }
        return '—';
      case 'longtext':
        final html = raw is Map
            ? (raw['value']?.toString() ?? '')
            : '${raw ?? ''}';
        return html.isEmpty ? '—' : _htmlToText(html);
      case 'link':
        final uri =
            raw is Map ? (raw['uri']?.toString() ?? '') : '${raw ?? ''}';
        return uri.isEmpty ? '—' : uri;
      case 'reference':
        return _refLabel(f.name);
      case 'image' || 'file':
        final uuids =
            _uuids((_detail['relationships'] as Map? ?? {})[f.name]);
        return uuids.isEmpty ? '—' : '${uuids.length} arquivo(s)';
      default:
        if (raw is List) {
          return raw
              .map((e) => e is Map ? '${e['value'] ?? e}' : '$e')
              .join(', ');
        }
        return '${raw ?? '—'}';
    }
  }

  static final _tagPattern = RegExp(r'<[^>]*>');

  String _htmlToText(String html) {
    try {
      final delta = HtmlToDelta().convert(html);
      final buf = StringBuffer();
      for (final op in delta.toList()) {
        if (op.data is String) buf.write(op.data);
      }
      return buf.toString().trim();
    } catch (_) {
      return html.replaceAll(_tagPattern, '').trim();
    }
  }

  DateTime? _parseDate(dynamic raw) {
    if (raw is Map) raw = raw['value'];
    if (raw == null) return null;
    final s = raw.toString();
    return DateTime.tryParse(s.length > 10 ? s : '${s}T00:00:00');
  }

  Future<void> _openEdit() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            ManageFormPage(bundle: widget.bundle, nid: widget.nid),
      ),
    );
    if (changed == true) _load();
  }

  Future<void> _unpublish() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Despublicar?'),
        content: const Text(
          'O item deixará de aparecer no site, mas continuará '
          'salvo como rascunho.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Despublicar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ManageService.unpublish(widget.bundle.name, widget.nid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Item despublicado.')),
      );
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('O portal recusou a despublicação.')),
      );
    }
  }

  String get _publicUrl {
    final base = AppConfig.portalUrl.replaceAll(RegExp(r'/+$'), '');
    return '$base/node/${widget.nid}';
  }

  @override
  Widget build(BuildContext context) {
    final published = _detail['status'] == true;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            floating: true,
            snap: true,
            title: Text(
              _detail['title']?.toString() ?? widget.bundle.labelSingular,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              if (published)
                IconButton(
                  tooltip: 'Despublicar',
                  icon: const Icon(Icons.unpublished_outlined),
                  onPressed: _unpublish,
                ),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            sliver: _loading
                ? const SkeletonSliver()
                : _error != null
                    ? _errorSliver()
                    : _contentSliver(published),
          ),
        ],
      ),
      bottomNavigationBar: _loading || _error != null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: const Text('Ver página pública'),
                        onPressed: () => launchExternalUri(
                          context,
                          Uri.parse(_publicUrl),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: const Text('Editar'),
                        onPressed: _openEdit,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _errorSliver() {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Tentar novamente'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _contentSliver(bool published) {
    final steps = widget.bundle.steps;
    final groups = <({String label, List<ManageField> fields})>[
      if (steps.isEmpty)
        (label: 'Dados', fields: widget.bundle.fields)
      else
        for (final s in steps)
          if (s.id != 'review')
            (
              label: s.label,
              fields: [
                for (final f in widget.bundle.fields)
                  if (f.group == s.id) f,
              ],
            ),
    ];
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  StatusPill(
                    label: published ? 'Publicado' : 'Rascunho',
                    kind: published
                        ? StatusKind.published
                        : StatusKind.draft,
                  ),
                  StatusPill(
                    label: widget.bundle.labelSingular,
                    kind: StatusKind.neutral,
                  ),
                  if (_detail['changed'] != null)
                    Text(
                      'Alterado em ${_changedText('${_detail['changed']}')}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                ],
              ),
            );
          }
          final g = groups[index - 1];
          if (g.fields.isEmpty) return const SizedBox.shrink();
          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    g.label,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const Divider(height: 18),
                  for (final f in g.fields) ...[
                    Text(
                      f.label,
                      style: Theme.of(context).textTheme.labelMedium
                          ?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 2),
                    SelectableText(
                      _displayValue(f),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 12),
                  ],
                ],
              ),
            ),
          );
        },
        childCount: groups.length + 1,
      ),
    );
  }

  String _changedText(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    return '${dt.day.toString().padLeft(2, '0')}/'
        '${dt.month.toString().padLeft(2, '0')}/${dt.year}';
  }
}

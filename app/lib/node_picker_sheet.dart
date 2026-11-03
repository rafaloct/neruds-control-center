import 'package:flutter/material.dart';

import 'manage_models.dart';
import 'manage_service.dart';

/// Seletor nativo de ficha do portal — substitui a colagem de URLs.
/// Busca itens reais via /manage/{bundle} e devolve
/// {'nid': int, 'title': String, 'bundle': String} ao fechar.
class NodePickerSheet extends StatefulWidget {
  const NodePickerSheet({super.key, this.initialBundle});

  /// Bundle pré-selecionado (ex.: o gap_bundle da tarefa).
  final String? initialBundle;

  @override
  State<NodePickerSheet> createState() => _NodePickerSheetState();
}

class _NodePickerSheetState extends State<NodePickerSheet> {
  final _search = TextEditingController();
  List<ManageBundle> _schemas = const [];
  ManageBundle? _bundle;
  List<ManageItem> _items = const [];
  bool _loading = true;
  bool _loadingItems = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSchemas();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadSchemas() async {
    try {
      final schemas = await ManageService.schemas();
      if (!mounted) return;
      setState(() {
        _schemas = schemas;
        _bundle = schemas
            .where((s) => s.name == widget.initialBundle)
            .firstOrNull ??
            (schemas.isNotEmpty ? schemas.first : null);
        _loading = false;
      });
      _loadItems();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'O portal recusou a consulta aos setores.';
        _loading = false;
      });
    }
  }

  Future<void> _loadItems() async {
    final bundle = _bundle;
    if (bundle == null) return;
    setState(() => _loadingItems = true);
    try {
      final items = await ManageService.list(
        bundle.name,
        search: _search.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _items = items;
        _loadingItems = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _items = const [];
        _loadingItems = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .82,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Vincular ficha do portal',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  if (_schemas.isNotEmpty)
                    DropdownButtonFormField<String>(
                      initialValue: _bundle?.name,
                      decoration: const InputDecoration(
                        labelText: 'Setor',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        for (final s in _schemas)
                          DropdownMenuItem(
                            value: s.name,
                            child: Text(s.label),
                          ),
                      ],
                      onChanged: (v) {
                        setState(() => _bundle =
                            _schemas.where((s) => s.name == v).firstOrNull);
                        _loadItems();
                      },
                    ),
                  const SizedBox(height: 10),
                  SearchBar(
                    controller: _search,
                    hintText: 'Buscar pelo título',
                    leading: const Icon(Icons.search),
                    onSubmitted: (_) => _loadItems(),
                    elevation: const WidgetStatePropertyAll(0),
                    side: WidgetStatePropertyAll(
                      BorderSide(
                        color:
                            Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _loadSchemas,
              icon: const Icon(Icons.refresh),
              label: const Text('Tentar novamente'),
            ),
          ],
        ),
      );
    }
    if (_loadingItems) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return const Center(child: Text('Nenhuma ficha encontrada.'));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: CircleAvatar(
              child: Text(
                item.title.isEmpty
                    ? '?'
                    : item.title.characters.first.toUpperCase(),
              ),
            ),
            title: Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${item.status ? 'Publicado' : 'Rascunho'} · #${item.nid}',
            ),
            onTap: () => Navigator.pop(context, {
              'nid': item.nid,
              'title': item.title,
              'bundle': _bundle?.name ?? '',
            }),
          ),
        );
      },
    );
  }
}

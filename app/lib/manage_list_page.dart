import 'package:flutter/material.dart';

import 'manage_form_page.dart';
import 'manage_models.dart';
import 'manage_service.dart';

/// Listagem genérica de um setor — busca, filtro de status e ações por item.
/// Consome GET /manage/{bundle}; sem nada hardcoded por tipo.
class ManageListPage extends StatefulWidget {
  const ManageListPage({super.key, required this.bundle});

  final ManageBundle bundle;

  @override
  State<ManageListPage> createState() => _ManageListPageState();
}

class _ManageListPageState extends State<ManageListPage> {
  final _search = TextEditingController();
  List<ManageItem> _items = const [];
  bool _loading = true;
  String? _error;
  String _status = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await ManageService.list(
        widget.bundle.name,
        status: _status == 'all' ? null : _status,
        search: _search.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Não foi possível carregar ${widget.bundle.label}.';
        _loading = false;
      });
    }
  }

  Future<void> _confirmUnpublish(ManageItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Despublicar ${widget.bundle.labelSingular}?'),
        content: Text(
          '"${item.title}" deixará de aparecer no site, mas continuará '
          'salvo como rascunho. Você pode republicar depois.',
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
      await ManageService.unpublish(widget.bundle.name, item.nid);
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

  Future<void> _openForm([ManageItem? item]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ManageFormPage(bundle: widget.bundle, nid: item?.nid),
      ),
    );
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.bundle.label),
        actions: [
          if (widget.bundle.canCreate)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                onPressed: () => _openForm(),
                icon: const Icon(Icons.add),
                label: Text('Novo'),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    decoration: InputDecoration(
                      hintText: 'Buscar em ${widget.bundle.label}',
                      prefixIcon: const Icon(Icons.search),
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _load(),
                  ),
                ),
                const SizedBox(width: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'all', label: Text('Todos')),
                    ButtonSegment(
                        value: 'published', label: Text('Publicados')),
                    ButtonSegment(value: 'draft', label: Text('Rascunhos')),
                  ],
                  selected: {_status},
                  onSelectionChanged: (s) {
                    setState(() => _status = s.first);
                    _load();
                  },
                ),
              ],
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
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
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Tentar novamente'),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          _status == 'draft'
              ? 'Nenhum rascunho neste setor.'
              : 'Nenhum item encontrado.',
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: _items.length,
        itemBuilder: (context, index) {
          final item = _items[index];
          return ListTile(
            leading: Icon(
              item.status ? Icons.public : Icons.edit_note_outlined,
              color: item.status
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            title: Text(item.title),
            subtitle: Text(
              item.status ? 'Publicado' : 'Rascunho',
              style: TextStyle(
                color: item.status
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            trailing: Wrap(
              spacing: 4,
              children: [
                IconButton(
                  tooltip: 'Editar',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _openForm(item),
                ),
                if (item.status)
                  IconButton(
                    tooltip: 'Despublicar',
                    icon: const Icon(Icons.unpublished_outlined),
                    onPressed: () => _confirmUnpublish(item),
                  ),
              ],
            ),
            onTap: () => _openForm(item),
          );
        },
      ),
    );
  }
}

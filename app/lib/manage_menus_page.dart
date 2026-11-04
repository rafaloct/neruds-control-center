import 'package:flutter/material.dart';

import 'manage_rich_list.dart';
import 'manage_service.dart';

/// Menus e navegação — lista os itens de cada menu do portal,
/// permite ligar/desligar, editar título/URI/peso, adicionar e
/// remover itens. Depende da permissão "administer menu" do Drupal.
class ManageMenusPage extends StatefulWidget {
  const ManageMenusPage({super.key});

  @override
  State<ManageMenusPage> createState() => _ManageMenusPageState();
}

class _ManageMenusPageState extends State<ManageMenusPage> {
  List<Map<String, String>> _menus = const [];
  List<Map<String, dynamic>> _items = const [];
  String? _menu;
  bool _loading = true;
  bool _itemsLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMenus();
  }

  Future<void> _loadMenus() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final menus = await ManageService.menus();
      if (!mounted) return;
      final main = menus.where((m) => m['id'] == 'main').firstOrNull;
      setState(() {
        _menus = menus;
        _menu = (main ?? menus.firstOrNull)?['id'];
        _loading = false;
      });
      if (_menu != null) _loadItems();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error =
            'Não foi possível consultar os menus. A conta precisa da '
            'permissão de administração de menus no portal.';
      });
    }
  }

  Future<void> _loadItems() async {
    final menu = _menu;
    if (menu == null) return;
    setState(() => _itemsLoading = true);
    try {
      final items = await ManageService.menuItems(menu);
      if (!mounted) return;
      setState(() {
        _items = items;
        _itemsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _itemsLoading = false);
    }
  }

  Future<void> _toggle(Map<String, dynamic> item, bool enabled) async {
    try {
      await ManageService.updateMenuItem('${item['uuid']}', {
        'enabled': enabled,
      });
      setState(() => item['enabled'] = enabled);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('O portal recusou a alteração do item.'),
        ),
      );
    }
  }

  Future<void> _editDialog({Map<String, dynamic>? item}) async {
    final title = TextEditingController(text: '${item?['title'] ?? ''}');
    final uri = TextEditingController(text: '${item?['uri'] ?? ''}');
    final weight = TextEditingController(
      text: '${item?['weight'] ?? 0}',
    );
    var expanded = item?['expanded'] == true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(item == null ? 'Novo item' : 'Editar item'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  decoration: const InputDecoration(labelText: 'Título'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: uri,
                  decoration: const InputDecoration(
                    labelText: 'Destino (internal:/rota ou URL)',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: weight,
                  decoration:
                      const InputDecoration(labelText: 'Peso (ordem)'),
                  keyboardType: TextInputType.number,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Expandir subitens'),
                  value: expanded,
                  onChanged: (v) => setLocal(() => expanded = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Salvar'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final patch = {
      'title': title.text.trim(),
      'uri': uri.text.trim(),
      'weight': int.tryParse(weight.text.trim()) ?? 0,
      'expanded': expanded,
    };
    try {
      if (item == null) {
        await ManageService.createMenuItem(_menu!, {
          ...patch,
          'enabled': true,
        });
      } else {
        await ManageService.updateMenuItem('${item['uuid']}', patch);
      }
      _loadItems();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('O portal recusou o salvamento do item.'),
        ),
      );
    }
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remover item?'),
        content: Text(
          '"${item['title']}" sai do menu no portal. '
          'O conteúdo vinculado não é apagado.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ManageService.deleteMenuItem('${item['uuid']}');
      _loadItems();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('O portal recusou a remoção do item.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Menus e navegação'),
        actions: [
          if (_menu != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Novo item'),
                onPressed: () => _editDialog(),
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _errorBody()
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: DropdownButtonFormField<String>(
                        initialValue: _menu,
                        decoration: const InputDecoration(
                          labelText: 'Menu',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final m in _menus)
                            DropdownMenuItem(
                              value: m['id'],
                              child: Text(m['label'] ?? ''),
                            ),
                        ],
                        onChanged: (v) {
                          setState(() => _menu = v);
                          _loadItems();
                        },
                      ),
                    ),
                    Expanded(
                      child: _itemsLoading
                          ? const SkeletonList(count: 6)
                          : RefreshIndicator(
                              onRefresh: _loadItems,
                              child: _items.isEmpty
                                  ? ListView(
                                      children: const [
                                        Padding(
                                          padding: EdgeInsets.all(40),
                                          child: Center(
                                            child: Text(
                                              'Este menu não tem itens.',
                                            ),
                                          ),
                                        ),
                                      ],
                                    )
                                  : ListView.builder(
                                      padding: const EdgeInsets.all(16),
                                      itemCount: _items.length,
                                      itemBuilder: (context, i) =>
                                          _itemCard(_items[i]),
                                    ),
                            ),
                    ),
                  ],
                ),
    );
  }

  Widget _itemCard(Map<String, dynamic> item) {
    final enabled = item['enabled'] == true;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          enabled ? Icons.link : Icons.link_off,
          color: enabled ? null : Theme.of(context).colorScheme.outline,
        ),
        title: Text(
          '${item['title']}',
          style: TextStyle(
            decoration: enabled ? null : TextDecoration.lineThrough,
          ),
        ),
        subtitle: Text(
          '${item['uri']}  ·  peso ${item['weight']}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: enabled,
              onChanged: (v) => _toggle(item, v),
            ),
            IconButton(
              tooltip: 'Editar',
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: () => _editDialog(item: item),
            ),
            IconButton(
              tooltip: 'Remover',
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => _delete(item),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorBody() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline, size: 40),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(_error!, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _loadMenus,
            icon: const Icon(Icons.refresh),
            label: const Text('Tentar novamente'),
          ),
        ],
      ),
    );
  }
}

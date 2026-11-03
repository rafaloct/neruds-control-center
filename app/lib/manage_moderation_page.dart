import 'package:flutter/material.dart';

import 'manage_form_page.dart';
import 'manage_models.dart';
import 'manage_service.dart';

/// Painel de moderação — fila unificada de rascunhos pendentes em todos
/// os setores. Visível para contas com permissão de revisão.
class ManageModerationPage extends StatefulWidget {
  const ManageModerationPage({super.key, required this.schemas});

  final List<ManageBundle> schemas;

  @override
  State<ManageModerationPage> createState() => _ManageModerationPageState();
}

class _ManageModerationPageState extends State<ManageModerationPage> {
  List<Map<String, dynamic>> _items = const [];
  bool _loading = true;
  String? _error;

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
      final items = await ManageService.moderationPending();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Não foi possível carregar a fila de aprovação.';
        _loading = false;
      });
    }
  }

  ManageBundle? _bundleOf(Map<String, dynamic> item) {
    for (final b in widget.schemas) {
      if (b.name == item['bundle']) return b;
    }
    return null;
  }

  Future<void> _approve(Map<String, dynamic> item) async {
    final title = item['title']?.toString() ?? '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Aprovar e publicar?'),
        content: Text(
          '"$title" ficará visível no site imediatamente.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Aprovar e publicar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ManageService.approve(
        item['bundle'].toString(),
        item['nid'] is int
            ? item['nid']
            : int.parse('${item['nid']}'),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"$title" publicado no site.')),
      );
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'O portal recusou a publicação — verifique se sua conta '
            'tem permissão de aprovar este setor.',
          ),
        ),
      );
    }
  }

  Future<void> _openEdit(Map<String, dynamic> item) async {
    final bundle = _bundleOf(item);
    if (bundle == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ManageFormPage(
          bundle: bundle,
          nid: item['nid'] is int
              ? item['nid']
              : int.tryParse('${item['nid']}'),
        ),
      ),
    );
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Aprovações')),
      body: _buildBody(),
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
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Nenhum rascunho aguardando aprovação.\n'
            'Quando extensionistas salvarem conteúdo, aparece aqui.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: _items.length,
        itemBuilder: (context, index) {
          final item = _items[index];
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListTile(
              leading: const Icon(Icons.rate_review_outlined),
              title: Text(item['title']?.toString() ?? ''),
              subtitle: Text(
                '${item['bundle_label'] ?? item['bundle']} · rascunho',
              ),
              trailing: Wrap(
                spacing: 4,
                children: [
                  IconButton(
                    tooltip: 'Abrir/editar',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _openEdit(item),
                  ),
                  IconButton.filled(
                    tooltip: 'Aprovar e publicar',
                    icon: const Icon(Icons.check_circle_outline),
                    onPressed: () => _approve(item),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

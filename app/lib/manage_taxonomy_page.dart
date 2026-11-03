import 'package:flutter/material.dart';

import 'manage_models.dart';
import 'manage_service.dart';

/// Gestão de taxonomias — vocabulário → lista de termos → diálogo CRUD.
/// Reusa o padrão de lista genérica; os termos usam sempre o mesmo shape
/// (nome, descrição, peso, pai), então um único formulário cobre tudo.
class ManageTaxonomyPage extends StatefulWidget {
  const ManageTaxonomyPage({super.key});

  @override
  State<ManageTaxonomyPage> createState() => _ManageTaxonomyPageState();
}

class _ManageTaxonomyPageState extends State<ManageTaxonomyPage> {
  List<Map<String, String>> _vocabs = const [];
  String? _vocab;
  List<ManageItem> _terms = const [];
  bool _loading = true;
  String? _error;

  String get _vocabLabel => _vocabs
      .firstWhere((v) => v['vid'] == _vocab,
          orElse: () => const {'label': ''})['label'] ??
      '';

  @override
  void initState() {
    super.initState();
    _loadVocabs();
  }

  Future<void> _loadVocabs() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final vocabs = await ManageService.vocabularies();
    if (!mounted) return;
    setState(() {
      _vocabs = vocabs;
      _vocab = vocabs.isEmpty ? null : vocabs.first['vid'];
      _loading = false;
    });
    if (_vocab != null) _loadTerms();
  }

  Future<void> _loadTerms() async {
    if (_vocab == null) return;
    setState(() => _loading = true);
    try {
      final terms = await ManageService.terms(_vocab!);
      if (!mounted) return;
      setState(() {
        _terms = terms;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'O portal recusou a consulta ao vocabulário.';
        _loading = false;
      });
    }
  }

  Future<void> _editTerm([ManageItem? term]) async {
    final name = TextEditingController(text: term?.title ?? '');
    final weight = TextEditingController(text: '0');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          term == null ? 'Novo termo' : 'Editar "${term.title}"',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Nome *'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: weight,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Peso',
                helperText: 'Menor aparece primeiro nas listagens.',
              ),
            ),
          ],
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
    );
    if (saved != true || name.text.trim().isEmpty) return;
    try {
      await ManageService.saveTerm(
        _vocab!,
        tid: term?.nid,
        values: {
          'name': name.text.trim(),
          'weight': int.tryParse(weight.text.trim()) ?? 0,
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Termo salvo em "$_vocabLabel".')),
      );
      _loadTerms();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('O portal recusou o salvamento.')),
      );
    }
  }

  Future<void> _deleteTerm(ManageItem term) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Excluir "${term.title}"?'),
        content: const Text(
          'O termo será removido de todos os conteúdos que o usam.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ManageService.deleteTerm(_vocab!, term.nid);
      if (!mounted) return;
      _loadTerms();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('O portal recusou a exclusão.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Categorias e Tags')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: DropdownButtonFormField<String>(
              key: const Key('vocab-picker'),
              initialValue: _vocab,
              decoration: const InputDecoration(
                labelText: 'Vocabulário',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final v in _vocabs)
                  DropdownMenuItem(
                    value: v['vid'],
                    child: Text(v['label'] ?? ''),
                  ),
              ],
              onChanged: (v) {
                setState(() => _vocab = v);
                _loadTerms();
              },
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editTerm(),
        icon: const Icon(Icons.add),
        label: const Text('Novo termo'),
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
              onPressed: _loadTerms,
              icon: const Icon(Icons.refresh),
              label: const Text('Tentar novamente'),
            ),
          ],
        ),
      );
    }
    if (_terms.isEmpty) {
      return const Center(child: Text('Nenhum termo neste vocabulário.'));
    }
    return RefreshIndicator(
      onRefresh: _loadTerms,
      child: ListView.builder(
        itemCount: _terms.length,
        itemBuilder: (context, index) {
          final term = _terms[index];
          return ListTile(
            title: Text(term.title),
            trailing: Wrap(
              spacing: 4,
              children: [
                IconButton(
                  tooltip: 'Editar',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _editTerm(term),
                ),
                IconButton(
                  tooltip: 'Excluir',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _deleteTerm(term),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

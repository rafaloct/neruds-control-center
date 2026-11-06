import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import 'manage_detail_page.dart';
import 'manage_form_page.dart';
import 'manage_models.dart';
import 'manage_rich_list.dart';
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

  int? _itemNid(Map<String, dynamic> item) => item['nid'] is int
      ? item['nid']
      : int.tryParse('${item['nid']}');

  Future<void> _openEdit(Map<String, dynamic> item) async {
    final bundle = _bundleOf(item);
    if (bundle == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ManageFormPage(
          bundle: bundle,
          nid: _itemNid(item),
        ),
      ),
    );
    if (changed == true) _load();
  }

  Future<void> _openDetail(Map<String, dynamic> item) async {
    final bundle = _bundleOf(item);
    final nid = _itemNid(item);
    if (bundle == null || nid == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ManageDetailPage(bundle: bundle, nid: nid),
      ),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            const SliverAppBar(
              floating: true,
              snap: true,
              title: Text('Aprovações'),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
              sliver: _buildContent(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_loading) {
      return const SkeletonSliver();
    }
    if (_error != null) {
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
    if (_items.isEmpty) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Text(
              'Nenhum rascunho aguardando aprovação.\n'
              'Quando extensionistas salvarem conteúdo, aparece aqui.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    final grid = MediaQuery.sizeOf(context).width >= 720;
    Widget card(int index) {
      final item = _items[index];
      return RichListCard(
        title: item['title']?.toString() ?? '',
        status: 'Pendente',
        statusKind: StatusKind.pending,
        subtitle: '${item['bundle_label'] ?? item['bundle']}',
        avatarIcon: Icons.rate_review_outlined,
        showChevron: false,
        onTap: () => _openDetail(item),
        actions: [
          SlideAction(
            icon: Icons.edit_outlined,
            label: 'Editar',
            onTap: () => _openEdit(item),
          ),
          SlideAction(
            icon: Icons.check_circle_outline,
            label: 'Aprovar',
            onTap: () => _approve(item),
          ),
        ],
      )
          .animate()
          .fadeIn(duration: 220.ms, delay: ((index % 12) * 30).ms)
          .slideY(begin: .04, end: 0, duration: 220.ms);
    }

    if (grid) {
      return SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisExtent: 128,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
        ),
        delegate: SliverChildBuilderDelegate(
          (_, i) => card(i),
          childCount: _items.length,
        ),
      );
    }
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, i) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: card(i),
        ),
        childCount: _items.length,
      ),
    );
  }
}

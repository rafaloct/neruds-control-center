import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import 'manage_form_page.dart';
import 'manage_models.dart';
import 'manage_rich_list.dart';
import 'manage_service.dart';
import 'project_timeline.dart';

/// Listagem de um setor — CustomScrollView + SliverAppBar + cartões ricos.
/// Mesma fonte de dados (ManageService/JSON:API); só a apresentação muda.
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

  Future<void> _openFilters() async {
    var status = _status;
    final applied = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Filtros', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                Text('Status', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'all', label: Text('Todos')),
                    ButtonSegment(
                        value: 'published', label: Text('Publicados')),
                    ButtonSegment(value: 'draft', label: Text('Rascunhos')),
                  ],
                  selected: {status},
                  onSelectionChanged: (s) =>
                      setSheet(() => status = s.first),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Aplicar'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (applied == true) {
      setState(() => _status = status);
      _load();
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

  void _openTimeline(ManageItem item) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProjectTimelinePage(project: item),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              floating: true,
              snap: true,
              title: Text(widget.bundle.label),
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(68),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: SearchBar(
                          controller: _search,
                          hintText: 'Buscar em ${widget.bundle.label}',
                          leading: const Icon(Icons.search),
                          onSubmitted: (_) => _load(),
                          elevation:
                              const WidgetStatePropertyAll(0),
                          side: WidgetStatePropertyAll(
                            BorderSide(color: scheme.outlineVariant),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Badge(
                        isLabelVisible: _status != 'all',
                        smallSize: 8,
                        child: IconButton.filledTonal(
                          tooltip: 'Filtros',
                          icon: const Icon(Icons.tune),
                          onPressed: _openFilters,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
              sliver: _buildContent(),
            ),
          ],
        ),
      ),
      floatingActionButton: widget.bundle.canCreate
          ? FloatingActionButton.extended(
              onPressed: () => _openForm(),
              icon: const Icon(Icons.add),
              label: Text('Nova ${widget.bundle.labelSingular}'),
            )
          : null,
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
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Text(
            'Nenhum item em ${widget.bundle.label}.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final width = MediaQuery.sizeOf(context).width;
    final grid = width >= 720;
    final delegate = SliverChildBuilderDelegate(
      (context, index) {
        final item = _items[index];
        return Padding(
          padding: EdgeInsets.only(bottom: grid ? 0 : 10),
          child: RichListCard(
          title: item.title,
          status: item.status ? 'Publicado' : 'Rascunho',
          statusKind: item.status
              ? StatusKind.published
              : StatusKind.draft,
          subtitle:
              item.changed == null ? null : _changedText(item.changed!),
          showChevron: !grid,
          onTap: () => _openForm(item),
          actions: [
            SlideAction(
              icon: Icons.edit_outlined,
              label: 'Editar',
              onTap: () => _openForm(item),
            ),
            if (widget.bundle.name == 'projeto_pesquisa_extensao')
              SlideAction(
                icon: Icons.timeline_outlined,
                label: 'Cronograma',
                onTap: () => _openTimeline(item),
              ),
            if (item.status)
              SlideAction(
                icon: Icons.unpublished_outlined,
                label: 'Despublicar',
                onTap: () => _confirmUnpublish(item),
                destructive: true,
              ),
          ],
          ),
        )
            .animate()
            .fadeIn(duration: 220.ms, delay: ((index % 12) * 30).ms)
            .slideY(begin: .04, end: 0, duration: 220.ms);
      },
      childCount: _items.length,
    );
    if (grid) {
      return SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisExtent: 128,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
        ),
        delegate: delegate,
      );
    }
    return SliverList(delegate: delegate);
  }
}

String _changedText(String iso) {
  final dt = DateTime.tryParse(iso);
  if (dt == null) return '';
  return '${dt.day.toString().padLeft(2, '0')}/'
      '${dt.month.toString().padLeft(2, '0')}/${dt.year}';
}

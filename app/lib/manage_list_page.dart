import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:shimmer/shimmer.dart';

import 'manage_form_page.dart';
import 'manage_models.dart';
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
      return const _SkeletonSliver();
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
        return _RichCard(
          item: item,
          bundleName: widget.bundle.name,
          isGrid: grid,
          onEdit: () => _openForm(item),
          onUnpublish:
              item.status ? () => _confirmUnpublish(item) : null,
          onTimeline: widget.bundle.name == 'projeto_pesquisa_extensao'
              ? () => _openTimeline(item)
              : null,
          onTap: () => _openForm(item),
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
    return SliverList.list(
      children: [
        for (var i = 0; i < _items.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: delegate.build(context, i)!,
          ),
      ],
    );
  }
}

/// Card rico: avatar com inicial, título, status em chip, data e ações
/// por deslize (slidable) — sem abrir o detalhe para editar/despublicar.
class _RichCard extends StatelessWidget {
  const _RichCard({
    required this.item,
    required this.bundleName,
    required this.isGrid,
    this.onEdit,
    this.onUnpublish,
    this.onTimeline,
    this.onTap,
  });

  final ManageItem item;
  final String bundleName;
  final bool isGrid;
  final VoidCallback? onEdit;
  final VoidCallback? onUnpublish;
  final VoidCallback? onTimeline;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final published = item.status;
    final card = Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: published
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                foregroundColor: published
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
                child: Text(
                  item.title.isEmpty
                      ? '?'
                      : item.title.characters.first.toUpperCase(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _StatusChip(published: published),
                        if (item.changed != null)
                          Text(
                            _changedText(item.changed!),
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (!isGrid)
                Icon(
                  Icons.chevron_right,
                  color: scheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
    return Slidable(
      key: ValueKey('item-${item.nid}'),
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        children: [
          if (onEdit != null)
            SlidableAction(
              onPressed: (_) => onEdit!(),
              icon: Icons.edit_outlined,
              label: 'Editar',
              backgroundColor: scheme.primaryContainer,
              foregroundColor: scheme.onPrimaryContainer,
            ),
          if (onTimeline != null)
            SlidableAction(
              onPressed: (_) => onTimeline!(),
              icon: Icons.timeline_outlined,
              label: 'Cronograma',
              backgroundColor: scheme.tertiaryContainer,
              foregroundColor: scheme.onTertiaryContainer,
            ),
          if (onUnpublish != null)
            SlidableAction(
              onPressed: (_) => onUnpublish!(),
              icon: Icons.unpublished_outlined,
              label: 'Despublicar',
              backgroundColor: scheme.errorContainer,
              foregroundColor: scheme.onErrorContainer,
            ),
        ],
      ),
      child: card,
    );
  }

  String _changedText(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    return '${dt.day.toString().padLeft(2, '0')}/'
        '${dt.month.toString().padLeft(2, '0')}/${dt.year}';
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.published});

  final bool published;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: published
            ? scheme.primaryContainer
            : scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        published ? 'Publicado' : 'Rascunho',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: published
                  ? scheme.onPrimaryContainer
                  : scheme.onTertiaryContainer,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

/// Skeletons pulsantes imitando os cards reais enquanto a lista carrega.
class _SkeletonSliver extends StatelessWidget {
  const _SkeletonSliver();

  @override
  Widget build(BuildContext context) {
    final grid = MediaQuery.sizeOf(context).width >= 720;
    final card = Shimmer.fromColors(
      baseColor:
          Theme.of(context).colorScheme.surfaceContainerHighest,
      highlightColor: Theme.of(context).colorScheme.surface,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const CircleAvatar(radius: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 14,
                      width: double.infinity,
                      color: Colors.white,
                    ),
                    const SizedBox(height: 8),
                    Container(height: 10, width: 120, color: Colors.white),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (grid) {
      return SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisExtent: 128,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
        ),
        delegate: SliverChildBuilderDelegate((_, i) => card, childCount: 6),
      );
    }
    return SliverList.list(
      children: [
        for (var i = 0; i < 6; i++)
          Padding(padding: const EdgeInsets.only(bottom: 10), child: card),
      ],
    );
  }
}

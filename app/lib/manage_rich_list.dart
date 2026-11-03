import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:shimmer/shimmer.dart';

/// Componentes de listagem rica compartilhados pelas telas de Gestão —
/// avatar, título em destaque, chip de status e ações por deslize.
/// Apenas apresentação: o data binding fica nas páginas/serviços.

/// Chip de status colorido (publicado/rascunho/pendente).
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.kind});

  final String label;
  final StatusKind kind;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (kind) {
      StatusKind.published =>
        (scheme.primaryContainer, scheme.onPrimaryContainer),
      StatusKind.draft => (
          scheme.tertiaryContainer,
          scheme.onTertiaryContainer,
        ),
      StatusKind.pending =>
        (scheme.errorContainer, scheme.onErrorContainer),
      StatusKind.neutral => (
          scheme.surfaceContainerHighest,
          scheme.onSurfaceVariant,
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

enum StatusKind { published, draft, pending, neutral }

/// Ação disponível ao deslizar o cartão.
class SlideAction {
  const SlideAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;
}

/// Cartão rico de item de lista.
class RichListCard extends StatelessWidget {
  const RichListCard({
    super.key,
    required this.title,
    required this.status,
    required this.statusKind,
    this.subtitle,
    this.avatarText,
    this.avatarIcon,
    this.onTap,
    this.actions = const [],
    this.showChevron = true,
  });

  final String title;
  final String status;
  final StatusKind statusKind;
  final String? subtitle;
  final String? avatarText;
  final IconData? avatarIcon;
  final VoidCallback? onTap;
  final List<SlideAction> actions;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = statusKind != StatusKind.neutral;
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
                backgroundColor: statusKind == StatusKind.published
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                foregroundColor: statusKind == StatusKind.published
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
                child: avatarIcon != null
                    ? Icon(avatarIcon, size: 20)
                    : Text(
                        title.isEmpty
                            ? '?'
                            : (avatarText ??
                                    title.characters.first)
                                .toUpperCase(),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
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
                        StatusPill(label: status, kind: statusKind),
                        if (subtitle != null && subtitle!.isNotEmpty)
                          Text(
                            subtitle!,
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (showChevron && actions.isEmpty)
                Icon(
                  Icons.chevron_right,
                  color: active
                      ? scheme.onSurfaceVariant
                      : scheme.outlineVariant,
                ),
            ],
          ),
        ),
      ),
    );
    if (actions.isEmpty) return card;
    return Slidable(
      key: ValueKey('rich-$title-${identityHashCode(this)}'),
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        children: [
          for (final a in actions)
            SlidableAction(
              onPressed: (_) => a.onTap(),
              icon: a.icon,
              label: a.label,
              backgroundColor: a.destructive
                  ? scheme.errorContainer
                  : scheme.primaryContainer,
              foregroundColor: a.destructive
                  ? scheme.onErrorContainer
                  : scheme.onPrimaryContainer,
            ),
        ],
      ),
      child: card,
    );
  }
}

/// Skeleton pulsante imitando o RichListCard durante o carregamento.
class SkeletonCard extends StatelessWidget {
  const SkeletonCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
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
                    Container(
                      height: 10,
                      width: 120,
                      color: Colors.white,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 6 skeletons como sliver — mesma malha do conteúdo real.
class SkeletonSliver extends StatelessWidget {
  const SkeletonSliver({super.key, this.count = 6});

  final int count;

  @override
  Widget build(BuildContext context) {
    final grid = MediaQuery.sizeOf(context).width >= 720;
    if (grid) {
      return SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisExtent: 128,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
        ),
        delegate: SliverChildBuilderDelegate(
          (_, i) => const SkeletonCard(),
          childCount: count,
        ),
      );
    }
    return SliverList.list(
      children: [
        for (var i = 0; i < count; i++)
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: SkeletonCard(),
          ),
      ],
    );
  }
}

/// Variante não-sliver para páginas com corpo simples.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.count = 6});

  final int count;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SkeletonSliver(count: count),
        ),
      ],
    );
  }
}

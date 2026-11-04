import 'package:flutter/material.dart';

import 'app_config.dart';
import 'manage_models.dart';
import 'manage_rich_list.dart';
import 'manage_service.dart';
import 'manage_navigation.dart';
import 'workflow_widgets.dart';

/// Prévia interna da página inicial — compõe as seções da home do
/// portal (Últimas Notícias, Publicações, Grupos) com os dados reais
/// do /manage, para conferir como o site vai ficar sem abrir o
/// navegador. "Abrir site" fica como ação secundária (comparação).
class HomePreviewPage extends StatelessWidget {
  const HomePreviewPage({super.key});

  static const _sections = <({String bundle, String label, String icon})>[
    (bundle: 'noticia', label: 'Últimas Notícias', icon: '📰'),
    (
      bundle: 'publicacao_cientifica',
      label: 'Publicações Científicas',
      icon: '📚',
    ),
    (
      bundle: 'grupo_estudos',
      label: 'Grupos de Estudos',
      icon: '👥',
    ),
    (
      bundle: 'acao_extensionista',
      label: 'Ações Extensionistas',
      icon: '🤝',
    ),
    (
      bundle: 'evento_cientifico',
      label: 'Eventos Científicos',
      icon: '📅',
    ),
  ];

  String get _siteUrl =>
      AppConfig.portalUrl.replaceAll(RegExp(r'/+$'), '');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Prévia da página inicial'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Abrir site'),
              onPressed: () =>
                  launchExternalUri(context, Uri.parse(_siteUrl)),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Como o portal apresenta o conteúdo hoje. '
            'Toque num item para abrir a ficha dentro do app.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 16),
          for (final s in _sections) _PreviewSection(section: s),
        ],
      ),
    );
  }
}

class _PreviewSection extends StatelessWidget {
  const _PreviewSection({required this.section});

  final ({String bundle, String label, String icon}) section;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ManageItem>>(
      future: ManageService.list(
        section.bundle,
        status: 'published',
        limit: 4,
      ),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Column(
            children: [SkeletonCard(), SkeletonCard()],
          );
        }
        if (snap.hasError) {
          // erro de seção degrada para lista vazia — registrado via takeException nos testes
        }
        final items = snap.data ?? const <ManageItem>[];
        final theme = Theme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('${section.icon}  '),
                Expanded(
                  child: Text(
                    section.label,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (items.length > 2)
                  Text(
                    '+${items.length - 2} mais',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            const Divider(height: 10),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  'Nenhum item publicado nesta seção.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              for (final item in items.take(2))
                _PreviewCard(item: item, bundle: section.bundle),
            const SizedBox(height: 12),
          ],
        );
      },
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.item, required this.bundle});

  final ManageItem item;
  final String bundle;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => openManageDetail(
          context,
          nid: item.nid,
          bundleName: bundle,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 12,
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor:
                    Theme.of(context).colorScheme.primaryContainer,
                child: Text(
                  item.title.isNotEmpty ? item.title[0] : '?',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context)
                        .colorScheme
                        .onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

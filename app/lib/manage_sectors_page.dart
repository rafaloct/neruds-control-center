import 'package:flutter/material.dart';

import 'app_session.dart';
import 'home_preview_page.dart';
import 'manage_list_page.dart';
import 'manage_menus_page.dart';
import 'manage_moderation_page.dart';
import 'manage_models.dart';
import 'manage_service.dart';
import 'manage_taxonomy_page.dart';
import 'manage_users_page.dart';

/// Dashboard de setores — grid de módulos de gestão disponíveis para a
/// sessão, renderizado a partir de GET /manage/schemas. Novo setor no
/// bridge aparece aqui automaticamente.
class ManageSectorsPage extends StatefulWidget {
  const ManageSectorsPage({super.key});

  @override
  State<ManageSectorsPage> createState() => _ManageSectorsPageState();
}

class _ManageSectorsPageState extends State<ManageSectorsPage> {
  List<ManageBundle> _bundles = const [];
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
      final bundles = await ManageService.schemas();
      if (!mounted) return;
      setState(() {
        _bundles = bundles;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Não foi possível carregar os setores do portal.';
        _loading = false;
      });
    }
  }

  IconData _iconFor(String name) => switch (name) {
        'newspaper' => Icons.newspaper_outlined,
        'event' => Icons.event_outlined,
        'folder' => Icons.folder_outlined,
        'person' => Icons.person_outline,
        'menu_book' => Icons.menu_book_outlined,
        'groups' => Icons.groups_outlined,
        'volunteer_activism' => Icons.volunteer_activism_outlined,
        'description' => Icons.description_outlined,
        'groups_2' => Icons.groups_2_outlined,
        _ => Icons.category_outlined,
      };

  @override
  Widget build(BuildContext context) {
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
    if (_bundles.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Esta conta ainda não tem setores de gestão disponíveis. '
            'Fale com a coordenação para receber acesso.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Gestão do portal',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            'Escolha o setor que deseja gerenciar. O portal continua sendo '
            'a fonte oficial — tudo que você mudar aqui vale na hora no site.',
          ),
          const SizedBox(height: 16),
          // Prévia interna — como o site monta a home com os dados
          // gerenciados aqui (sem abrir o navegador).
          OutlinedButton.icon(
            icon: const Icon(Icons.visibility_outlined, size: 18),
            label: const Text('Prévia da página inicial'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const HomePreviewPage()),
            ),
          ),
          const SizedBox(height: 20),
          GridView.count(
            crossAxisCount: _gridColumns(context),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.6,
            children: [
              if (AppSession.instance.canReview ||
                  AppSession.instance.canAdminUsers)
                _ActionCard(
                  icon: Icons.rate_review_outlined,
                  title: 'Aprovações',
                  subtitle: 'Rascunhos aguardando revisão',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          ManageModerationPage(schemas: _bundles),
                    ),
                  ),
                ),
              for (final bundle in _bundles)
                _SectorCard(
                  bundle: bundle,
                  icon: _iconFor(bundle.icon),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ManageListPage(bundle: bundle),
                    ),
                  ),
                ),
              _ActionCard(
                icon: Icons.menu_outlined,
                title: 'Menus e navegação',
                subtitle: 'Itens de menu do portal',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ManageMenusPage(),
                  ),
                ),
              ),
              _ActionCard(
                icon: Icons.category_outlined,
                title: 'Categorias e Tags',
                subtitle: 'Vocabulários e termos',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ManageTaxonomyPage(),
                  ),
                ),
              ),
              if (AppSession.instance.canAdminUsers)
                _ActionCard(
                  icon: Icons.group_outlined,
                  title: 'Equipe',
                  subtitle: 'Contas e permissões',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const ManageUsersPage(),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  int _gridColumns(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    if (width > 1100) return 4;
    if (width > 700) return 3;
    return 2;
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      color: scheme.secondaryContainer,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: scheme.onSecondaryContainer, size: 28),
              const Spacer(),
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectorCard extends StatelessWidget {
  const _SectorCard({
    required this.bundle,
    required this.icon,
    required this.onTap,
  });

  final ManageBundle bundle;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: scheme.primary, size: 28),
              const Spacer(),
              Text(
                bundle.label,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                bundle.canCreate
                    ? 'Criar e gerenciar'
                    : 'Somente gerenciar',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: bundle.canCreate
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

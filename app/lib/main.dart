import 'package:flutter/material.dart';

import 'app_session.dart';
import 'drupal_api.dart';
import 'editorial_page.dart';
import 'identity_page.dart';
import 'mission_page.dart';
import 'opportunities_page.dart';

void main() {
  runApp(const NerudsControlApp());
}

class NerudsControlApp extends StatelessWidget {
  const NerudsControlApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NERUDS Control Center',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF315D45),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F7F4),
      ),
      home: const ControlHome(),
    );
  }
}

class ControlHome extends StatefulWidget {
  const ControlHome({super.key});

  @override
  State<ControlHome> createState() => _ControlHomeState();
}

class _ControlHomeState extends State<ControlHome> {
  final DrupalApi api = DrupalApi();
  int index = 0;
  late Future<PortalSnapshot> snapshot;

  @override
  void initState() {
    super.initState();
    snapshot = api.loadSnapshot();
  }

  void refresh() {
    setState(() => snapshot = api.loadSnapshot());
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardPage(snapshot: snapshot, onRefresh: refresh),
      const EditorialPage(),
      const MissionPage(),
      const OpportunitiesPage(),
      const AdminPage(),
    ];

    const destinations = [
      NavigationDestination(
        icon: Icon(Icons.dashboard_outlined),
        label: 'Início',
      ),
      NavigationDestination(
        icon: Icon(Icons.edit_note_outlined),
        label: 'Conteúdo',
      ),
      NavigationDestination(
        icon: Icon(Icons.task_alt_outlined),
        label: 'Missão',
      ),
      NavigationDestination(
        icon: Icon(Icons.rss_feed_outlined),
        label: 'Oportunidades',
      ),
      NavigationDestination(
        icon: Icon(Icons.admin_panel_settings_outlined),
        label: 'Administração',
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;

        if (!wide) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('NERUDS Control Center'),
              actions: [
                IconButton(
                  tooltip: 'Atualizar',
                  onPressed: refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            body: pages[index],
            bottomNavigationBar: NavigationBar(
              selectedIndex: index,
              onDestinationSelected: (value) => setState(() => index = value),
              destinations: destinations,
            ),
          );
        }

        return Scaffold(
          body: Row(
            children: [
              NavigationRail(
                extended: true,
                selectedIndex: index,
                onDestinationSelected: (value) =>
                    setState(() => index = value),
                leading: const Padding(
                  padding: EdgeInsets.fromLTRB(16, 24, 16, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'NERUDS',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text('Controle do portal'),
                    ],
                  ),
                ),
                destinations: destinations
                    .map(
                      (item) => NavigationRailDestination(
                        icon: item.icon,
                        label: Text(item.label),
                      ),
                    )
                    .toList(),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: IconButton(
                          tooltip: 'Atualizar',
                          onPressed: refresh,
                          icon: const Icon(Icons.refresh),
                        ),
                      ),
                    ),
                    Expanded(child: pages[index]),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({
    super.key,
    required this.snapshot,
    required this.onRefresh,
  });

  final Future<PortalSnapshot> snapshot;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PortalSnapshot>(
      future: snapshot,
      builder: (context, result) {
        final data = result.data;
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Visão geral',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 6),
            const Text(
              'O essencial do portal em uma tela, sem precisar entrar no painel técnico do Drupal.',
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                MetricCard(
                  icon: data?.online == true
                      ? Icons.check_circle_outline
                      : Icons.cloud_off_outlined,
                  title: 'Portal',
                  value: result.connectionState == ConnectionState.waiting
                      ? 'Verificando...'
                      : data?.online == true
                          ? 'Online'
                          : 'Indisponível',
                ),
                MetricCard(
                  icon: Icons.hub_outlined,
                  title: 'CMS',
                  value: data?.generator ?? 'Verificando...',
                ),
                MetricCard(
                  icon: Icons.inventory_2_outlined,
                  title: 'Tipos de conteúdo',
                  value: '${data?.contentTypes.length ?? 0}',
                ),
                const MetricCard(
                  icon: Icons.shield_outlined,
                  title: 'Modo',
                  value: 'Editorial seguro',
                ),
              ],
            ),
            const SizedBox(height: 28),
            Text(
              'Últimas notícias',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 10),
            if (data?.error != null)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.warning_amber_outlined),
                  title: const Text('Não foi possível consultar o portal'),
                  subtitle: Text(data!.error!),
                  trailing: IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: onRefresh,
                  ),
                ),
              )
            else if (data?.latestNews.isEmpty ?? true)
              const Card(
                child: ListTile(
                  title: Text('Nenhuma notícia carregada.'),
                ),
              )
            else
              ...data!.latestNews.map(
                (item) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.article_outlined),
                    title: Text(item['title'] ?? 'Sem título'),
                    subtitle: Text(
                      'Estado: ${item['state']?.isEmpty == true ? 'não informado' : item['state']}',
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 230,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon),
              const SizedBox(height: 18),
              Text(title, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              Text(value, style: Theme.of(context).textTheme.titleLarge),
            ],
          ),
        ),
      ),
    );
  }
}

class RoutinePage extends StatefulWidget {
  const RoutinePage({super.key});

  @override
  State<RoutinePage> createState() => _RoutinePageState();
}

class _RoutinePageState extends State<RoutinePage> {
  final done = <int>{};

  static const routines = [
    ('Revisar rascunhos', 'Semanal', Icons.rate_review_outlined),
    ('Checar links e anexos', 'Semanal', Icons.link_outlined),
    ('Atualizar projetos em andamento', 'Mensal', Icons.science_outlined),
    ('Conferir equipe e bolsistas', 'Mensal', Icons.groups_outlined),
    ('Revisar publicações recentes', 'Mensal', Icons.menu_book_outlined),
    ('Exportar inventário do portal', 'Mensal', Icons.archive_outlined),
    ('Testar backup e restauração', 'Trimestral', Icons.backup_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Rotinas de perpetuidade',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 6),
        const Text(
          'Checklists simples para que a troca de bolsistas não interrompa a manutenção do portal.',
        ),
        const SizedBox(height: 20),
        for (var i = 0; i < routines.length; i++)
          CheckboxListTile(
            value: done.contains(i),
            onChanged: (value) {
              setState(() {
                if (value == true) {
                  done.add(i);
                } else {
                  done.remove(i);
                }
              });
            },
            secondary: Icon(routines[i].$3),
            title: Text(routines[i].$1),
            subtitle: Text(routines[i].$2),
          ),
      ],
    );
  }
}

class AdminPage extends StatelessWidget {
  const AdminPage({super.key});

  static const items = [
    (
      'Saúde do Drupal',
      'Status, versão, filas, cron e cache.',
      Icons.monitor_heart_outlined
    ),
    (
      'E-mail institucional',
      'Poste.io/SMTP para avisos editoriais e recuperação de acesso.',
      Icons.mark_email_read_outlined
    ),
    (
      'Backups',
      'Criar, validar e registrar restaurações.',
      Icons.backup_outlined
    ),
    (
      'Atualizações',
      'Composer/Drush com pré-checagem e confirmação.',
      Icons.system_update_alt_outlined
    ),
    (
      'Logs',
      'Erros recentes do Drupal, PHP e servidor web.',
      Icons.receipt_long_outlined
    ),
    (
      'Usuários e papéis',
      'Entrada e saída de bolsistas sem compartilhar senha.',
      Icons.manage_accounts_outlined
    ),
    (
      'Inventário',
      'Módulos, tipos de conteúdo, taxonomias e integrações.',
      Icons.inventory_outlined
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Administração',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 6),
        const Text(
          'Área reservada para coordenação/TI. Ações de infraestrutura ficam separadas do trabalho editorial dos bolsistas.',
        ),
        const SizedBox(height: 20),
        ...items.map(
          (item) {
            final isIdentity = item.$1 == 'Usuários e papéis';
            final openable = isIdentity && AppSession.instance.canAdminUsers;
            return Card(
              child: ListTile(
                leading: Icon(item.$3),
                title: Text(item.$1),
                subtitle: Text(item.$2),
                trailing: openable
                    ? const Icon(Icons.chevron_right)
                    : const Chip(label: Text('controle técnico')),
                onTap: openable
                    ? () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => Scaffold(
                              appBar: AppBar(title: const Text('Identidade')),
                              body: const IdentityPage(),
                            ),
                          ),
                        )
                    : null,
              ),
            );
          },
        ),
      ],
    );
  }
}

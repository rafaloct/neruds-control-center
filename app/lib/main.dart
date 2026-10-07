import 'package:flutter/material.dart';

import 'app_session.dart';
import 'drupal_api.dart';
import 'editorial_page.dart';
import 'identity_page.dart';
import 'mission_page.dart';
import 'opportunities_page.dart';
import 'session_widgets.dart';
import 'workflow_widgets.dart';

void main() => runApp(const NerudsControlApp());

class NerudsControlApp extends StatelessWidget {
  const NerudsControlApp({super.key});

  @override
  Widget build(BuildContext context) {
    const orange = Color(0xFFF58535);
    const gray = Color(0xFF606062);
    const lightGray = Color(0xFFDCDDDF);
    final scheme =
        ColorScheme.fromSeed(
          seedColor: orange,
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xFF434345),
          onPrimary: Colors.white,
          primaryContainer: const Color(0xFFFFDEC7),
          onPrimaryContainer: const Color(0xFF352014),
          secondary: gray,
          onSecondary: Colors.white,
          secondaryContainer: orange,
          onSecondaryContainer: const Color(0xFF292321),
          surface: const Color(0xFFFAFAFA),
          onSurface: const Color(0xFF29292B),
          onSurfaceVariant: const Color(0xFF555557),
          outline: gray,
          outlineVariant: lightGray,
        );
    return MaterialApp(
      title: 'NERUDS · Portal e inventário',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF6F6F7),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          margin: const EdgeInsets.symmetric(vertical: 5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: lightGray),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          alignLabelWithHint: true,
          filled: true,
          fillColor: Colors.white,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
        progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: Color(0xFF434345),
          linearTrackColor: lightGray,
          circularTrackColor: lightGray,
        ),
        navigationRailTheme: const NavigationRailThemeData(
          backgroundColor: Colors.white,
          indicatorColor: Color(0xFFFFDEC7),
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Colors.white,
          indicatorColor: Color(0xFFFFDEC7),
        ),
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
  final Set<int> _visited = {0};
  int index = 0;
  bool _leaving = false;
  late Future<PortalSnapshot> snapshot;

  @override
  void initState() {
    super.initState();
    snapshot = api.loadSnapshot();
    AppSession.instance.addListener(_sessionChanged);
  }

  void _sessionChanged() {
    if (!mounted) return;
    setState(() {
      if (index == 4 && !AppSession.instance.canAdminUsers) index = 0;
    });
  }

  @override
  void dispose() {
    AppSession.instance.removeListener(_sessionChanged);
    super.dispose();
  }

  void refresh() => setState(() => snapshot = api.loadSnapshot());

  void _select(int value) {
    if (_leaving) return;
    setState(() {
      _visited.add(value);
      index = value;
    });
  }

  Future<void> _logout() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    await signOut(context);
    if (mounted) setState(() => _leaving = false);
  }

  @override
  Widget build(BuildContext context) {
    final session = AppSession.instance;
    final epoch = session.identityEpoch;
    final destinations = [
      const NavigationDestination(
        icon: Icon(Icons.home_outlined),
        label: 'Início',
      ),
      const NavigationDestination(
        icon: Icon(Icons.edit_note_outlined),
        label: 'Conteúdo',
      ),
      const NavigationDestination(
        icon: Icon(Icons.inventory_2_outlined),
        label: 'Inventário',
      ),
      const NavigationDestination(
        icon: Icon(Icons.rss_feed_outlined),
        label: 'Oportunidades',
      ),
      if (session.canAdminUsers)
        const NavigationDestination(
          icon: Icon(Icons.manage_accounts_outlined),
          label: 'Administração',
        ),
    ];
    // Lazy first visit, retained afterwards. Identity changes create fresh pages.
    final pages = [
      DashboardPage(snapshot: snapshot, onRefresh: refresh, onSelect: _select),
      if (_visited.contains(1))
        EditorialPage(key: ValueKey('editorial-$epoch'))
      else
        const SizedBox.shrink(),
      if (_visited.contains(2))
        MissionPage(key: ValueKey('mission-$epoch'))
      else
        const SizedBox.shrink(),
      if (_visited.contains(3))
        OpportunitiesPage(key: ValueKey('opportunities-$epoch'))
      else
        const SizedBox.shrink(),
      if (session.canAdminUsers) AdminPage(key: ValueKey('admin-$epoch')),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 960;
        return Scaffold(
          appBar: AppBar(
            title: const Text(
              'NERUDS',
              style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1),
            ),
            actions: [
              if (session.authenticated)
                PopupMenuButton<String>(
                  enabled: !_leaving,
                  tooltip: 'Conta de ${session.username}',
                  onSelected: (_) => _logout(),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      enabled: false,
                      child: Text('Conectado como ${session.username}'),
                    ),
                    const PopupMenuItem(
                      value: 'logout',
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.logout),
                        title: Text('Sair da conta'),
                      ),
                    ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.account_circle_outlined),
                        if (constraints.maxWidth >= 600) ...[
                          const SizedBox(width: 8),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 220),
                            child: Text(
                              session.username ?? '',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                        const Icon(Icons.expand_more),
                      ],
                    ),
                  ),
                )
              else
                TextButton.icon(
                  onPressed: () => showSignInDialog(context),
                  icon: const Icon(Icons.login),
                  label: Text(session.expired ? 'Entrar novamente' : 'Entrar'),
                ),
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            child: Row(
              children: [
                if (wide) ...[
                  NavigationRail(
                    extended: true,
                    minExtendedWidth: 210,
                    selectedIndex: index,
                    onDestinationSelected: _select,
                    leading: const Padding(
                      padding: EdgeInsets.fromLTRB(12, 22, 12, 28),
                      child: Text('Portal e inventário'),
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
                ],
                Expanded(
                  key: const ValueKey('workspace'),
                  child: Stack(
                    children: [
                      ExcludeFocus(
                        excluding: _leaving,
                        child: AbsorbPointer(
                          absorbing: _leaving,
                          child: IndexedStack(index: index, children: pages),
                        ),
                      ),
                      if (_leaving)
                        Positioned.fill(
                          child: ColoredBox(
                            color: const Color(0xE6FFFFFF),
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const CircularProgressIndicator(),
                                  const SizedBox(height: 16),
                                  Text(
                                    'Encerrando a sessão',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: index,
                  onDestinationSelected: _select,
                  destinations: destinations
                      .map(
                        (item) => NavigationDestination(
                          icon: item.icon,
                          label: switch (item.label) {
                            'Oportunidades' => 'Pautas',
                            'Administração' => 'Contas',
                            _ => item.label,
                          },
                          tooltip: item.label,
                        ),
                      )
                      .toList(),
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
    required this.onSelect,
  });

  final Future<PortalSnapshot> snapshot;
  final VoidCallback onRefresh;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final inset = constraints.maxWidth < 600 ? 16.0 : 32.0;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: ListView(
              padding: EdgeInsets.all(inset),
              children: [
                Text(
                  'O trabalho do núcleo, em continuidade',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Cuide do acervo, prepare conteúdos e deixe o próximo passo '
                  'claro para quem continua o trabalho.',
                ),
                const SizedBox(height: 28),
                Card(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.inventory_2_outlined, size: 30),
                        const SizedBox(height: 16),
                        Text(
                          'Continuar o inventário',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Encontre a ficha existente, confira a fonte e registre '
                          'a proposta. Filtre por responsável e tipo de conteúdo '
                          'para escolher sua próxima tarefa.',
                        ),
                        const SizedBox(height: 18),
                        FilledButton.icon(
                          onPressed: () => onSelect(2),
                          icon: const Icon(Icons.arrow_forward),
                          label: const Text('Abrir tarefas do inventário'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (context, inner) {
                    final width = inner.maxWidth >= 700
                        ? (inner.maxWidth - 16) / 2
                        : inner.maxWidth;
                    return Wrap(
                      spacing: 16,
                      runSpacing: 12,
                      children: [
                        SizedBox(
                          width: width,
                          child: _StartCard(
                            icon: Icons.edit_note_outlined,
                            title: 'Preparar uma notícia',
                            description:
                                'Transforme uma atualização, chamada, vaga ou relato '
                                'em texto para revisão. O envio cria um rascunho.',
                            action: 'Abrir conteúdo',
                            onPressed: () => onSelect(1),
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: _StartCard(
                            icon: Icons.rss_feed_outlined,
                            title: 'Examinar oportunidades',
                            description:
                                'Confira a origem e o prazo, registre uma decisão '
                                'e continue a pauta que já foi criada.',
                            action: 'Abrir oportunidades',
                            onPressed: () => onSelect(3),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 24),
                Text(
                  'Um registro que outra pessoa consegue continuar',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Fonte recebida, proposta revisada e página pública conferida '
                  'são etapas diferentes. Registre o que foi feito e o que ainda '
                  'depende de outra pessoa na própria tarefa.',
                ),
                const SizedBox(height: 28),
                FutureBuilder<PortalSnapshot>(
                  future: snapshot,
                  builder: (context, result) {
                    final data = result.data;
                    if (result.connectionState == ConnectionState.waiting) {
                      return const LinearProgressIndicator(
                        semanticsLabel: 'Consultando o portal',
                      );
                    }
                    if (data == null || data.error != null || !data.online) {
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Consulta ao portal indisponível',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                data?.error ??
                                    'Não foi possível consultar o portal. Tente novamente.',
                              ),
                              const SizedBox(height: 8),
                              TextButton.icon(
                                onPressed: onRefresh,
                                icon: const Icon(Icons.refresh),
                                label: const Text('Tentar novamente'),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              'No portal agora',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const Chip(
                              avatar: Icon(
                                Icons.check_circle_outline,
                                size: 18,
                              ),
                              label: Text('Portal disponível'),
                            ),
                            PortalLinkButton(
                              label: 'Abrir portal',
                              url: data.portalUrl,
                            ),
                            IconButton(
                              tooltip: 'Atualizar notícias',
                              onPressed: onRefresh,
                              icon: const Icon(Icons.refresh),
                            ),
                          ],
                        ),
                        if (data.latestNews.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 16),
                            child: Text(
                              'Nenhuma notícia pública foi retornada nesta consulta.',
                            ),
                          ),
                        ...data.latestNews.map(
                          (item) => Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item['title'] ?? 'Sem título',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  if ((item['public_url'] ?? '').isNotEmpty)
                                    PortalLinkButton(
                                      label: 'Ler no portal',
                                      url: item['public_url'],
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StartCard extends StatelessWidget {
  const _StartCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.action,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String description;
  final String action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 28),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(description),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: onPressed, child: Text(action)),
        ],
      ),
    ),
  );
}

class AdminPage extends StatelessWidget {
  const AdminPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Administração',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        const Text(
          'Contas individuais e passagem de responsabilidade ajudam o trabalho '
          'a continuar quando a equipe muda.',
        ),
        const SizedBox(height: 24),
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.all(20),
            leading: const Icon(Icons.manage_accounts_outlined),
            title: const Text('Usuários e papéis'),
            subtitle: const Text(
              'Criar contas extensionistas, recuperar o acesso e encerrar '
              'vínculos com transferência de tarefas.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: !AppSession.instance.canAdminUsers
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: const Text('Equipe e acessos')),
                        body: const IdentityPage(),
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

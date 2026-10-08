import 'package:flutter/material.dart';

import 'app_config.dart';
import 'app_session.dart';
import 'portal_read.dart';
import 'session_widgets.dart';
import 'workflow_widgets.dart';

/// Monitoring tab organized by the portal's real axes (issue #24):
/// projects/actions, events, publications and news — every row is a real
/// node with links to its public view and its Drupal edit form.
class MonitoringPage extends StatefulWidget {
  const MonitoringPage({super.key, required this.onNavigate});

  /// Tab switcher callback (1 = Conteúdo, 2 = Inventário).
  final ValueChanged<int> onNavigate;

  @override
  State<MonitoringPage> createState() => _MonitoringPageState();
}

class _MonitoringPageState extends State<MonitoringPage> {
  final PortalReadApi _api = PortalReadApi();
  MonitoringData? _data;
  bool _loading = false;
  String? _statusFilter;
  String? _kindFilter;
  String? _municipalityFilter;
  String? _eixoFilter;
  String? _linhaFilter;
  String? _odsFilter;

  /// Bundles each role may create — the real permission matrix observed on
  /// the portal: extensionista/pesquisador create noticia+relatorio,
  /// content_editor additionally page; the remaining bundles are
  /// administrator-only.
  static const _createRoles = <String, Set<String>>{
    'noticia': {'extensionista', 'pesquisador', 'content_editor', 'administrator'},
    'relatorio': {'extensionista', 'pesquisador', 'content_editor', 'administrator'},
    'page': {'content_editor', 'administrator'},
    'projeto_pesquisa_extensao': {'administrator'},
    'acao_extensionista': {'administrator'},
    'evento_cientifico': {'administrator'},
    'publicacao_cientifica': {'administrator'},
  };

  static const _fichaLabels = <String, String>{
    'noticia': 'Notícia',
    'relatorio': 'Relatório',
    'page': 'Página',
    'projeto_pesquisa_extensao': 'Projeto de pesquisa e extensão',
    'acao_extensionista': 'Ação extensionista',
    'evento_cientifico': 'Evento científico',
    'publicacao_cientifica': 'Publicação científica',
  };

  bool _canCreate(String bundle) {
    final allowed = _createRoles[bundle] ?? const <String>{};
    return AppSession.instance.roles.any(allowed.contains);
  }

  @override
  void initState() {
    super.initState();
    AppSession.instance.addListener(_sessionChanged);
    _reload();
  }

  @override
  void dispose() {
    AppSession.instance.removeListener(_sessionChanged);
    super.dispose();
  }

  void _sessionChanged() {
    if (mounted) _reload();
  }

  Future<void> _reload() async {
    final session = AppSession.instance;
    if (!session.authenticated) {
      setState(() {
        _data = null;
        _loading = false;
      });
      return;
    }
    final epoch = session.identityEpoch;
    final token = session.token;
    setState(() => _loading = true);
    final data = await _api.loadMonitoring();
    if (!mounted ||
        AppSession.instance.identityEpoch != epoch ||
        AppSession.instance.token != token) {
      return;
    }
    setState(() {
      _data = data;
      _loading = false;
      _reconcileFilters(data);
    });
  }

  /// Drops saved filters whose terms vanished from the refreshed board —
  /// otherwise a stale selection would silently hide every row.
  void _reconcileFilters(MonitoringData data) {
    final board = data.projetos.data;
    if (board == null) return;
    String? keep(Set<String> terms, String? value) =>
        terms.contains(value) ? value : null;
    _statusFilter = keep(
      {for (final p in board.projects) ...p.status},
      _statusFilter,
    );
    _kindFilter = keep(
      {
        for (final p in board.projects) ...p.kind,
        for (final a in board.actions) ...a.kind,
      },
      _kindFilter,
    );
    _municipalityFilter = keep(
      {for (final a in board.actions) ...a.municipality},
      _municipalityFilter,
    );
    _eixoFilter = keep(
      {for (final p in board.projects) ...p.eixos},
      _eixoFilter,
    );
    _linhaFilter = keep(
      {for (final p in board.projects) ...p.linhas},
      _linhaFilter,
    );
    _odsFilter = keep(
      {for (final p in board.projects) ...p.ods},
      _odsFilter,
    );
  }

  String _stamp(String? iso) {
    if (iso == null) return '';
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return '';
    final local = parsed.toLocal();
    final d = local.day.toString().padLeft(2, '0');
    final m = local.month.toString().padLeft(2, '0');
    final h = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    return 'Dados de $d/$m às $h:$min';
  }

  String _when(PortalEvent event) {
    final days = event.daysUntil;
    if (days == null) return 'sem data';
    if (days == 0) return 'hoje';
    if (days == 1) return 'amanhã';
    if (days > 1) return 'em $days dias';
    return 'há ${-days} dias';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = AppSession.instance;

    if (!session.authenticated) {
      return Card(
        margin: const EdgeInsets.all(24),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Monitoramento', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text(
                'Entre com sua conta para acompanhar projetos, eventos, '
                'publicações e notícias do portal.',
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => showSignInDialog(context),
                icon: const Icon(Icons.login),
                label: const Text('Entrar com minha conta'),
              ),
            ],
          ),
        ),
      );
    }

    final data = _data;
    return DefaultTabController(
      length: 4,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('Monitoramento', style: theme.textTheme.headlineSmall),
                if (data?.fetchedAt != null)
                  Chip(
                    avatar: const Icon(Icons.schedule, size: 16),
                    label: Text(_stamp(data!.fetchedAt)),
                  ),
                _newFichaMenu(context),
                IconButton(
                  tooltip: 'Atualizar monitoramento',
                  onPressed: _loading ? null : _reload,
                  icon: _loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            const TabBar(
              tabs: [
                Tab(text: 'Projetos e ações'),
                Tab(text: 'Eventos'),
                Tab(text: 'Publicações'),
                Tab(text: 'Notícias'),
              ],
            ),
            Expanded(
              child: data == null
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(
                      children: [
                        _projectsTab(data),
                        _eventsTab(data),
                        _gapsTab(
                          data,
                          result: data.publicacoes,
                          listingUrl: data.publicacoesListingUrl,
                          listingLabel: 'Publicações no portal',
                          feedSection: 'publicacoes',
                          showDuplicates: true,
                        ),
                        _gapsTab(
                          data,
                          result: data.noticias,
                          listingUrl: data.noticiasListingUrl,
                          listingLabel: 'Notícias no portal',
                          feedSection: 'noticias',
                          showDuplicates: true,
                          extraAction: TextButton.icon(
                            onPressed: () => widget.onNavigate(1),
                            icon: const Icon(Icons.edit_note_outlined, size: 18),
                            label: const Text('Preparar notícia no app'),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _newFichaMenu(BuildContext context) {
    return MenuAnchor(
      builder: (context, controller, _) => OutlinedButton.icon(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.add_outlined, size: 18),
        label: const Text('Nova ficha'),
      ),
      menuChildren: [
        for (final entry in _fichaLabels.entries)
          _FichaMenuItem(
            label: entry.value,
            bundle: entry.key,
            enabled: _canCreate(entry.key),
            hostContext: context,
          ),
      ],
    );
  }

  Widget _sectionError(String error) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
    ),
  );

  Widget _linkRow(List<Widget> buttons) => Wrap(
    spacing: 4,
    runSpacing: 4,
    children: buttons,
  );

  Widget _projectsTab(MonitoringData data) {
    final result = data.projetos;
    if (!result.ok) return ListView(children: [_sectionError(result.error!)]);
    final board = result.data!;
    final gaps = data.gapsByNode();
    final gapErrors = [
      data.projetoGaps.error,
      data.acaoGaps.error,
    ].whereType<String>().toList();

    final statusTerms = <String>{
      for (final p in board.projects) ...p.status,
    };
    final kindTerms = <String>{
      for (final p in board.projects) ...p.kind,
      for (final a in board.actions) ...a.kind,
    };
    final municipalityTerms = <String>{
      for (final a in board.actions) ...a.municipality,
    };
    final eixoTerms = <String>{
      for (final p in board.projects) ...p.eixos,
    };
    final linhaTerms = <String>{
      for (final p in board.projects) ...p.linhas,
    };
    final odsTerms = <String>{
      for (final p in board.projects) ...p.ods,
    };

    final projects = board.projects.where((p) {
      if (_statusFilter != null && !p.status.contains(_statusFilter)) {
        return false;
      }
      if (_kindFilter != null && !p.kind.contains(_kindFilter)) return false;
      if (_eixoFilter != null && !p.eixos.contains(_eixoFilter)) return false;
      if (_linhaFilter != null && !p.linhas.contains(_linhaFilter)) {
        return false;
      }
      if (_odsFilter != null && !p.ods.contains(_odsFilter)) return false;
      return true;
    }).toList();
    final actions = board.actions.where((a) {
      if (_kindFilter != null && !a.kind.contains(_kindFilter)) return false;
      if (_municipalityFilter != null &&
          !a.municipality.contains(_municipalityFilter)) {
        return false;
      }
      return true;
    }).toList();

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const SizedBox(height: 12),
        _linkRow([
          PortalLinkButton(label: 'Todos os projetos', url: board.listingUrl),
          PortalLinkButton(label: 'Mapa de projetos', url: board.mapUrl),
        ]),
        if (statusTerms.isNotEmpty ||
            kindTerms.isNotEmpty ||
            municipalityTerms.isNotEmpty ||
            eixoTerms.isNotEmpty ||
            linhaTerms.isNotEmpty ||
            odsTerms.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (statusTerms.isNotEmpty)
                  _filterMenu(
                    label: 'Status',
                    options: statusTerms.toList()..sort(),
                    value: _statusFilter,
                    onChanged: (v) => setState(() => _statusFilter = v),
                  ),
                if (kindTerms.isNotEmpty)
                  _filterMenu(
                    label: 'Tipo',
                    options: kindTerms.toList()..sort(),
                    value: _kindFilter,
                    onChanged: (v) => setState(() => _kindFilter = v),
                  ),
                if (municipalityTerms.isNotEmpty)
                  _filterMenu(
                    label: 'Município',
                    options: municipalityTerms.toList()..sort(),
                    value: _municipalityFilter,
                    onChanged: (v) =>
                        setState(() => _municipalityFilter = v),
                  ),
                if (eixoTerms.isNotEmpty)
                  _filterMenu(
                    label: 'Eixo temático',
                    options: eixoTerms.toList()..sort(),
                    value: _eixoFilter,
                    onChanged: (v) => setState(() => _eixoFilter = v),
                  ),
                if (linhaTerms.isNotEmpty)
                  _filterMenu(
                    label: 'Linha de pesquisa',
                    options: linhaTerms.toList()..sort(),
                    value: _linhaFilter,
                    onChanged: (v) => setState(() => _linhaFilter = v),
                  ),
                if (odsTerms.isNotEmpty)
                  _filterMenu(
                    label: 'ODS',
                    options: odsTerms.toList()..sort(),
                    value: _odsFilter,
                    onChanged: (v) => setState(() => _odsFilter = v),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        if (gapErrors.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Lacunas indisponíveis: ${gapErrors.join(' ')}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          )
        else if (data.projetoGaps.data?.truncated == true ||
            data.acaoGaps.data?.truncated == true)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Lacunas exibidas em amostra — fichas além do limite '
              'podem ter campos ausentes não listados.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        Text(
          'Projetos (${projects.length})',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        if (projects.isEmpty)
          const Text('Nenhum projeto com os filtros atuais.')
        else
          for (final p in projects)
            Card(
              child: ListTile(
                title: Text(p.title),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      [
                        if ((p.coordinator ?? '').isNotEmpty)
                          'Coord.: ${p.coordinator}',
                        if ((p.start ?? '').isNotEmpty)
                          'início ${p.start}',
                        if ((p.end ?? '').isNotEmpty) 'fim ${p.end}',
                      ].join(' · '),
                    ),
                    _gapsLine(gaps[p.nid]),
                    if (p.status.isNotEmpty || p.kind.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (final s in p.status)
                              Chip(
                                label: Text(s),
                                visualDensity: VisualDensity.compact,
                              ),
                            for (final k in p.kind)
                              Chip(
                                label: Text(k),
                                visualDensity: VisualDensity.compact,
                                avatar: const Icon(
                                  Icons.category_outlined,
                                  size: 14,
                                ),
                              ),
                          ],
                        ),
                      ),
                    _linkRow([
                      PortalLinkButton(label: 'Ver', url: p.viewUrl),
                      PortalLinkButton(
                        label: 'Editar',
                        url: p.editUrl,
                        editing: true,
                      ),
                      if (gaps[p.nid] != null) _gapTaskButton(gaps[p.nid]!),
                    ]),
                  ],
                ),
              ),
            ),
        const SizedBox(height: 16),
        Text(
          'Ações extensionistas (${actions.length})',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        if (actions.isEmpty)
          const Text('Nenhuma ação extensionista com os filtros atuais.')
        else
          for (final a in actions)
            Card(
              child: ListTile(
                title: Text(a.title),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      [
                        if ((a.local ?? '').isNotEmpty) a.local!,
                        if (a.participants != null)
                          '${a.participants} participantes',
                        ...a.municipality,
                        ...a.kind,
                      ].join(' · '),
                    ),
                    _gapsLine(gaps[a.nid]),
                    _linkRow([
                      PortalLinkButton(label: 'Ver', url: a.viewUrl),
                      PortalLinkButton(
                        label: 'Editar',
                        url: a.editUrl,
                        editing: true,
                      ),
                      if (gaps[a.nid] != null) _gapTaskButton(gaps[a.nid]!),
                    ]),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  Widget _filterMenu({
    required String label,
    required List<String> options,
    required String? value,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownMenu<String?>(
      initialSelection: value,
      label: Text(label),
      dropdownMenuEntries: [
        DropdownMenuEntry(value: null, label: 'Todos'),
        for (final option in options)
          DropdownMenuEntry(value: option, label: option),
      ],
      onSelected: onChanged,
    );
  }

  Widget _eventsTab(MonitoringData data) {
    final result = data.eventos;
    if (!result.ok) return ListView(children: [_sectionError(result.error!)]);
    final events = result.data!;
    final gaps = data.gapsByNode();
    final upcoming = events
        .where((e) => !e.past && e.daysUntil != null)
        .toList()
      ..sort((a, b) => a.daysUntil!.compareTo(b.daysUntil!));
    final undated = events
        .where((e) => !e.past && e.daysUntil == null)
        .toList();
    final past = events.where((e) => e.past).toList();

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const SizedBox(height: 12),
        _linkRow([
          PortalLinkButton(
            label: 'Todos os eventos',
            url: data.eventsListingUrl,
          ),
        ]),
        const SizedBox(height: 12),
        if (data.eventoGaps.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Lacunas indisponíveis: ${data.eventoGaps.error}',
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          )
        else if (data.eventoGaps.data?.truncated == true)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Lacunas exibidas em amostra — fichas além do limite '
              'podem ter campos ausentes não listados.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (upcoming.isEmpty && undated.isEmpty && past.isEmpty)
          const Text('Nenhum evento registrado no portal.'),
        if (upcoming.isNotEmpty) ...[
          Text('Próximos', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          for (final e in upcoming) _eventTile(e, gaps),
        ],
        if (undated.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'Sem data registrada',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          for (final e in undated) _eventTile(e, gaps),
        ],
        if (past.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'Encerrados',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          for (final e in past) _eventTile(e, gaps),
        ],
      ],
    );
  }

  Widget _gapsLine(GapNode? gap) {
    final missing = gap?.missing;
    if (missing == null || missing.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        'Faltam: ${missing.join(', ')}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  /// A real portal gap becomes a mission task (issue #25): the task
  /// remembers the node and the missing fields so it can be reconciled
  /// against the portal later.
  Widget _gapTaskButton(GapNode node) {
    if (node.nid == null) return const SizedBox.shrink();
    return TextButton.icon(
      key: ValueKey('gap-task-${node.nid}'),
      onPressed: () => _createGapTask(node),
      icon: const Icon(Icons.playlist_add, size: 18),
      label: const Text('Criar tarefa'),
    );
  }

  Future<void> _createGapTask(GapNode node) async {
    List<MissionRef> missions;
    try {
      missions = await _api.listMissions();
    } catch (error) {
      _message(workflowError(error));
      return;
    }
    if (!mounted) return;
    if (missions.isEmpty) {
      _message('Nenhuma missão disponível para receber a tarefa.');
      return;
    }
    var missionId = missions.first.id;
    final title = TextEditingController(
      text: 'Completar ficha — ${node.title}',
    );
    final responsible = TextEditingController(
      text: AppSession.instance.username ?? '',
    );
    final action = TextEditingController(
      text: 'Abrir a ficha no portal e completar os campos ausentes.',
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Criar tarefa a partir da lacuna'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Ficha: ${node.title}'),
                Text(
                  'Faltam: ${node.missing.join(', ')}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: missionId,
                  decoration: const InputDecoration(labelText: 'Missão'),
                  items: [
                    for (final mission in missions)
                      DropdownMenuItem(
                        value: mission.id,
                        child: Text(mission.title),
                      ),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => missionId = value ?? missionId),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: title,
                  decoration: const InputDecoration(labelText: 'Título'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: responsible,
                  decoration: const InputDecoration(
                    labelText: 'Responsável',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: action,
                  decoration: const InputDecoration(
                    labelText: 'Próxima ação',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              key: const ValueKey('gap-task-confirm'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Criar tarefa'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (confirmed != true) {
      title.dispose();
      responsible.dispose();
      action.dispose();
      return;
    }
    try {
      await _api.createGapTask(
        missionId,
        node: node,
        title: title.text.trim().isEmpty
            ? 'Completar ficha — ${node.title}'
            : title.text.trim(),
        responsible: responsible.text.trim(),
        action: action.text.trim(),
      );
      _message('Tarefa criada na missão — acompanhe na aba Inventário.');
    } catch (error) {
      _message(workflowError(error));
    } finally {
      title.dispose();
      responsible.dispose();
      action.dispose();
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Shared-DOI groups flagged by the bridge — shown as a review signal,
  /// never merged or acted on automatically.
  Widget _duplicatesCard(List<DuplicateGroup> groups) {
    if (groups.isEmpty) return const SizedBox.shrink();
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Possível duplicidade de DOI — conferir no portal',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            for (final group in groups)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'DOI ${group.doi} aparece em ${group.nodes.length} fichas '
                      '(${group.nodes.map((n) => n.typeLabel).toSet().join(', ')}).',
                    ),
                    _linkRow([
                      for (final node in group.nodes)
                        PortalLinkButton(
                          label: node.title,
                          url: node.viewUrl,
                        ),
                    ]),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _eventTile(PortalEvent event, Map<int, GapNode> gaps) => Card(
    child: ListTile(
      title: Text(event.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              _when(event),
              if (!event.published) 'rascunho',
              if ((event.local ?? '').isNotEmpty) event.local!,
              if (event.callOpen == true) 'chamada aberta',
            ].join(' · '),
          ),
          _gapsLine(gaps[event.nid]),
          _linkRow([
            if ((event.signupUrl ?? '').isNotEmpty)
              PortalLinkButton(label: 'Inscrição', url: event.signupUrl),
            if ((event.submissionUrl ?? '').isNotEmpty &&
                event.callOpen != false)
              PortalLinkButton(label: 'Submissão', url: event.submissionUrl),
            PortalLinkButton(label: 'Ver', url: event.viewUrl),
            PortalLinkButton(
              label: 'Editar',
              url: event.editUrl,
              editing: true,
            ),
            if (gaps[event.nid] != null) _gapTaskButton(gaps[event.nid]!),
          ]),
        ],
      ),
    ),
  );

  Widget _gapsTab(
    MonitoringData data, {
    required SectionResult<GapReport> result,
    required String? listingUrl,
    required String listingLabel,
    required String feedSection,
    Widget? extraAction,
    bool showDuplicates = false,
  }) {
    final report = result.data;
    final nodes = report?.nodes ?? const <GapNode>[];
    final feed = data.feeds;
    final latest = (feed.data?.items ?? const <FeedItem>[])
        .where((i) => i.section == feedSection)
        .take(5)
        .toList();

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const SizedBox(height: 12),
        _linkRow([
          PortalLinkButton(label: listingLabel, url: listingUrl),
          ?extraAction,
        ]),
        if (showDuplicates && data.duplicates.ok)
          _duplicatesCard(data.duplicates.data!),
        const SizedBox(height: 12),
        Text(
          result.ok
              ? 'Fichas com lacunas (${nodes.length}'
                  '${report!.truncated ? ' ou mais' : ''})'
              : 'Fichas com lacunas',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        if (!result.ok)
          Text(
            result.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          )
        else if (nodes.isEmpty)
          const Text('Nenhum campo monitorado ausente nesta consulta.')
        else
          for (final node in nodes)
            Card(
              child: ListTile(
                title: Text(node.title),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Faltam: ${node.missing.join(', ')}'),
                    _linkRow([
                      PortalLinkButton(label: 'Ver', url: node.viewUrl),
                      PortalLinkButton(
                        label: 'Editar',
                        url: node.editUrl,
                        editing: true,
                      ),
                      _gapTaskButton(node),
                    ]),
                  ],
                ),
              ),
            ),
        const SizedBox(height: 16),
        Text(
          'Últimas publicadas',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        if (!feed.ok)
          Text(
            feed.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          )
        else if (feed.data!.failedSections.contains(feedSection))
          Text(
            'A seção $feedSection não respondeu nesta consulta.',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          )
        else if (latest.isEmpty)
          const Text('Nenhum item recente nesta seção.')
        else
          for (final item in latest)
            Card(
              child: ListTile(
                dense: true,
                title: Text(item.title),
                trailing: PortalLinkButton(label: 'Abrir', url: item.link),
              ),
            ),
      ],
    );
  }
}

/// One entry in the "Nova ficha" menu — opens the real Drupal add form;
/// disabled when the signed-in roles cannot create that bundle.
class _FichaMenuItem extends StatelessWidget {
  const _FichaMenuItem({
    required this.label,
    required this.bundle,
    required this.enabled,
    required this.hostContext,
  });

  final String label;
  final String bundle;
  final bool enabled;

  /// Live context from the page — menu item contexts are deactivated when
  /// the menu closes, before the deferred callback runs.
  final BuildContext hostContext;

  @override
  Widget build(BuildContext context) {
    return MenuItemButton(
      onPressed: enabled ? () => _openForm(hostContext) : null,
      child: Row(
        children: [
          Expanded(child: Text(label)),
          if (!enabled)
            const Tooltip(
              message: 'Sua conta não cria este tipo de ficha',
              child: Icon(Icons.lock_outline, size: 16),
            ),
        ],
      ),
    );
  }

  Future<void> _openForm(BuildContext context) async {
    // The portal address may arrive asynchronously from /portal/snapshot —
    // resolve it at tap time, not when the menu was built.
    final portal = AppConfig.portalUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = portal.isEmpty
        ? null
        : AppConfig.webUri('$portal/node/add/$bundle');
    if (uri == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'O endereço do portal ainda não foi descoberto. '
              'Tente novamente em instantes.',
            ),
          ),
        );
      }
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Nova ficha de $label'),
        content: const Text(
          'O formulário de cadastro do portal será aberto no navegador. '
          'Entre com sua conta do portal; ela determina os campos '
          'disponíveis. Depois de salvar, vincule a ficha criada à tarefa '
          'correspondente pelo endereço da página.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Voltar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Abrir formulário'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await launchExternalUri(context, uri);
  }
}

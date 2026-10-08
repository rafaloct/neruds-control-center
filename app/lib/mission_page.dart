import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'app_config.dart';
import 'bridge_http.dart' as http;
import 'portal_read.dart' show missionBoardChanged;
import 'session_widgets.dart';
import 'unsaved_work.dart';
import 'workflow_widgets.dart';

import 'app_session.dart';

Uri _uri(String path, [Map<String, String>? query]) =>
    AppConfig.endpoint(path).replace(queryParameters: query);

String _error(http.Response response) {
  try {
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final detail = data['detail'];
    if (detail is Map && detail['message'] != null) {
      return detail['message'].toString();
    }
    return detail?.toString() ?? 'Não foi possível concluir a solicitação.';
  } catch (_) {
    return 'Não foi possível concluir a solicitação (HTTP ${response.statusCode}).';
  }
}

String _nextAction(Map<String, dynamic> task) {
  switch (task['current_stage']) {
    case 'Em pesquisa':
      return 'Registre a fonte e o que ela comprova.';
    case 'Evidência registrada':
      return 'Organize a proposta de atualização para revisão.';
    case 'Revisão cruzada':
      return 'Compare a proposta com a fonte e registre a revisão.';
    case 'Aguardando validação':
      return 'Registre a validação e os ajustes ainda necessários.';
    case 'Conferência pública':
      return 'Abra a página pública e confira o resultado.';
    case 'Concluído':
      return 'Consulte as evidências e o histórico desta verificação.';
    case 'Bloqueado':
      return 'Registre o bloqueio e a informação necessária para retomar.';
    default:
      return 'Leia a lacuna e confirme onde pesquisar.';
  }
}

class MissionPage extends StatefulWidget {
  const MissionPage({super.key});

  @override
  State<MissionPage> createState() => _MissionPageState();
}

class _MissionPageState extends State<MissionPage> {
  final search = TextEditingController();
  bool loading = false;
  bool checkingUrls = false;
  Map<String, dynamic>? dashboard;
  Map<String, dynamic>? automation;
  List<Map<String, dynamic>> tasks = const [];
  List<Map<String, dynamic>> workItems = const [];
  List<Map<String, dynamic>> savedFilters = const [];
  String? stage;
  String? priority;
  String? dueStatus;
  String? owner;
  String? contentType;
  int? missionId;
  int totalTasks = 0;
  int _loadGeneration = 0;
  String? loadError;
  List<Map<String, dynamic>> missions = const [];

  String _missionPath(String suffix) => '/missions/$missionId/$suffix';

  List<String> get workflow => (dashboard?['workflow'] as List? ?? stages)
      .map((value) => value.toString())
      .toList();

  static const stages = [
    'Triagem',
    'Em pesquisa',
    'Evidência registrada',
    'Revisão cruzada',
    'Aguardando validação',
    'Conferência pública',
    'Concluído',
    'Bloqueado',
  ];

  @override
  void initState() {
    super.initState();
    AppSession.instance.addListener(_sessionChanged);
    missionBoardChanged.addListener(_missionDataChanged);
    if (AppSession.instance.authenticated) _load();
  }

  @override
  void dispose() {
    AppSession.instance.removeListener(_sessionChanged);
    missionBoardChanged.removeListener(_missionDataChanged);
    search.dispose();
    super.dispose();
  }

  void _missionDataChanged() {
    if (mounted && AppSession.instance.authenticated) _load();
  }

  void _sessionChanged() {
    if (!mounted) return;
    if (AppSession.instance.authenticated) {
      _load();
    } else {
      _loadGeneration++;
      setState(() {
        loading = false;
        dashboard = null;
        automation = null;
        tasks = const [];
        workItems = const [];
        savedFilters = const [];
        missions = const [];
        missionId = null;
        loadError = null;
      });
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _load({bool append = false}) async {
    if (!AppSession.instance.authenticated) return;
    final generation = ++_loadGeneration;
    final identity = AppSession.instance.identityEpoch;
    setState(() {
      loading = true;
      loadError = null;
    });
    try {
      if (missions.isEmpty) {
        final response = await http.get(
          _uri('/missions'),
          headers: AppSession.instance.authHeaders,
        );
        if (response.statusCode != 200) throw Exception(_error(response));
        final list = (jsonDecode(utf8.decode(response.bodyBytes)) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        if (!mounted ||
            generation != _loadGeneration ||
            identity != AppSession.instance.identityEpoch) {
          return;
        }
        missions = list;
        if (list.isEmpty) {
          setState(() {
            missionId = null;
            dashboard = null;
            tasks = const [];
            workItems = const [];
            totalTasks = 0;
          });
          return;
        }
        if (!list.any((m) => m['id'] == missionId)) {
          missionId = (list.first['id'] as num).toInt();
        }
      }

      final query = <String, String>{
        'limit': '50',
        'offset': append ? tasks.length.toString() : '0',
      };
      if (stage != null) query['stage'] = stage!;
      if (priority != null) query['priority'] = priority!;
      if (dueStatus != null) query['due_status'] = dueStatus!;
      if (owner != null) query['owner'] = owner!;
      if (contentType != null) query['content_type'] = contentType!;
      if (search.text.trim().isNotEmpty) query['q'] = search.text.trim();
      final responses = await Future.wait([
        http.get(
          _uri(_missionPath('dashboard')),
          headers: AppSession.instance.authHeaders,
        ),
        http.get(
          _uri(_missionPath('tasks'), query),
          headers: AppSession.instance.authHeaders,
        ),
        http.get(
          _uri(_missionPath('work-items')),
          headers: AppSession.instance.authHeaders,
        ),
        http.get(
          _uri(_missionPath('saved-filters')),
          headers: AppSession.instance.authHeaders,
        ),
      ]);
      for (final response in responses) {
        if (response.statusCode != 200) throw Exception(_error(response));
      }
      if (!mounted ||
          generation != _loadGeneration ||
          identity != AppSession.instance.identityEpoch) {
        return;
      }
      final taskPayload = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(responses[1].bodyBytes)),
      );
      final loadedTasks = (taskPayload['items'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final workPayload = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(responses[2].bodyBytes)),
      );
      setState(() {
        dashboard = Map<String, dynamic>.from(
          jsonDecode(utf8.decode(responses[0].bodyBytes)),
        );
        tasks = append ? [...tasks, ...loadedTasks] : loadedTasks;
        totalTasks = (taskPayload['total'] as num?)?.toInt() ?? tasks.length;
        workItems = (workPayload['items'] as List? ?? const [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        savedFilters = (jsonDecode(utf8.decode(responses[3].bodyBytes)) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      });
      await _loadAutomation();
    } catch (error) {
      if (mounted && generation == _loadGeneration) {
        setState(() => loadError = workflowError(error));
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> _loadAutomation() async {
    if (!AppSession.instance.authenticated || missionId == null) return;
    final selectedMission = missionId;
    final generation = _loadGeneration;
    try {
      final response = await http.get(
        _uri(_missionPath('automation')),
        headers: AppSession.instance.authHeaders,
      );
      if (response.statusCode == 200 &&
          mounted &&
          selectedMission == missionId &&
          generation == _loadGeneration) {
        setState(() {
          automation = Map<String, dynamic>.from(
            jsonDecode(utf8.decode(response.bodyBytes)),
          );
        });
      }
    } catch (_) {
      // Automação é opcional: bridges antigas sem o endpoint não quebram a tela.
    }
  }

  Future<void> _runUrlCheck() async {
    setState(() => checkingUrls = true);
    try {
      final response = await http.post(
        _uri(_missionPath('url-check'), {'limit': '25'}),
        headers: AppSession.instance.authHeaders,
      );
      if (response.statusCode != 200) {
        _message(_error(response));
        return;
      }
      final data = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)),
      );
      _message(
        'Verificação concluída: ${data['checked']} URLs testadas, '
        '${data['broken']} com problema.',
      );
      await _loadAutomation();
    } catch (e) {
      _message(workflowError(e));
    } finally {
      if (mounted) setState(() => checkingUrls = false);
    }
  }

  Future<void> _showIssueList(
    String title,
    List<Map<String, dynamic>> items,
    String Function(Map<String, dynamic>) subtitle,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: items.isEmpty
              ? const Text('Nada encontrado.')
              : ListView(
                  shrinkWrap: true,
                  children: items
                      .map(
                        (item) => ListTile(
                          dense: true,
                          title: Text(
                            item['title']?.toString() ?? 'Sem título',
                          ),
                          subtitle: Text(subtitle(item)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            Navigator.pop(context);
                            final id = item['task_id'] ?? item['id'];
                            if (id is int) _openTask(id);
                          },
                        ),
                      )
                      .toList(),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  Future<void> _openTask(int id) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => MissionTaskDialog(taskId: id, workflow: workflow),
    );
    if (changed == true) _load();
  }

  Future<void> _openWorkItem(int id) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => MissionWorkItemDialog(workItemId: id),
    );
    if (changed == true) _load();
  }

  Future<void> _saveCurrentFilter() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Salvar filtros'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Nome do filtro',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;

    final filters = <String, String>{};
    if (priority != null) filters['priority'] = priority!;
    if (stage != null) filters['stage'] = stage!;
    if (dueStatus != null) filters['due_status'] = dueStatus!;
    if (owner != null) filters['owner'] = owner!;
    if (contentType != null) filters['content_type'] = contentType!;
    if (search.text.trim().isNotEmpty) filters['q'] = search.text.trim();
    try {
      final response = await http.post(
        _uri(_missionPath('saved-filters')),
        headers: AppSession.instance.authHeaders,
        body: jsonEncode({'name': name, 'filters': filters}),
      );
      if (response.statusCode != 200) throw Exception(_error(response));
      _message('Seleção salva para sua conta.');
      await _load();
    } catch (error) {
      _message(workflowError(error));
    }
  }

  void _applySavedFilter(Map<String, dynamic> saved) {
    final filters = Map<String, dynamic>.from(saved['filters'] as Map? ?? {});
    setState(() {
      priority = filters['priority']?.toString();
      stage = filters['stage']?.toString();
      dueStatus = filters['due_status']?.toString();
      owner = filters['owner']?.toString();
      contentType = filters['content_type']?.toString();
      search.text = filters['q']?.toString() ?? '';
    });
    _load();
  }

  Future<void> _showWeeklyReport() async {
    try {
      final response = await http.get(
        _uri(_missionPath('weekly-report')),
        headers: AppSession.instance.authHeaders,
      );
      if (response.statusCode != 200) {
        _message(_error(response));
        return;
      }
      final report = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)),
      );
      final summary = Map<String, dynamic>.from(
        report['summary'] as Map? ?? {},
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Relatório semanal'),
          content: Text(
            'Progresso: ${summary['overall_concluded'] ?? 0}/${summary['overall_total'] ?? 0}\n'
            'Atrasados: ${summary['overdue'] ?? 0}\n'
            'Próximos 7 dias: ${summary['upcoming'] ?? 0}\n'
            'Eventos na semana: ${(report['recent_events'] as List? ?? const []).length}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Fechar'),
            ),
          ],
        ),
      );
    } catch (error) {
      _message(workflowError(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppSession.instance,
      builder: (context, _) {
        if (!AppSession.instance.authenticated) {
          return const SessionPrompt(
            title: 'Entre para acompanhar o trabalho do núcleo',
            message:
                'A conta do portal identifica quem registrou fontes, '
                'evidências e revisões. Você pode continuar de qualquer computador autorizado.',
          );
        }
        return _content(context);
      },
    );
  }

  Widget _content(BuildContext context) {
    final data = dashboard;
    if (data == null) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Trabalho do núcleo',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 16),
          if (loading) const LinearProgressIndicator(),
          if (!loading)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loadError ?? 'Nenhuma missão disponível para esta conta.',
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      key: const ValueKey('mission-retry'),
                      onPressed: () => _load(),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Tentar novamente'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    }
    final owners =
        (data['by_owner'] as Map? ?? {}).keys
            .map((value) => value.toString())
            .toList()
          ..sort();
    final types =
        (data['by_type'] as Map? ?? {}).keys
            .map((value) => value.toString())
            .toList()
          ..sort();
    final stages = workflow;
    final total = (data['overall_total'] as num?)?.toInt() ?? 0;
    final concluded = (data['overall_concluded'] as num?)?.toInt() ?? 0;
    final progress = total == 0 ? 0.0 : (concluded / total).clamp(0.0, 1.0);
    return RefreshIndicator(
      onRefresh: () => _load(),
      child: ListView(
        key: const PageStorageKey('mission-workspace'),
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Trabalho do núcleo',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 6),
          Text(data['title']?.toString() ?? 'Verificações do portal'),
          const SizedBox(height: 8),
          const Text(
            'Escolha uma frente, confira a lacuna e registre a evidência. '
            'Responsáveis organizam o trabalho; as permissões continuam definidas no portal.',
          ),
          if (missions.length > 1) ...[
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              key: ValueKey('mission-selector-$missionId'),
              initialValue: missionId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Missão'),
              items: missions
                  .map(
                    (mission) => DropdownMenuItem(
                      value: (mission['id'] as num).toInt(),
                      child: Text(
                        mission['title']?.toString() ?? 'Missão',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: loading
                  ? null
                  : (value) {
                      setState(() {
                        missionId = value;
                        dashboard = null;
                        automation = null;
                        tasks = const [];
                        owner = null;
                        contentType = null;
                        stage = null;
                        priority = null;
                        dueStatus = null;
                        search.clear();
                      });
                      _load();
                    },
            ),
          ],
          const SizedBox(height: 20),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _Metric('Registros concluídos', '$concluded / $total'),
              _Metric('Verificações do portal', '${data['total_tasks'] ?? 0}'),
              _Metric('Prazo vencido', '${data['overdue'] ?? 0}'),
              _Metric('Próximos 7 dias', '${data['upcoming'] ?? 0}'),
            ],
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: progress,
            minHeight: 8,
            borderRadius: BorderRadius.circular(20),
          ),
          const SizedBox(height: 6),
          Text(
            '${(progress * 100).toStringAsFixed(0)}% da missão registrado como concluído',
          ),
          const SizedBox(height: 20),
          Text(
            'Encontre sua frente',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('mission-search'),
            controller: search,
            onSubmitted: (_) => _load(),
            decoration: InputDecoration(
              labelText: 'Buscar por título, lacuna ou ação',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                tooltip: 'Buscar verificações',
                onPressed: loading ? null : () => _load(),
                icon: const Icon(Icons.arrow_forward),
              ),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _filter(
                label: 'Responsável',
                value: owner,
                values: owners,
                fieldKey: 'mission-owner',
                empty: 'Todos os responsáveis',
                onChanged: (value) {
                  owner = value;
                  _load();
                },
              ),
              _filter(
                label: 'Tipo de conteúdo',
                value: contentType,
                values: types,
                fieldKey: 'mission-content-type',
                empty: 'Todas as frentes',
                onChanged: (value) {
                  contentType = value;
                  _load();
                },
              ),
              _filter(
                label: 'Etapa',
                value: stage,
                values: stages,
                fieldKey: 'mission-stage',
                empty: 'Todas as etapas',
                onChanged: (value) {
                  stage = value;
                  _load();
                },
              ),
              _filter(
                label: 'Prioridade',
                value: priority,
                values: const ['P0', 'P1', 'P2'],
                fieldKey: 'mission-priority',
                empty: 'Todas',
                onChanged: (value) {
                  priority = value;
                  _load();
                },
              ),
              _filter(
                label: 'Prazo',
                value: dueStatus,
                values: const ['overdue', 'upcoming'],
                labels: const {
                  'overdue': 'Prazo vencido',
                  'upcoming': 'Próximos 7 dias',
                },
                fieldKey: 'mission-deadline',
                empty: 'Todos os prazos',
                onChanged: (value) {
                  dueStatus = value;
                  _load();
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: loading ? null : _saveCurrentFilter,
                icon: const Icon(Icons.bookmark_add_outlined),
                label: const Text('Guardar esta seleção'),
              ),
              if (savedFilters.isNotEmpty)
                PopupMenuButton<Map<String, dynamic>>(
                  tooltip: 'Aplicar seleção salva',
                  onSelected: _applySavedFilter,
                  itemBuilder: (_) => savedFilters
                      .map(
                        (filter) => PopupMenuItem(
                          value: filter,
                          child: Text(filter['name']?.toString() ?? 'Sem nome'),
                        ),
                      )
                      .toList(),
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Seleções salvas'),
                  ),
                ),
              OutlinedButton.icon(
                onPressed: loading ? null : _showWeeklyReport,
                icon: const Icon(Icons.summarize_outlined),
                label: const Text('Resumo da semana'),
              ),
              TextButton.icon(
                onPressed: loading
                    ? null
                    : () {
                        setState(() {
                          owner = null;
                          contentType = null;
                          stage = null;
                          priority = null;
                          dueStatus = null;
                          search.clear();
                        });
                        _load();
                      },
                icon: const Icon(Icons.filter_alt_off_outlined),
                label: const Text('Limpar filtros'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            'Verificações do portal',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          Text('${tasks.length} de $totalTasks registros nesta seleção'),
          if (loading) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(),
          ],
          if (loadError != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(loadError!),
                trailing: IconButton(
                  tooltip: 'Tentar novamente',
                  onPressed: () => _load(),
                  icon: const Icon(Icons.refresh),
                ),
              ),
            ),
          if (tasks.isEmpty && !loading)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  'Nenhuma verificação com esses filtros. '
                  'Escolha outro responsável ou limpe a seleção.',
                ),
              ),
            ),
          ...tasks.map(
            (task) => Card(
              child: ListTile(
                key: ValueKey('mission-task-${task['id']}'),
                onTap: () => _openTask((task['id'] as num).toInt()),
                leading: CircleAvatar(
                  child: Text(task['priority']?.toString() ?? '?'),
                ),
                title: Text(task['title']?.toString() ?? 'Sem título'),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${task['content_type'] ?? 'Sem tipo'} · '
                        '${task['current_stage'] ?? 'Triagem'}',
                      ),
                      Text(
                        'Responsável: ${task['primary_owner'] ?? task['responsible'] ?? 'Não atribuído'}'
                        ' · Revisão: ${task['cross_reviewer'] ?? 'Não atribuída'}',
                      ),
                      if ((task['suggested_area']?.toString() ?? '').isNotEmpty)
                        Text('Área: ${task['suggested_area']}'),
                      if (task['deadline_date'] != null)
                        Text(
                          'Prazo: ${task['deadline_date']}'
                          '${task['deadline_status'] == 'overdue' ? ' · vencido' : ''}',
                        ),
                      const SizedBox(height: 4),
                      Text(_nextAction(task)),
                    ],
                  ),
                ),
                trailing: const Icon(Icons.chevron_right),
              ),
            ),
          ),
          if (tasks.length < totalTasks)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                key: const ValueKey('mission-load-more'),
                onPressed: loading ? null : () => _load(append: true),
                child: const Text('Carregar mais verificações'),
              ),
            ),
          const SizedBox(height: 20),
          _automationCard(context),
          const SizedBox(height: 16),
          Card(
            child: ExpansionTile(
              leading: const Icon(Icons.account_tree_outlined),
              title: Text('Atividades complementares (${workItems.length})'),
              subtitle: const Text(
                'Memória institucional, entrevistas, organização e passagem de bastão.',
              ),
              children: workItems.isEmpty
                  ? const [
                      ListTile(
                        title: Text(
                          'Nenhuma atividade complementar disponível.',
                        ),
                      ),
                    ]
                  : workItems
                        .map(
                          (item) => ListTile(
                            onTap: () =>
                                _openWorkItem((item['id'] as num).toInt()),
                            leading: Icon(
                              item['completed'] == true
                                  ? Icons.check_circle_outline
                                  : Icons.radio_button_unchecked,
                            ),
                            title: Text(
                              item['title']?.toString() ?? 'Sem título',
                            ),
                            subtitle: Text(
                              '${_sectionLabel(item['section']?.toString() ?? '')}'
                              ' · ${item['status'] ?? 'A fazer'}',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                          ),
                        )
                        .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _filter({
    required String label,
    required String? value,
    required List<String> values,
    required String fieldKey,
    required String empty,
    required ValueChanged<String?> onChanged,
    Map<String, String> labels = const {},
  }) {
    final choices = {...values, ?value}.toList();
    return SizedBox(
      width: 240,
      child: DropdownButtonFormField<String>(
        key: ValueKey('$fieldKey-$value'),
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        items: [
          DropdownMenuItem(value: null, child: Text(empty)),
          ...choices.map(
            (choice) => DropdownMenuItem(
              value: choice,
              child: Text(
                labels[choice] ?? choice,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
        onChanged: loading
            ? null
            : (selected) {
                onChanged(selected);
              },
      ),
    );
  }

  Widget _automationCard(BuildContext context) {
    if (automation == null) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.fact_check_outlined),
          title: const Text('Conferências automáticas'),
          subtitle: const Text(
            'As sugestões ainda não foram carregadas. '
            'Você pode continuar o registro manual da tarefa.',
          ),
          trailing: IconButton(
            tooltip: 'Carregar conferências',
            onPressed: _loadAutomation,
            icon: const Icon(Icons.refresh),
          ),
        ),
      );
    }
    final a = automation!;
    final suggested = (a['suggested_tasks'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final missing = Map<String, dynamic>.from(
      a['missing_evidence'] as Map? ?? {},
    );
    final duplicates = Map<String, dynamic>.from(
      a['possible_duplicates'] as Map? ?? {},
    );
    final urlCheck = Map<String, dynamic>.from(a['url_check'] as Map? ?? {});
    final missingCount = missing['count'] ?? 0;
    final dupeCount = duplicates['count'] ?? 0;
    final brokenCount = urlCheck['broken'] ?? 0;
    final pendingUrls = urlCheck['pending'] ?? 0;

    final dupItems = <Map<String, dynamic>>[];
    for (final group in (duplicates['internal'] as List? ?? const [])) {
      final g = Map<String, dynamic>.from(group as Map);
      final label = g['kind'] == 'url' ? 'mesma URL' : 'mesmo título';
      for (final t in (g['tasks'] as List? ?? const [])) {
        final task = Map<String, dynamic>.from(t as Map);
        dupItems.add({
          ...task,
          'title': '${task['title'] ?? 'Sem título'} ($label)',
        });
      }
    }
    for (final m in (duplicates['drupal_matches'] as List? ?? const [])) {
      final match = Map<String, dynamic>.from(m as Map);
      final task = Map<String, dynamic>.from(match['task'] as Map? ?? {});
      dupItems.add({
        ...task,
        'title':
            '${task['title'] ?? 'Sem título'} (≈ rascunho ${match['drupal_nid']})',
      });
    }

    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.auto_awesome_outlined),
        title: const Text('Sugestões automáticas'),
        subtitle: const Text(
          'O sistema aponta prioridades e inconsistências. Nada é concluído sozinho.',
        ),
        children: [
          if (suggested.isEmpty)
            const ListTile(title: Text('Sem sugestões no momento.'))
          else
            ...suggested.map(
              (task) => ListTile(
                dense: true,
                onTap: () => _openTask(task['id'] as int),
                leading: CircleAvatar(
                  radius: 16,
                  child: Text(
                    task['priority']?.toString() ?? '?',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                title: Text(task['title']?.toString() ?? 'Sem título'),
                subtitle: Text(task['reason']?.toString() ?? ''),
                trailing: const Icon(Icons.chevron_right),
              ),
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ActionChip(
                  avatar: const Icon(Icons.fact_check_outlined, size: 18),
                  label: Text('Sem evidência ($missingCount)'),
                  onPressed: () => _showIssueList(
                    'Etapas avançadas sem evidência',
                    (missing['items'] as List? ?? const [])
                        .map((e) => Map<String, dynamic>.from(e as Map))
                        .toList(),
                    (item) =>
                        '${item['current_stage'] ?? 'Sem etapa'} • ${item['primary_owner'] ?? 'Não atribuído'}',
                  ),
                ),
                ActionChip(
                  avatar: const Icon(Icons.copy_all_outlined, size: 18),
                  label: Text('Duplicidades ($dupeCount)'),
                  onPressed: () => _showIssueList(
                    'Possíveis duplicidades',
                    dupItems,
                    (item) =>
                        '${item['content_type'] ?? 'Sem tipo'} • ${item['current_stage'] ?? 'Sem etapa'}',
                  ),
                ),
                ActionChip(
                  avatar: const Icon(Icons.link_off_outlined, size: 18),
                  label: Text('URLs quebradas ($brokenCount)'),
                  onPressed: () => _showIssueList(
                    'URLs públicas com problema',
                    (urlCheck['issues'] as List? ?? const [])
                        .map((e) => Map<String, dynamic>.from(e as Map))
                        .toList(),
                    (item) =>
                        '${item['url'] ?? ''}\n${item['error'] ?? 'HTTP ${item['http_code'] ?? '?'}'}',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: checkingUrls ? null : _runUrlCheck,
                  icon: checkingUrls
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.travel_explore_outlined),
                  label: Text(
                    pendingUrls > 0
                        ? 'Verificar URLs ($pendingUrls pendentes)'
                        : 'Verificar URLs novamente',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 138,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelLarge),
              Text(value, style: Theme.of(context).textTheme.titleLarge),
            ],
          ),
        ),
      ),
    );
  }
}

class MissionEvidenceSelection {
  const MissionEvidenceSelection({required this.name, required this.bytes});
  final String name;
  final Uint8List bytes;
}

typedef MissionEvidencePicker = Future<MissionEvidenceSelection?> Function();

// A fullscreen route owns its opening identity; renewed sessions may resume
// local fields, but older requests must not replace them.
mixin _MissionDialogSession<T extends StatefulWidget> on State<T> {
  late final int _dialogIdentityEpoch;
  int _sessionRevision = 0;

  bool get _identityChanged =>
      AppSession.instance.identityEpoch != _dialogIdentityEpoch;
  bool get _sessionReady =>
      !_identityChanged && AppSession.instance.authenticated;

  int? _beginSessionRequest() => _sessionReady ? _sessionRevision : null;
  bool _currentSessionRequest(int revision) =>
      mounted && _sessionReady && revision == _sessionRevision;

  @override
  void initState() {
    super.initState();
    _dialogIdentityEpoch = AppSession.instance.identityEpoch;
    AppSession.instance.addListener(_dialogSessionChanged);
  }

  void _dialogSessionChanged() {
    if (!mounted) return;
    _sessionRevision++;
    setState(() => _resetSessionView(_identityChanged));
    if (_sessionReady) _resumeSessionView();
  }

  // Never navigate in this listener: sign-in may still own the top route when
  // setSession notifies listeners.
  void _resetSessionView(bool changedIdentity);
  void _resumeSessionView();

  @override
  void dispose() {
    AppSession.instance.removeListener(_dialogSessionChanged);
    super.dispose();
  }
}

class _MissionSessionNotice extends StatelessWidget {
  const _MissionSessionNotice({required this.identityChanged});
  final bool identityChanged;

  @override
  Widget build(BuildContext context) {
    if (!identityChanged) {
      return const SessionPrompt(
        title: 'Entre para retomar este preenchimento',
        message:
            'Os campos ainda não salvos continuam nesta janela. '
            'Entre com a mesma conta para continuar e salvar.',
      );
    }
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Esta ficha pertence à sessão anterior. '
          'Feche esta janela e abra a tarefa com a conta atual.',
          key: ValueKey('mission-session-ended'),
        ),
      ),
    );
  }
}

class MissionTaskDialog extends StatefulWidget {
  const MissionTaskDialog({
    super.key,
    required this.taskId,
    this.workflow = _MissionPageState.stages,
    this.evidencePicker,
  });

  final int taskId;
  final List<String> workflow;
  final MissionEvidencePicker? evidencePicker;

  @override
  State<MissionTaskDialog> createState() => _MissionTaskDialogState();
}

class _MissionTaskDialogState extends State<MissionTaskDialog>
    with _MissionDialogSession<MissionTaskDialog> {
  Map<String, dynamic>? task;
  Map<String, dynamic> _original = {};
  List<Map<String, dynamic>>? _duplicates;
  Map<String, dynamic>? _gapCheck;
  String? _loadError;
  String? _duplicateError;
  String? _gapCheckError;
  bool loading = true;
  bool saving = false;
  bool checkingDuplicates = false;
  bool checkingGap = false;
  bool _applying = false;
  bool _didChange = false;
  bool _allowClose = false;
  bool _closePromptOpen = false;
  int _step = 0;
  final _taskScroll = ScrollController();
  String? stage;
  bool publicCheck = false;

  final evidence = TextEditingController();
  final source = TextEditingController();
  final consultationDate = TextEditingController();
  final observations = TextEditingController();
  final note = TextEditingController();
  final primaryOwner = TextEditingController();
  final crossReviewer = TextEditingController();
  final internalDeadline = TextEditingController();

  Map<String, TextEditingController> get _fields => {
    'evidence': evidence,
    'confirmed_source': source,
    'consultation_date': consultationDate,
    'observations': observations,
    'note': note,
    'primary_owner': primaryOwner,
    'cross_reviewer': crossReviewer,
    'internal_deadline': internalDeadline,
  };

  Map<String, dynamic> get _values => {
    for (final entry in _fields.entries) entry.key: entry.value.text,
    'current_stage': stage,
    'public_check_ok': publicCheck,
  };

  bool get _dirty =>
      task != null &&
      _values.entries.any((entry) => entry.value != _original[entry.key]);

  @override
  void initState() {
    super.initState();
    for (final controller in _fields.values) {
      controller.addListener(_formChanged);
    }
    _load();
  }

  @override
  void dispose() {
    UnsavedWork.instance.remove(this);
    _taskScroll.dispose();
    for (final controller in _fields.values) {
      controller.removeListener(_formChanged);
      controller.dispose();
    }
    super.dispose();
  }

  @override
  void _resetSessionView(bool changedIdentity) {
    loading = false;
    saving = false;
    checkingDuplicates = false;
    checkingGap = false;
    if (!changedIdentity) return;
    _applying = true;
    task = null;
    _original = {};
    _duplicates = null;
    _gapCheck = null;
    _loadError = null;
    _duplicateError = null;
    _gapCheckError = null;
    stage = null;
    publicCheck = false;
    _didChange = false;
    for (final controller in _fields.values) {
      controller.clear();
    }
    _applying = false;
    UnsavedWork.instance.remove(this);
  }

  @override
  void _resumeSessionView() {
    if (task == null) _load();
  }

  void _changeStep(int value) {
    setState(() => _step = value);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _taskScroll.hasClients) _taskScroll.jumpTo(0);
    });
  }

  void _formChanged() {
    if (_applying || !mounted) return;
    UnsavedWork.instance.setDirty(this, _dirty);
    setState(() {});
  }

  void _message(String text) {
    if (!mounted || !_sessionReady) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _applyTask(Map<String, dynamic> data, {bool preserveEdits = false}) {
    _applying = true;
    task = data;
    if (!preserveEdits) {
      stage =
          data['current_stage']?.toString() ?? _MissionPageState.stages.first;
      publicCheck = data['public_check_ok'] == true;
      for (final entry in _fields.entries) {
        entry.value.text = entry.key == 'note'
            ? ''
            : data[entry.key]?.toString() ?? '';
      }
      _original = Map<String, dynamic>.from(_values);
    }
    _applying = false;
    UnsavedWork.instance.setDirty(this, _dirty);
  }

  Future<void> _load({bool preserveEdits = false}) async {
    final revision = _beginSessionRequest();
    if (revision == null) return;
    setState(() => loading = true);
    try {
      final response = await http.get(
        _uri('/mission-tasks/${widget.taskId}'),
        headers: AppSession.instance.authHeaders,
      );
      if (!_currentSessionRequest(revision)) return;
      if (response.statusCode != 200) throw Exception(_error(response));
      final data = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)),
      );
      if (!_currentSessionRequest(revision)) return;
      setState(() {
        _applyTask(data, preserveEdits: preserveEdits);
        _loadError = null;
      });
    } catch (error) {
      if (_currentSessionRequest(revision)) {
        setState(() => _loadError = workflowError(error));
      }
    } finally {
      if (_currentSessionRequest(revision)) setState(() => loading = false);
    }
  }

  Future<void> _save() async {
    final revision = _beginSessionRequest();
    if (revision == null) return;
    if (saving || task == null || !_dirty) return;
    final changes = <String, dynamic>{};
    for (final entry in _values.entries) {
      if (entry.value == _original[entry.key]) continue;
      if (const {
            'primary_owner',
            'cross_reviewer',
            'internal_deadline',
          }.contains(entry.key) &&
          !AppSession.instance.canReview) {
        continue;
      }
      changes[entry.key] = entry.value is String
          ? (entry.value as String).trim()
          : entry.value;
    }
    final sourceUri = Uri.tryParse(source.text.trim());
    if (changes.containsKey('confirmed_source') &&
        sourceUri != null &&
        const {'http', 'https'}.contains(sourceUri.scheme) &&
        sourceUri.host.isNotEmpty) {
      changes['evidence_url'] = source.text.trim();
    }
    if (changes.isEmpty) return;
    setState(() => saving = true);
    try {
      final response = await http.patch(
        _uri('/mission-tasks/${widget.taskId}'),
        headers: AppSession.instance.authHeaders,
        body: jsonEncode(changes),
      );
      if (!_currentSessionRequest(revision)) return;
      if (response.statusCode != 200) throw Exception(_error(response));
      final data = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)),
      );
      if (!_currentSessionRequest(revision)) return;
      setState(() {
        _applyTask(data);
        _didChange = true;
      });
      _message(
        'Registro da tarefa salvo. O conteúdo do portal não foi alterado.',
      );
      // Gap-born tasks re-check the ficha on save — "resolved on the
      // portal" must reflect the portal's real state, not the task's.
      await _recheckGap();
    } catch (error) {
      if (_currentSessionRequest(revision)) _message(workflowError(error));
    } finally {
      if (_currentSessionRequest(revision)) setState(() => saving = false);
    }
  }

  Future<void> _requestClose() async {
    if (saving || _closePromptOpen) return;
    if (_dirty) {
      _closePromptOpen = true;
      final discard = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Você tem alterações não salvas'),
          content: const Text(
            'O texto e a etapa ainda não salvos serão descartados. '
            'Checklists e arquivos já registrados serão mantidos.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Continuar preenchendo'),
            ),
            FilledButton(
              key: const ValueKey('mission-confirm-discard'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Descartar alterações'),
            ),
          ],
        ),
      );
      _closePromptOpen = false;
      if (discard != true || !mounted) return;
    }
    UnsavedWork.instance.remove(this);
    setState(() => _allowClose = true);
    if (mounted) Navigator.pop(context, _didChange);
  }

  Future<void> _uploadEvidence() async {
    final revision = _beginSessionRequest();
    if (revision == null) return;
    if (saving) return;
    try {
      MissionEvidenceSelection? selected;
      if (widget.evidencePicker != null) {
        selected = await widget.evidencePicker!();
      } else {
        final file = await FilePicker.pickFile(dialogTitle: 'Anexar evidência');
        if (file != null) {
          selected = MissionEvidenceSelection(
            name: file.name,
            bytes: await file.readAsBytes(),
          );
        }
      }
      if (selected == null || !_currentSessionRequest(revision)) return;
      if (selected.bytes.isEmpty) {
        _message('O arquivo está vazio. Escolha a evidência novamente.');
        return;
      }
      if (selected.bytes.length > 10 * 1024 * 1024) {
        _message('A evidência deve ter até 10 MB.');
        return;
      }
      setState(() => saving = true);
      final request = http.MultipartRequest(
        'POST',
        _uri('/mission-tasks/${widget.taskId}/evidence-files'),
      );
      final headers = Map<String, String>.from(AppSession.instance.authHeaders)
        ..remove('Content-Type');
      request.headers.addAll(headers);
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          selected.bytes,
          filename: selected.name,
        ),
      );
      final response = await http.Response.fromStream(await http.send(request));
      if (!_currentSessionRequest(revision)) return;
      if (response.statusCode != 201) throw Exception(_error(response));
      _didChange = true;
      await _load(preserveEdits: true);
      if (!_currentSessionRequest(revision)) return;
      _message(
        'Arquivo anexado à tarefa. Seu preenchimento ainda não salvo foi preservado.',
      );
    } catch (error) {
      if (_currentSessionRequest(revision)) _message(workflowError(error));
    } finally {
      if (_currentSessionRequest(revision)) setState(() => saving = false);
    }
  }

  Future<void> _check(String kind, int order, bool completed) async {
    final revision = _beginSessionRequest();
    if (revision == null) return;
    if (saving) return;
    setState(() => saving = true);
    try {
      final response = await http.patch(
        _uri('/mission-tasks/${widget.taskId}/checklists/$kind/$order'),
        headers: AppSession.instance.authHeaders,
        body: jsonEncode({'completed': completed}),
      );
      if (!_currentSessionRequest(revision)) return;
      if (response.statusCode != 200) throw Exception(_error(response));
      final data = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)),
      );
      if (!_currentSessionRequest(revision)) return;
      setState(() {
        _applyTask(data, preserveEdits: true);
        _didChange = true;
      });
      _message('Checklist registrado. Seu preenchimento foi preservado.');
    } catch (error) {
      if (_currentSessionRequest(revision)) _message(workflowError(error));
    } finally {
      if (_currentSessionRequest(revision)) setState(() => saving = false);
    }
  }

  Future<void> _findDuplicates() async {
    final revision = _beginSessionRequest();
    if (revision == null) return;
    if (checkingDuplicates) return;
    setState(() {
      checkingDuplicates = true;
      _duplicateError = null;
    });
    try {
      final response = await http.get(
        _uri('/mission-tasks/${widget.taskId}/drupal-duplicates'),
        headers: AppSession.instance.authHeaders,
      );
      if (!_currentSessionRequest(revision)) return;
      if (response.statusCode != 200) throw Exception(_error(response));
      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
      if (_currentSessionRequest(revision)) {
        setState(() {
          _duplicates = (data['matches'] as List? ?? const [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        });
      }
    } catch (error) {
      if (_currentSessionRequest(revision)) {
        setState(() => _duplicateError = workflowError(error));
      }
    } finally {
      if (_currentSessionRequest(revision)) {
        setState(() => checkingDuplicates = false);
      }
    }
  }

  /// Node id carried by the task's canonical /node links, if linked.
  int? get _taskNid {
    for (final key in const ['public_url', 'edit_url']) {
      final match = RegExp(
        r'/node/(\d+)',
      ).firstMatch(task?[key]?.toString() ?? '');
      if (match != null) return int.tryParse(match.group(1)!);
    }
    return null;
  }

  /// Reconciliation: re-read the ficha on the portal and compare the
  /// current monitored fields with the gaps this task was created for.
  Future<void> _recheckGap() async {
    if (checkingGap) return;
    final bundle = task?['gap_bundle']?.toString() ?? '';
    final nid = _taskNid;
    if (bundle.isEmpty || nid == null) return;
    final revision = _beginSessionRequest();
    if (revision == null) return;
    setState(() {
      checkingGap = true;
      _gapCheck = null;
      _gapCheckError = null;
    });
    try {
      final response = await http.get(
        _uri('/portal/nodes/$nid/lacunas', {'tipo': bundle}),
        headers: AppSession.instance.authHeaders,
      );
      if (!_currentSessionRequest(revision)) return;
      if (response.statusCode != 200) throw Exception(_error(response));
      setState(() {
        _gapCheck = Map<String, dynamic>.from(
          jsonDecode(utf8.decode(response.bodyBytes)) as Map,
        );
      });
    } catch (error) {
      if (_currentSessionRequest(revision)) {
        setState(() => _gapCheckError = workflowError(error));
      }
    } finally {
      if (_currentSessionRequest(revision)) {
        setState(() => checkingGap = false);
      }
    }
  }

  Future<void> _linkPortalNode() async {
    final controller = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Vincular ficha do portal'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Endereço ou número da ficha',
            hintText: 'https://portal/node/123 ou 123',
          ),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Vincular'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || input == null || input.isEmpty) return;
    final portal = AppConfig.portalUrl;
    final portalUri = AppConfig.webUri(portal);
    if (portalUri == null) {
      _message('O endereço do portal não está configurado nesta estação.');
      return;
    }
    String? nid;
    if (RegExp(r'^\d+$').hasMatch(input)) {
      nid = input;
    } else {
      final parsed = AppConfig.webUri(input);
      // A configured portal may live under a path prefix (/neruds/node/1);
      // URLs on the same origin but outside that prefix do not belong to it.
      final basePath = portalUri.path.replaceAll(RegExp(r'/+$'), '');
      final path = parsed != null && basePath.isNotEmpty
          ? (parsed.path.startsWith('$basePath/')
              ? parsed.path.substring(basePath.length)
              : null)
          : parsed?.path;
      final match = path == null
          ? null
          : RegExp(r'^/node/(\d+)(?:/edit)?/?$').firstMatch(path);
      if (parsed == null || parsed.origin.toLowerCase() != portalUri.origin.toLowerCase() || path == null) {
        _message('O endereço informado não pertence ao portal configurado.');
        return;
      }
      nid = match?.group(1);
      // Aliases Pathauto (ex.: /projeto-agrovila) não trazem o nid — o
      // bridge resolve pelo shortlink da página.
      nid ??= await _resolvePortalAlias(input);
      if (nid == null) return;
    }
    final revision = _beginSessionRequest();
    // While a gap re-check is in flight another relink could overlap it —
    // both writes share the session revision and a late response for the
    // old node would overwrite the new node's result.
    if (revision == null || saving || checkingGap) return;
    setState(() => saving = true);
    try {
      final response = await http.patch(
        _uri('/mission-tasks/${widget.taskId}'),
        headers: AppSession.instance.authHeaders,
        body: jsonEncode({
          'public_url':
              '${portal.replaceAll(RegExp(r'/+$'), '')}/node/$nid',
          'edit_url':
              '${portal.replaceAll(RegExp(r'/+$'), '')}/node/$nid/edit',
        }),
      );
      if (!_currentSessionRequest(revision)) return;
      if (response.statusCode != 200) throw Exception(_error(response));
      final data = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)),
      );
      if (!_currentSessionRequest(revision)) return;
      setState(() {
        _applyTask(data, preserveEdits: true);
        // preserveEdits skips the checkbox and its baseline, but a relink
        // resets the server-side verification — reflect both immediately so
        // the already-persisted change is not treated as unsaved work.
        publicCheck = data['public_check_ok'] == true;
        _original['public_check_ok'] = publicCheck;
        // A relink targets a different node — drop the previous gap
        // result and duplicate matches so neither card reports node A's
        // state for node B.
        _gapCheck = null;
        _gapCheckError = null;
        _duplicates = null;
        UnsavedWork.instance.setDirty(this, _dirty);
        _didChange = true;
      });
      _message('Ficha $nid vinculada a esta tarefa.');
      await _recheckGap();
    } catch (error) {
      if (_currentSessionRequest(revision)) _message(workflowError(error));
    } finally {
      if (_currentSessionRequest(revision)) setState(() => saving = false);
    }
  }

  /// Resolve a same-portal alias to its node id via the bridge; returns
  /// null after messaging the user when the address cannot be resolved.
  Future<String?> _resolvePortalAlias(String url) async {
    try {
      final response = await http.get(
        _uri('/portal/node-lookup', {'url': url}),
        headers: AppSession.instance.authHeaders,
      );
      if (!mounted) return null;
      if (response.statusCode != 200) {
        _message(_error(response));
        return null;
      }
      final data = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)),
      );
      return data['nid']?.toString();
    } catch (error) {
      if (mounted) _message(workflowError(error));
      return null;
    }
  }

  String? _portalTarget(Map<String, dynamic> match) {
    final reference = task?['public_url'] ?? task?['edit_url'];
    final base = Uri.tryParse(reference?.toString() ?? '');
    if (base == null ||
        !const {'http', 'https'}.contains(base.scheme) ||
        base.host.isEmpty) {
      return null;
    }
    final path = match['path']?.toString();
    if (path != null && path.isNotEmpty) return base.resolve(path).toString();
    return match['nid'] == null
        ? null
        : base.resolve('/node/${match['nid']}').toString();
  }

  Future<void> _downloadEvidence(Map<String, dynamic> file) async {
    final revision = _beginSessionRequest();
    if (revision == null) return;
    try {
      final response = await http.get(
        _uri('/mission-evidence/${file['id']}'),
        headers: AppSession.instance.authHeaders,
      );
      if (!_currentSessionRequest(revision)) return;
      if (response.statusCode != 200) throw Exception(_error(response));
      if (!_currentSessionRequest(revision)) return;
      final location = await FilePicker.saveFile(
        dialogTitle: 'Salvar evidência',
        fileName: file['filename']?.toString() ?? 'evidence.bin',
        bytes: response.bodyBytes,
      );
      if (location != null && _currentSessionRequest(revision)) {
        _message('Evidência salva no local escolhido.');
      }
    } catch (error) {
      if (_currentSessionRequest(revision)) _message(workflowError(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<bool>(
      canPop: _allowClose || (!_dirty && !saving),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _requestClose();
      },
      child: Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Verificação do portal'),
            leading: IconButton(
              key: const ValueKey('mission-task-close'),
              tooltip: 'Fechar verificação',
              onPressed: saving ? null : _requestClose,
              icon: const Icon(Icons.close),
            ),
            actions: [
              FilledButton.icon(
                key: const ValueKey('mission-task-save'),
                // A save triggers a gap re-check; disabling it while one
                // runs prevents two overlapping reconciliation requests.
                onPressed:
                    !_sessionReady || loading || saving || checkingGap || !_dirty
                    ? null
                    : _save,
                icon: saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: const Text('Salvar registro'),
              ),
              const SizedBox(width: 12),
            ],
          ),
          body: !_sessionReady
              ? _MissionSessionNotice(identityChanged: _identityChanged)
              : loading
              ? const Center(child: CircularProgressIndicator())
              : task == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_loadError ?? 'Esta tarefa não está disponível.'),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: () {
                            setState(() => loading = true);
                            _load();
                          },
                          child: const Text('Tentar novamente'),
                        ),
                      ],
                    ),
                  ),
                )
              : _taskBody(context),
        ),
      ),
    );
  }

  Widget _taskBody(BuildContext context) {
    final data = task!;
    const labels = [
      '1. Entender a lacuna',
      '2. Fonte e proposta',
      '3. Revisar e conferir',
    ];
    return ListView(
      key: const PageStorageKey('mission-task-form'),
      controller: _taskScroll,
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          data['title']?.toString() ?? 'Sem título',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            Chip(label: Text(data['content_type']?.toString() ?? 'Conteúdo')),
            if ((data['suggested_area']?.toString() ?? '').isNotEmpty)
              Chip(label: Text(data['suggested_area'].toString())),
            Chip(
              label: Text('Prioridade ${data['priority'] ?? 'não informada'}'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Responsável: ${data['primary_owner'] ?? data['responsible'] ?? 'Não atribuído'}'
          ' · Revisão: ${data['cross_reviewer'] ?? 'Não atribuída'}',
        ),
        const SizedBox(height: 8),
        Text(_nextAction({...data, 'current_stage': stage})),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _dirty
                  ? 'Há alterações não salvas. Salvar registro guarda a execução desta tarefa. '
                        'A página do portal é atualizada no Drupal.'
                  : 'Esta ficha registra pesquisa, proposta e conferência. '
                        'Salvar a tarefa não altera nem publica conteúdo no portal.',
            ),
          ),
        ),
        if (_loadError != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(_loadError!),
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var index = 0; index < labels.length; index++)
              ChoiceChip(
                key: ValueKey('mission-task-step-$index'),
                selected: _step == index,
                label: Text(labels[index]),
                onSelected: saving ? null : (_) => _changeStep(index),
              ),
          ],
        ),
        const SizedBox(height: 20),
        if (_step == 0) ..._contextFields(context),
        if (_step == 1) ..._researchFields(context),
        if (_step == 2) ..._reviewFields(context),
        const SizedBox(height: 24),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            if (_step > 0)
              OutlinedButton.icon(
                onPressed: saving ? null : () => _changeStep(_step - 1),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Voltar'),
              ),
            if (_step < 2)
              FilledButton.icon(
                key: const ValueKey('mission-task-next'),
                onPressed: saving ? null : () => _changeStep(_step + 1),
                icon: const Icon(Icons.arrow_forward),
                label: Text(
                  _step == 0
                      ? 'Registrar fonte e proposta'
                      : 'Revisar e conferir',
                ),
              ),
          ],
        ),
      ],
    );
  }

  List<Widget> _contextFields(BuildContext context) {
    final data = task!;
    return [
      Text(
        'O que precisa ser verificado',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 12),
      _Info('Lacuna identificada', data['gaps']),
      _Info('Ação sugerida', data['action']),
      const SizedBox(height: 12),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          PortalLinkButton(
            label: 'Conferir página pública',
            url: data['public_url']?.toString(),
          ),
          PortalLinkButton(
            label: 'Abrir edição no portal',
            url: data['edit_url']?.toString(),
            editing: true,
          ),
        ],
      ),
      const SizedBox(height: 8),
      const Text(
        'A edição utiliza sua conta e as permissões do Drupal. '
        'O registro desta missão permanece disponível para reunir a evidência.',
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('mission-link-node'),
        // Disabled while a gap re-check runs — the guard inside
        // _linkPortalNode would otherwise discard the entered node
        // silently after the dialog closed.
        onPressed: saving || checkingGap ? null : _linkPortalNode,
        icon: const Icon(Icons.link, size: 18),
        label: const Text('Vincular ficha do portal'),
      ),
      const SizedBox(height: 6),
      const Text(
        'Quando a ficha for criada pelo formulário do portal, informe o '
        'endereço ou o número para ligar esta tarefa a ela.',
      ),
      if ((data['gap_bundle']?.toString() ?? '').isNotEmpty) ...[
        const SizedBox(height: 12),
        _gapReconciliation(context),
      ],
      const SizedBox(height: 12),
      _Info('Onde pesquisar', data['where_to_search']),
      _Info('Fontes de partida', data['sources']),
      _Info('Consulta sugerida', data['suggested_query']),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        key: const ValueKey('mission-find-duplicates'),
        onPressed: checkingDuplicates ? null : _findDuplicates,
        icon: checkingDuplicates
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.find_in_page_outlined),
        label: const Text('Conferir registros com este título'),
      ),
      const SizedBox(height: 6),
      const Text(
        'Consulta de apoio para evitar duplicação. Nenhum registro é alterado.',
      ),
      if (_duplicateError != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(_duplicateError!),
        ),
      if (_duplicates != null && _duplicates!.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'Nenhum registro com título exato encontrado. '
            'Confira também as fontes e a página vinculada.',
          ),
        ),
      if (_duplicates != null)
        ..._duplicates!.map(
          (match) => Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(match['title']?.toString() ?? 'Sem título'),
                  Text(
                    match['published'] == true
                        ? 'Publicado no portal'
                        : 'Ainda não publicado',
                  ),
                  PortalLinkButton(
                    label: 'Abrir registro',
                    url: _portalTarget(match),
                  ),
                ],
              ),
            ),
          ),
        ),
      const SizedBox(height: 16),
      ExpansionTile(
        // Own PageStorageKey: inside the scrolled task ListView an unkeyed
        // ExpansionTile remounts after scrolling past it and PageStorage can
        // hand back the stored scroll offset (a double), crashing initState.
        key: const PageStorageKey('mission-task-origins'),
        tilePadding: EdgeInsets.zero,
        title: const Text('Origem e rastreabilidade'),
        children: [
          _Info('Identificador na fonte', data['source_record_id']),
          _Info('Linha da planilha', data['spreadsheet_row']),
          _Info('Identificador da tarefa', widget.taskId),
        ],
      ),
    ];
  }

  /// Reconciliation card for tasks born from a monitored portal gap:
  /// re-reads the ficha and reports which recorded fields are still empty.
  Widget _gapReconciliation(BuildContext context) {
    final data = task!;
    final recorded = (data['gap_fields'] as List? ?? const [])
        .map((f) => f.toString())
        .toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Reconciliação com o portal',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              'Esta tarefa nasceu de campos ausentes na ficha '
              '(${recorded.length} monitorados). A verificação lê o portal '
              'agora — o resultado não altera a tarefa.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('mission-recheck-gap'),
              onPressed: checkingGap || _taskNid == null
                  ? null
                  : _recheckGap,
              icon: checkingGap
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync, size: 18),
              label: const Text('Reconferir lacuna no portal'),
            ),
            if (_taskNid == null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Vincule a ficha do portal para reconferir a lacuna.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (_gapCheckError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _gapCheckError!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            if (_gapCheck != null)
              ..._gapCheckResult(context, _gapCheck!, recorded),
          ],
        ),
      ),
    );
  }

  List<Widget> _gapCheckResult(
    BuildContext context,
    Map<String, dynamic> check,
    List<String> recorded,
  ) {
    final bodySmall = Theme.of(context).textTheme.bodySmall;
    if (check['found'] != true) {
      final actualType = check['actual_type']?.toString();
      return [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            actualType != null
                ? 'A ficha vinculada é do tipo "$actualType" no portal, '
                    'diferente da lacuna registrada nesta tarefa — '
                    'revise o vínculo.'
                : 'A ficha não foi encontrada no portal — ela pode ter sido '
                    'removida ou sua conta não pode visualizá-la.',
          ),
        ),
      ];
    }
    final missingFields = (check['missing_fields'] as List? ?? const [])
        .map((f) => f.toString())
        .toList();
    final missingLabels = (check['missing_labels'] as List? ?? const [])
        .map((f) => f.toString())
        .toList();
    final labelOf = {
      for (var i = 0; i < missingFields.length; i++)
        missingFields[i]:
            i < missingLabels.length ? missingLabels[i] : missingFields[i],
    };
    final pending = [
      for (final field in recorded)
        if (missingFields.contains(field)) labelOf[field] ?? field,
    ];
    final resolvedCount = recorded.length - pending.length;
    final otherMissing = missingFields.length - pending.length;
    return [
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (pending.isEmpty)
              Text(
                'Lacuna resolvida no portal — os campos registrados '
                'estão preenchidos.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              )
            else
              Text('Ainda falta no portal: ${pending.join(', ')}.'),
            if (pending.isNotEmpty && resolvedCount > 0)
              Text(
                'Já preenchidos: $resolvedCount campo(s).',
                style: bodySmall,
              ),
            if (otherMissing > 0)
              Text(
                'Outros campos monitorados ausentes: $otherMissing.',
                style: bodySmall,
              ),
            if (check['published'] != true)
              Text('A ficha segue como rascunho no portal.', style: bodySmall),
          ],
        ),
      ),
    ];
  }

  List<Widget> _researchFields(BuildContext context) {
    final checklists = task!['checklists'] as Map? ?? {};
    return [
      Text(
        'Fonte e comprovação',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 6),
      const Text(
        'Registre o que a fonte permite afirmar e separe isso '
        'da proposta que ainda precisa ser revisada.',
      ),
      const SizedBox(height: 16),
      _textField(
        source,
        'Fonte confirmada / URL da evidência',
        'Documento, página oficial ou contato que confirmou a informação.',
        keyName: 'mission-evidence-source',
      ),
      const SizedBox(height: 12),
      _textField(
        consultationDate,
        'Data da consulta',
        'Use AAAA-MM-DD. Preserve a data em que a fonte foi consultada.',
        keyName: 'mission-consultation-date',
      ),
      const SizedBox(height: 12),
      PortalLinkButton(label: 'Abrir fonte confirmada', url: source.text),
      const SizedBox(height: 12),
      _textField(
        evidence,
        'O que a fonte comprova',
        'Descreva a informação confirmada e seus limites.',
        keyName: 'mission-evidence-text',
        lines: 3,
      ),
      const SizedBox(height: 16),
      _evidenceFilesSection(context),
      const SizedBox(height: 16),
      _textField(
        observations,
        'Proposta de atualização / divergências',
        'Escreva o ajuste proposto, o que falta confirmar e eventuais bloqueios.',
        keyName: 'mission-proposal',
        lines: 4,
      ),
      const SizedBox(height: 20),
      Text(
        'Checklist de pesquisa',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const Text(
        'Cada marcação é registrada imediatamente. '
        'O restante do preenchimento é mantido até você salvar.',
      ),
      ..._checks('pesquisa', checklists['pesquisa']),
    ];
  }

  List<Widget> _reviewFields(BuildContext context) {
    final data = task!;
    final checklists = data['checklists'] as Map? ?? {};
    final events = (data['events'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final stages = {
      ...(widget.workflow.isEmpty ? _MissionPageState.stages : widget.workflow),
      ?stage,
    }.toList();
    return [
      Text(
        'Revisão e conferência',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 6),
      const Text(
        'Fonte comprova a informação; revisão registra a validação; '
        'conferência pública verifica o que realmente aparece no portal. '
        'Uma etapa não substitui as outras.',
      ),
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(
        key: ValueKey('mission-task-stage-$stage'),
        initialValue: stage,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Etapa registrada',
          helperText:
              'Mude a etapa conforme o trabalho realizado. Isso não publica conteúdo.',
          border: OutlineInputBorder(),
        ),
        items: stages
            .map((value) => DropdownMenuItem(value: value, child: Text(value)))
            .toList(),
        onChanged: saving
            ? null
            : (value) {
                stage = value;
                _formChanged();
              },
      ),
      const SizedBox(height: 16),
      _textField(
        primaryOwner,
        'Responsável principal',
        'Atribuição organiza o trabalho e não concede permissão no portal.',
        keyName: 'mission-primary-owner',
        enabled: AppSession.instance.canReview,
      ),
      const SizedBox(height: 12),
      _textField(
        crossReviewer,
        'Responsável pela revisão cruzada',
        'Alteração disponível para revisão e coordenação.',
        keyName: 'mission-cross-reviewer',
        enabled: AppSession.instance.canReview,
      ),
      const SizedBox(height: 12),
      _textField(
        internalDeadline,
        'Prazo interno (AAAA-MM-DD)',
        'Prazo de trabalho da equipe.',
        keyName: 'mission-internal-deadline',
        enabled: AppSession.instance.canReview,
      ),
      const SizedBox(height: 12),
      _textField(
        note,
        'Registro da revisão / nota desta atualização',
        'Informe quem validou, o que foi decidido e o próximo passo, quando aplicável.',
        keyName: 'mission-update-note',
        lines: 3,
      ),
      const SizedBox(height: 16),
      PortalLinkButton(
        label: 'Conferir resultado no portal',
        url: data['public_url']?.toString(),
      ),
      SwitchListTile(
        key: const ValueKey('mission-public-check'),
        contentPadding: EdgeInsets.zero,
        value: publicCheck,
        onChanged: saving
            ? null
            : (value) {
                publicCheck = value;
                _formChanged();
              },
        title: const Text('Conferência pública realizada'),
        subtitle: const Text(
          'Marque depois de abrir a página e verificar o resultado. '
          'O registro será guardado ao salvar esta ficha.',
        ),
      ),
      const SizedBox(height: 16),
      Text(
        'Checklist de publicação',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const Text(
        'Estas marcações documentam verificações. '
        'Elas não executam a publicação.',
      ),
      ..._checks('publicacao', checklists['publicacao']),
      const SizedBox(height: 16),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text('Histórico desta verificação (${events.length})'),
        children: events.isEmpty
            ? const [ListTile(title: Text('Nenhuma atualização registrada.'))]
            : events
                  .map(
                    (event) => ListTile(
                      leading: const Icon(Icons.history),
                      title: Text('${event['actor'] ?? 'Conta não informada'}'),
                      subtitle: Text(
                        '${event['created_at'] ?? ''}\n'
                        '${event['note'] ?? event['event_type'] ?? ''}',
                      ),
                    ),
                  )
                  .toList(),
      ),
    ];
  }

  Widget _textField(
    TextEditingController controller,
    String label,
    String help, {
    required String keyName,
    int lines = 1,
    bool enabled = true,
  }) => TextField(
    key: ValueKey(keyName),
    controller: controller,
    enabled: enabled && !saving,
    minLines: lines,
    maxLines: lines == 1 ? 1 : lines + 3,
    decoration: InputDecoration(
      labelText: label,
      helperText: help,
      helperMaxLines: 3,
      border: const OutlineInputBorder(),
      alignLabelWithHint: lines > 1,
    ),
  );

  Widget _evidenceFilesSection(BuildContext context) {
    final files = (task?['evidence_files'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Arquivos que sustentam a pesquisa',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            const Text(
              'Os arquivos ficam vinculados à tarefa, com autoria e integridade registradas. '
              'Eles não são publicados como anexos no portal. Até 10 MB por arquivo.',
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('mission-upload-evidence'),
                onPressed: saving ? null : _uploadEvidence,
                icon: const Icon(Icons.attach_file),
                label: const Text('Anexar evidência'),
              ),
            ),
            if (files.isEmpty) const Text('Nenhum arquivo anexado.'),
            ...files.map(
              (file) => ListTile(
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: Text(file['filename']?.toString() ?? 'Arquivo'),
                subtitle: Text(
                  'Registrado por ${file['uploaded_by'] ?? 'conta não informada'}'
                  ' · ${file['size_bytes'] ?? 0} bytes',
                ),
                trailing: const Icon(Icons.download_outlined),
                onTap: () => _downloadEvidence(file),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _checks(String kind, dynamic raw) {
    return (raw as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .map(
          (item) => CheckboxListTile(
            key: ValueKey('mission-check-$kind-${item['item_order']}'),
            contentPadding: EdgeInsets.zero,
            value: item['completed'] == true,
            onChanged: saving
                ? null
                : (value) => _check(
                    kind,
                    (item['item_order'] as num).toInt(),
                    value == true,
                  ),
            title: Text(item['item']?.toString() ?? ''),
            subtitle: item['criterion'] == null
                ? null
                : Text(item['criterion'].toString()),
          ),
        )
        .toList();
  }
}

class _Info extends StatelessWidget {
  const _Info(this.label, this.value);

  final String label;
  final dynamic value;

  @override
  Widget build(BuildContext context) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return const SizedBox.shrink();
    return Card(
      child: ListTile(title: Text(label), subtitle: SelectableText(text)),
    );
  }
}

String _sectionLabel(String value) {
  const labels = {
    'chamados_tecnicos': 'Chamados técnicos',
    'extensao_institucional': 'Extensão institucional',
    'roteiro_entrevistas': 'Roteiro de entrevistas',
    'mvv': 'Missão, Visão e Valores',
    'historia_linha_tempo': 'História e linha do tempo',
    'organograma': 'Organograma',
    'noticias_instagram': 'Instagram → notícia',
    'paginas_futuras': 'Páginas futuras',
    'diario_extensao': 'Diário de extensão',
    'encerramento_acessos': 'Encerramento e acessos',
  };
  return labels[value] ?? value;
}

class MissionWorkItemDialog extends StatefulWidget {
  const MissionWorkItemDialog({super.key, required this.workItemId});

  final int workItemId;

  @override
  State<MissionWorkItemDialog> createState() => _MissionWorkItemDialogState();
}

class _MissionWorkItemDialogState extends State<MissionWorkItemDialog>
    with _MissionDialogSession<MissionWorkItemDialog> {
  Map<String, dynamic>? item;
  bool loading = true;
  bool saving = false;
  bool completed = false;
  bool _applying = false;
  bool _allowClose = false;
  bool _didChange = false;
  bool _closePromptOpen = false;
  Map<String, dynamic> _original = {};

  final status = TextEditingController();
  final evidence = TextEditingController();
  final note = TextEditingController();

  Map<String, dynamic> get _values => {
    'completed': completed,
    'status': status.text,
    'evidence': evidence.text,
    'note': note.text,
  };

  bool get _dirty =>
      item != null &&
      _values.entries.any((entry) => entry.value != _original[entry.key]);

  void _formChanged() {
    if (_applying || !mounted) return;
    UnsavedWork.instance.setDirty(this, _dirty);
    setState(() {});
  }

  void _message(String text) {
    if (mounted && _sessionReady) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  void initState() {
    super.initState();
    for (final controller in [status, evidence, note]) {
      controller.addListener(_formChanged);
    }
    _load();
  }

  @override
  void dispose() {
    UnsavedWork.instance.remove(this);
    for (final controller in [status, evidence, note]) {
      controller.removeListener(_formChanged);
    }
    status.dispose();
    evidence.dispose();
    note.dispose();
    super.dispose();
  }

  @override
  void _resetSessionView(bool changedIdentity) {
    loading = false;
    saving = false;
    if (!changedIdentity) return;
    _applying = true;
    item = null;
    _original = {};
    completed = false;
    _didChange = false;
    for (final controller in [status, evidence, note]) {
      controller.clear();
    }
    _applying = false;
    UnsavedWork.instance.remove(this);
  }

  @override
  void _resumeSessionView() {
    if (item == null) _load();
  }

  void _applyItem(Map<String, dynamic> data) {
    _applying = true;
    item = data;
    completed = data['completed'] == true;
    status.text = data['status']?.toString() ?? '';
    evidence.text = data['evidence']?.toString() ?? '';
    note.text = data['note']?.toString() ?? '';
    _original = Map<String, dynamic>.from(_values);
    _applying = false;
    UnsavedWork.instance.setDirty(this, false);
  }

  Future<void> _load() async {
    final revision = _beginSessionRequest();
    if (revision == null) return;
    setState(() => loading = true);
    try {
      final response = await http.get(
        _uri('/mission-work-items/${widget.workItemId}'),
        headers: AppSession.instance.authHeaders,
      );
      if (!_currentSessionRequest(revision)) return;
      if (response.statusCode != 200) throw Exception(_error(response));
      final data = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)),
      );
      if (_currentSessionRequest(revision)) setState(() => _applyItem(data));
    } catch (error) {
      if (_currentSessionRequest(revision)) _message(workflowError(error));
    } finally {
      if (_currentSessionRequest(revision)) setState(() => loading = false);
    }
  }

  Future<void> _save() async {
    final revision = _beginSessionRequest();
    if (revision == null) return;
    if (!_dirty || saving) return;
    final changes = <String, dynamic>{
      for (final entry in _values.entries)
        if (entry.value != _original[entry.key])
          entry.key: entry.value is String
              ? (entry.value as String).trim()
              : entry.value,
    };
    setState(() => saving = true);
    try {
      final response = await http.patch(
        _uri('/mission-work-items/${widget.workItemId}'),
        headers: AppSession.instance.authHeaders,
        body: jsonEncode(changes),
      );
      if (!_currentSessionRequest(revision)) return;
      if (response.statusCode != 200) throw Exception(_error(response));
      final data = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)),
      );
      if (!_currentSessionRequest(revision)) return;
      setState(() {
        _applyItem(data);
        _didChange = true;
      });
      _message('Atividade registrada. O conteúdo do portal não foi alterado.');
    } catch (error) {
      if (_currentSessionRequest(revision)) _message(workflowError(error));
    } finally {
      if (_currentSessionRequest(revision)) setState(() => saving = false);
    }
  }

  Future<void> _requestClose() async {
    if (saving || _closePromptOpen) return;
    if (_dirty) {
      _closePromptOpen = true;
      final discard = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Você tem alterações não salvas'),
          content: const Text(
            'Deseja continuar o preenchimento ou descartar as alterações?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Continuar preenchendo'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Descartar alterações'),
            ),
          ],
        ),
      );
      _closePromptOpen = false;
      if (discard != true || !mounted) return;
    }
    UnsavedWork.instance.remove(this);
    setState(() => _allowClose = true);
    if (mounted) Navigator.pop(context, _didChange);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<bool>(
      canPop: _allowClose || (!_dirty && !saving),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _requestClose();
      },
      child: Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Atividade complementar'),
            leading: IconButton(
              key: const ValueKey('mission-work-item-close'),
              onPressed: saving ? null : _requestClose,
              icon: const Icon(Icons.close),
            ),
            actions: [
              FilledButton.icon(
                key: const ValueKey('mission-work-item-save'),
                onPressed: !_sessionReady || loading || saving || !_dirty
                    ? null
                    : _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Salvar'),
              ),
              const SizedBox(width: 12),
            ],
          ),
          body: !_sessionReady
              ? _MissionSessionNotice(identityChanged: _identityChanged)
              : loading
              ? const Center(child: CircularProgressIndicator())
              : item == null
              ? const Center(child: Text('Atividade não encontrada.'))
              : _body(context),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final data = item!;
    final payload = Map<String, dynamic>.from(data['payload'] as Map? ?? {});
    final events = (data['events'] as List<dynamic>? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final originalFields = payload.entries
        .where(
          (entry) =>
              entry.key != 'spreadsheet_row' &&
              entry.value != null &&
              entry.value.toString().trim().isNotEmpty,
        )
        .toList();

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(label: Text(_sectionLabel(data['section']?.toString() ?? ''))),
            Chip(label: Text('Linha ${data['spreadsheet_row']}')),
            if ((data['responsible']?.toString() ?? '').isNotEmpty)
              Chip(label: Text('Responsável: ${data['responsible']}')),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          data['title']?.toString() ?? 'Sem título',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Text(_dirty ? 'Há alterações não salvas.' : 'Registro preservado.'),
        const Text(
          'Salvar esta atividade registra o trabalho e não altera uma página do portal.',
        ),
        const SizedBox(height: 16),
        Card(
          child: ExpansionTile(
            title: const Text('Dados originais da planilha'),
            subtitle: const Text(
              'Referência preservada para comparar com o arquivo-fonte.',
            ),
            children: originalFields
                .map(
                  (entry) => ListTile(
                    title: Text(entry.key),
                    subtitle: SelectableText(entry.value.toString()),
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 14),
        SwitchListTile(
          value: completed,
          onChanged: saving
              ? null
              : (value) {
                  completed = value;
                  if (status.text.isEmpty ||
                      const {'A fazer', 'Concluído'}.contains(status.text)) {
                    status.text = value ? 'Concluído' : 'A fazer';
                  }
                  _formChanged();
                },
          title: const Text('Atividade concluída'),
          subtitle: const Text(
            'Concluir não apaga o estado anterior; a mudança entra no histórico.',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: status,
          enabled: !saving,
          decoration: const InputDecoration(
            labelText: 'Status',
            hintText: 'A fazer, em andamento, aguardando validação...',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: evidence,
          enabled: !saving,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'Evidência / link / produto',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('mission-work-item-note'),
          controller: note,
          enabled: !saving,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(
            labelText: 'Nota de execução',
            hintText:
                'Registre o que foi feito, quem validou, pendências ou próximos passos.',
            border: OutlineInputBorder(),
          ),
        ),
        const Divider(height: 32),
        Text('Histórico', style: Theme.of(context).textTheme.titleLarge),
        if (events.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Nenhuma alteração registrada ainda.'),
          )
        else
          ...events.map(
            (event) => ListTile(
              leading: const Icon(Icons.history),
              title: Text('${event['event_type']} • ${event['actor']}'),
              subtitle: Text('${event['created_at']}\n${event['note'] ?? ''}'),
              isThreeLine: true,
            ),
          ),
      ],
    );
  }
}

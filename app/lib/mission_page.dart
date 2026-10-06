import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'app_session.dart';

const _bridgeUrl = String.fromEnvironment(
  'NERUDS_BRIDGE_URL',
  defaultValue: 'https://largeo.tail2faed0.ts.net:8443',
);

Uri _uri(String path, [Map<String, String>? query]) {
  final base = _bridgeUrl.endsWith('/')
      ? _bridgeUrl.substring(0, _bridgeUrl.length - 1)
      : _bridgeUrl;
  return Uri.parse('$base$path').replace(queryParameters: query);
}

String _error(http.Response response) {
  try {
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    return data['detail']?.toString() ?? 'Erro HTTP ${response.statusCode}';
  } catch (_) {
    return 'Erro HTTP ${response.statusCode}';
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
  Map<String, dynamic>? dashboard;
  List<Map<String, dynamic>> tasks = const [];
  List<Map<String, dynamic>> workItems = const [];
  List<Map<String, dynamic>> savedFilters = const [];
  String? stage;
  String? priority;
  String? dueStatus;

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
    if (AppSession.instance.authenticated) _load();
  }

  @override
  void dispose() {
    AppSession.instance.removeListener(_sessionChanged);
    search.dispose();
    super.dispose();
  }

  void _sessionChanged() {
    if (!mounted) return;
    if (AppSession.instance.authenticated) {
      _load();
    } else {
      setState(() {
        dashboard = null;
        tasks = const [];
        workItems = const [];
        savedFilters = const [];
      });
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _load() async {
    if (!AppSession.instance.authenticated) return;
    setState(() => loading = true);
    try {
      final query = <String, String>{'limit': '250'};
      if (stage case final value?) query['stage'] = value;
      if (priority case final value?) query['priority'] = value;
      if (dueStatus case final value?) query['due_status'] = value;
      if (search.text.trim().isNotEmpty) query['q'] = search.text.trim();
      final responses = await Future.wait([
        http.get(
          _uri('/missions/1/dashboard'),
          headers: AppSession.instance.authHeaders,
        ),
        http.get(
          _uri('/missions/1/tasks', query),
          headers: AppSession.instance.authHeaders,
        ),
        http.get(
          _uri('/missions/1/work-items'),
          headers: AppSession.instance.authHeaders,
        ),
        http.get(
          _uri('/missions/1/saved-filters'),
          headers: AppSession.instance.authHeaders,
        ),
      ]);

      if (responses.any((r) => r.statusCode == 401)) {
        AppSession.instance.clear();
        _message('Sessão expirada. Entre novamente na aba Conteúdo.');
        return;
      }
      for (final response in responses) {
        if (response.statusCode != 200) {
          _message(_error(response));
          return;
        }
      }

      final d = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(responses[0].bodyBytes)),
      );
      final payload = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(responses[1].bodyBytes)),
      );
      final list = (payload['items'] as List<dynamic>? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final workPayload = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(responses[2].bodyBytes)),
      );
      final workList = (workPayload['items'] as List<dynamic>? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final savedList =
          (jsonDecode(utf8.decode(responses[3].bodyBytes)) as List<dynamic>? ??
                  const [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();

      if (mounted) {
        setState(() {
          dashboard = d;
          tasks = list;
          workItems = workList;
          savedFilters = savedList;
        });
      }
    } catch (e) {
      _message('Não foi possível carregar a missão: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _openTask(int id) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => MissionTaskDialog(taskId: id),
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
    if (search.text.trim().isNotEmpty) filters['q'] = search.text.trim();
    final response = await http.post(
      _uri('/missions/1/saved-filters'),
      headers: AppSession.instance.authHeaders,
      body: jsonEncode({'name': name, 'filters': filters}),
    );
    if (response.statusCode != 200) {
      _message(_error(response));
      return;
    }
    _message('Filtro salvo.');
    await _load();
  }

  void _applySavedFilter(Map<String, dynamic> saved) {
    final filters = Map<String, dynamic>.from(saved['filters'] as Map? ?? {});
    setState(() {
      priority = filters['priority']?.toString();
      stage = filters['stage']?.toString();
      dueStatus = filters['due_status']?.toString();
      search.text = filters['q']?.toString() ?? '';
    });
    _load();
  }

  Future<void> _showWeeklyReport() async {
    final response = await http.get(
      _uri('/missions/1/weekly-report'),
      headers: AppSession.instance.authHeaders,
    );
    if (response.statusCode != 200) {
      _message(_error(response));
      return;
    }
    final report = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(response.bodyBytes)),
    );
    final summary = Map<String, dynamic>.from(report['summary'] as Map? ?? {});
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
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppSession.instance,
      builder: (context, _) {
        if (!AppSession.instance.authenticated) {
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                'Missão do estagiário',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              const Card(
                child: ListTile(
                  leading: Icon(Icons.lock_outline),
                  title: Text('Entre no portal para iniciar'),
                  subtitle: Text(
                    'Use a aba Conteúdo. A mesma conta Drupal identifica quem pesquisou, revisou e alterou cada item.',
                  ),
                ),
              ),
            ],
          );
        }
        return _content(context);
      },
    );
  }

  Widget _content(BuildContext context) {
    final d = dashboard ?? const <String, dynamic>{};
    final p = Map<String, dynamic>.from(d['by_priority'] as Map? ?? {});
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Missão do estagiário',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 4),
          const Text(
            'Verificação do Portal NERUDS baseada na planilha de treinamento, com evidência e revisão cruzada.',
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _Metric('Itens', '${d['total_tasks'] ?? 205}'),
              _Metric('Concluídos', '${d['concluded'] ?? 0}'),
              _Metric('Progresso', '${d['progress_percent'] ?? 0}%'),
              _Metric('P0', '${p['P0'] ?? 0}'),
              _Metric('P1', '${p['P1'] ?? 0}'),
              _Metric('P2', '${p['P2'] ?? 0}'),
              _Metric('Atrasados', '${d['overdue'] ?? 0}'),
              _Metric('Próx. 7 dias', '${d['upcoming'] ?? 0}'),
              _Metric(
                'Complementares',
                '${d['work_concluded'] ?? 0}/${d['work_total'] ?? 73}',
              ),
              _Metric(
                'Missão completa',
                '${d['overall_concluded'] ?? 0}/${d['overall_total'] ?? 278}',
              ),
            ],
          ),
          const SizedBox(height: 16),
          LinearProgressIndicator(
            value: ((d['progress_percent'] as num?) ?? 0) / 100,
            minHeight: 8,
            borderRadius: BorderRadius.circular(20),
          ),
          const SizedBox(height: 12),
          Text(
            'Controle Master: ${d['progress_percent'] ?? 0}% • Missão completa: ${d['overall_progress_percent'] ?? 0}%',
          ),
          const SizedBox(height: 14),
          Card(
            child: ExpansionTile(
              leading: const Icon(Icons.account_tree_outlined),
              title: Text('Pacotes complementares (${workItems.length})'),
              subtitle: const Text(
                'Entrevistas, MVV, história, organograma, Instagram, páginas futuras, diário, chamados e encerramento.',
              ),
              children: workItems.isEmpty
                  ? const [
                      ListTile(
                        title: Text(
                          'Nenhuma atividade complementar carregada.',
                        ),
                      ),
                    ]
                  : workItems
                        .map(
                          (item) => ListTile(
                            onTap: () => _openWorkItem(item['id'] as int),
                            leading: Icon(
                              item['completed'] == true
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                            ),
                            title: Text(
                              item['title']?.toString() ?? 'Sem título',
                            ),
                            subtitle: Text(
                              '${_sectionLabel(item['section']?.toString() ?? '')} • ${item['status'] ?? 'A fazer'} • linha ${item['spreadsheet_row']}',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                          ),
                        )
                        .toList(),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: search,
            onSubmitted: (_) => _load(),
            decoration: InputDecoration(
              labelText: 'Buscar tarefa',
              hintText: 'Título, lacuna ou ação sugerida',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                onPressed: _load,
                icon: const Icon(Icons.arrow_forward),
              ),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<String?>(
                  initialValue: priority,
                  decoration: const InputDecoration(
                    labelText: 'Prioridade',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('Todas')),
                    DropdownMenuItem(value: 'P0', child: Text('P0')),
                    DropdownMenuItem(value: 'P1', child: Text('P1')),
                    DropdownMenuItem(value: 'P2', child: Text('P2')),
                  ],
                  onChanged: (v) {
                    setState(() => priority = v);
                    _load();
                  },
                ),
              ),
              SizedBox(
                width: 260,
                child: DropdownButtonFormField<String?>(
                  initialValue: stage,
                  decoration: const InputDecoration(
                    labelText: 'Etapa',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('Todas as etapas'),
                    ),
                    ...stages.map(
                      (v) => DropdownMenuItem(value: v, child: Text(v)),
                    ),
                  ],
                  onChanged: (v) {
                    setState(() => stage = v);
                    _load();
                  },
                ),
              ),
              SizedBox(
                width: 210,
                child: DropdownButtonFormField<String?>(
                  initialValue: dueStatus,
                  decoration: const InputDecoration(
                    labelText: 'Prazo',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: null,
                      child: Text('Todos os prazos'),
                    ),
                    DropdownMenuItem(
                      value: 'overdue',
                      child: Text('Atrasados'),
                    ),
                    DropdownMenuItem(
                      value: 'upcoming',
                      child: Text('Próximos 7 dias'),
                    ),
                  ],
                  onChanged: (v) {
                    setState(() => dueStatus = v);
                    _load();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _saveCurrentFilter,
                icon: const Icon(Icons.bookmark_add_outlined),
                label: const Text('Salvar filtros'),
              ),
              OutlinedButton.icon(
                onPressed: _showWeeklyReport,
                icon: const Icon(Icons.summarize_outlined),
                label: const Text('Relatório semanal'),
              ),
              if (savedFilters.isNotEmpty)
                PopupMenuButton<Map<String, dynamic>>(
                  tooltip: 'Aplicar filtro salvo',
                  onSelected: _applySavedFilter,
                  itemBuilder: (context) => savedFilters
                      .map(
                        (filter) => PopupMenuItem(
                          value: filter,
                          child: Text(filter['name']?.toString() ?? 'Sem nome'),
                        ),
                      )
                      .toList(),
                  icon: const Icon(Icons.bookmarks_outlined),
                ),
            ],
          ),
          const SizedBox(height: 18),
          if (loading && tasks.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(30),
                child: CircularProgressIndicator(),
              ),
            )
          else
            ...tasks.map(
              (item) => Card(
                child: ListTile(
                  onTap: () => _openTask(item['id'] as int),
                  leading: CircleAvatar(
                    child: Text(item['priority']?.toString() ?? '?'),
                  ),
                  title: Text(item['title']?.toString() ?? 'Sem título'),
                  subtitle: Text(
                    '${item['content_type'] ?? 'Sem tipo'} • ${item['current_stage'] ?? 'Triagem'}\n'
                    '${item['primary_owner'] ?? 'Não atribuído'} → revisão: ${item['cross_reviewer'] ?? 'Não atribuído'}'
                    '${item['deadline_date'] != null ? ' • prazo ${item['deadline_date']}${item['deadline_status'] == 'overdue'
                              ? ' (atrasado)'
                              : item['deadline_status'] == 'upcoming'
                              ? ' (próximo)'
                              : ''}' : ''}'
                    ' • linha ${item['spreadsheet_row']}',
                  ),
                  isThreeLine: true,
                  trailing: const Icon(Icons.chevron_right),
                ),
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

class MissionTaskDialog extends StatefulWidget {
  const MissionTaskDialog({super.key, required this.taskId});

  final int taskId;

  @override
  State<MissionTaskDialog> createState() => _MissionTaskDialogState();
}

class _MissionTaskDialogState extends State<MissionTaskDialog> {
  Map<String, dynamic>? task;
  bool loading = true;
  bool saving = false;
  String? stage;
  bool publicCheck = false;

  final evidence = TextEditingController();
  final source = TextEditingController();
  final observations = TextEditingController();
  final note = TextEditingController();
  final primaryOwner = TextEditingController();
  final crossReviewer = TextEditingController();
  final internalDeadline = TextEditingController();

  static const stages = _MissionPageState.stages;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    evidence.dispose();
    source.dispose();
    observations.dispose();
    note.dispose();
    primaryOwner.dispose();
    crossReviewer.dispose();
    internalDeadline.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final response = await http.get(
      _uri('/mission-tasks/${widget.taskId}'),
      headers: AppSession.instance.authHeaders,
    );
    if (!mounted) return;
    if (response.statusCode != 200) {
      setState(() => loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_error(response))));
      return;
    }
    final data = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(response.bodyBytes)),
    );
    setState(() {
      task = data;
      stage = data['current_stage']?.toString() ?? 'Triagem';
      publicCheck = data['public_check_ok'] == true;
      evidence.text = data['evidence']?.toString() ?? '';
      source.text = data['confirmed_source']?.toString() ?? '';
      observations.text = data['observations']?.toString() ?? '';
      primaryOwner.text = data['primary_owner']?.toString() ?? '';
      crossReviewer.text = data['cross_reviewer']?.toString() ?? '';
      internalDeadline.text =
          data['deadline_date']?.toString() ??
          data['internal_deadline']?.toString() ??
          '';
      loading = false;
    });
  }

  Future<void> _save() async {
    setState(() => saving = true);
    try {
      final response = await http.patch(
        _uri('/mission-tasks/${widget.taskId}'),
        headers: AppSession.instance.authHeaders,
        body: jsonEncode({
          'current_stage': stage,
          'evidence': evidence.text.trim(),
          'confirmed_source': source.text.trim(),
          'observations': observations.text.trim(),
          'public_check_ok': publicCheck,
          if (AppSession.instance.canReview) ...{
            'primary_owner': primaryOwner.text.trim(),
            'cross_reviewer': crossReviewer.text.trim(),
            'internal_deadline': internalDeadline.text.trim(),
          },
          'consultation_date': DateTime.now().toIso8601String().substring(
            0,
            10,
          ),
          'note': note.text.trim().isEmpty ? null : note.text.trim(),
          'evidence_url': source.text.trim().isEmpty
              ? null
              : source.text.trim(),
        }),
      );
      if (response.statusCode != 200) throw Exception(_error(response));
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Rastreio atualizado.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erro ao salvar: $e')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _check(String kind, int order, bool completed) async {
    final response = await http.patch(
      _uri('/mission-tasks/${widget.taskId}/checklists/$kind/$order'),
      headers: AppSession.instance.authHeaders,
      body: jsonEncode({'completed': completed}),
    );
    if (response.statusCode == 200) {
      await _load();
    } else if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_error(response))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Verificação da missão'),
          leading: IconButton(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.close),
          ),
          actions: [
            FilledButton.icon(
              onPressed: loading || saving ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Salvar'),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : task == null
            ? const Center(child: Text('Tarefa não encontrada.'))
            : _taskBody(context),
      ),
    );
  }

  Widget _taskBody(BuildContext context) {
    final data = task!;
    final checklists = Map<String, dynamic>.from(
      data['checklists'] as Map? ?? {},
    );
    final events = (data['events'] as List<dynamic>? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Wrap(
          spacing: 8,
          children: [
            Chip(label: Text(data['priority']?.toString() ?? '-')),
            Chip(label: Text(data['content_type']?.toString() ?? '-')),
            Chip(label: Text('Linha ${data['spreadsheet_row']}')),
            Chip(label: Text('ID ${data['source_record_id'] ?? '-'}')),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          data['title']?.toString() ?? 'Sem título',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 16),
        _Info('Lacunas', data['gaps']),
        _Info('Ação sugerida', data['action']),
        _Info('Onde buscar', data['where_to_search']),
        _Info('Consulta sugerida', data['suggested_query']),
        _Info('Fontes iniciais', data['sources']),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: stage,
          decoration: const InputDecoration(
            labelText: 'Etapa atual',
            border: OutlineInputBorder(),
          ),
          items: stages
              .map((v) => DropdownMenuItem(value: v, child: Text(v)))
              .toList(),
          onChanged: (v) => setState(() => stage = v),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: primaryOwner,
          enabled: AppSession.instance.canReview,
          decoration: const InputDecoration(
            labelText: 'Responsável principal',
            helperText: 'Somente revisão/coordenação pode alterar este campo.',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: crossReviewer,
          enabled: AppSession.instance.canReview,
          decoration: const InputDecoration(
            labelText: 'Revisor cruzado',
            helperText: 'Somente revisão/coordenação pode alterar este campo.',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: internalDeadline,
          enabled: AppSession.instance.canReview,
          keyboardType: TextInputType.datetime,
          decoration: const InputDecoration(
            labelText: 'Prazo interno (AAAA-MM-DD)',
            helperText: 'Somente revisão/coordenação pode alterar este campo.',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: source,
          decoration: const InputDecoration(
            labelText: 'Fonte confirmada / URL da evidência',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: evidence,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(
            labelText: 'Evidência',
            hintText: 'Registre o que a fonte comprova',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: observations,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(
            labelText: 'Observações / divergências / bloqueios',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: note,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Nota desta atualização',
            border: OutlineInputBorder(),
          ),
        ),
        SwitchListTile(
          value: publicCheck,
          onChanged: (v) => setState(() => publicCheck = v),
          title: const Text('Conferência pública realizada'),
          subtitle: const Text(
            'Marque apenas depois de abrir a página pública e conferir o resultado.',
          ),
        ),
        const Divider(height: 32),
        Text(
          'Checklist de pesquisa',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        ..._checks('pesquisa', checklists['pesquisa']),
        const Divider(height: 32),
        Text(
          'Checklist de publicação',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        ..._checks('publicacao', checklists['publicacao']),
        const Divider(height: 32),
        Text(
          'Histórico do item',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (events.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Ainda não há alterações registradas.'),
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

  List<Widget> _checks(String kind, dynamic raw) {
    final items = (raw as List<dynamic>? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    return items
        .map(
          (item) => CheckboxListTile(
            value: item['completed'] == true,
            onChanged: (v) =>
                _check(kind, item['item_order'] as int, v == true),
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

class _MissionWorkItemDialogState extends State<MissionWorkItemDialog> {
  Map<String, dynamic>? item;
  bool loading = true;
  bool saving = false;
  bool completed = false;

  final status = TextEditingController();
  final evidence = TextEditingController();
  final note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    status.dispose();
    evidence.dispose();
    note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final response = await http.get(
      _uri('/mission-work-items/${widget.workItemId}'),
      headers: AppSession.instance.authHeaders,
    );
    if (!mounted) return;
    if (response.statusCode != 200) {
      setState(() => loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_error(response))));
      return;
    }

    final data = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(response.bodyBytes)),
    );
    setState(() {
      item = data;
      completed = data['completed'] == true;
      status.text = data['status']?.toString() ?? '';
      evidence.text = data['evidence']?.toString() ?? '';
      note.text = data['note']?.toString() ?? '';
      loading = false;
    });
  }

  Future<void> _save() async {
    setState(() => saving = true);
    try {
      final response = await http.patch(
        _uri('/mission-work-items/${widget.workItemId}'),
        headers: AppSession.instance.authHeaders,
        body: jsonEncode({
          'completed': completed,
          'status': status.text.trim().isEmpty
              ? (completed ? 'Concluído' : 'A fazer')
              : status.text.trim(),
          'evidence': evidence.text.trim(),
          'note': note.text.trim(),
        }),
      );
      if (response.statusCode != 200) throw Exception(_error(response));
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Atividade complementar atualizada.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erro ao salvar: $e')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Atividade complementar'),
          leading: IconButton(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.close),
          ),
          actions: [
            FilledButton.icon(
              onPressed: loading || saving ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Salvar'),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : item == null
            ? const Center(child: Text('Atividade não encontrada.'))
            : _body(context),
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
          onChanged: (v) => setState(() => completed = v),
          title: const Text('Atividade concluída'),
          subtitle: const Text(
            'Concluir não apaga o estado anterior; a mudança entra no histórico.',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: status,
          decoration: const InputDecoration(
            labelText: 'Status',
            hintText: 'A fazer, em andamento, aguardando validação...',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: evidence,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'Evidência / link / produto',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: note,
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

import 'dart:convert';

import 'package:flutter/material.dart';
import 'bridge_http.dart' as http;

import 'app_config.dart';
import 'app_session.dart';
import 'session_widgets.dart';
import 'unsaved_work.dart';
import 'workflow_widgets.dart';

Uri _opUri(String path, [Map<String, String>? query]) =>
    AppConfig.endpoint(path).replace(queryParameters: query);

String _opError(http.Response response) {
  try {
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    return data['detail']?.toString() ?? 'Erro HTTP ${response.statusCode}';
  } catch (_) {
    return 'Erro HTTP ${response.statusCode}';
  }
}

class OpportunitiesPage extends StatefulWidget {
  const OpportunitiesPage({super.key});

  @override
  State<OpportunitiesPage> createState() => _OpportunitiesPageState();
}

class _OpportunitiesPageState extends State<OpportunitiesPage> {
  bool loading = false;
  String? loadError;
  int requestVersion = 0;
  late int identityEpoch;
  Map<String, dynamic>? dashboard;
  List<Map<String, dynamic>> sources = const [];
  List<Map<String, dynamic>> items = const [];
  String? status;
  String? category;
  String? deadlineStatus;

  static const categories = [
    'Edital',
    'Chamada para revista',
    'Oportunidade de extensão',
    'Grupo/rede de pesquisa',
    'Bolsa',
    'Evento científico',
    'Notícia institucional',
    'Outro',
  ];

  static const statuses = [
    'novo',
    'em_triagem',
    'verificado',
    'aprovado_pauta',
    'descartado',
    'rascunho_criado',
    'arquivado',
  ];

  @override
  void initState() {
    super.initState();
    identityEpoch = AppSession.instance.identityEpoch;
    AppSession.instance.addListener(_sessionChanged);
    if (AppSession.instance.authenticated) _load();
  }

  @override
  void dispose() {
    AppSession.instance.removeListener(_sessionChanged);
    super.dispose();
  }

  void _sessionChanged() {
    if (!mounted) return;
    requestVersion++;
    if (!AppSession.instance.authenticated ||
        identityEpoch != AppSession.instance.identityEpoch) {
      setState(() {
        dashboard = null;
        sources = const [];
        items = const [];
        loadError = null;
        loading = false;
      });
    }
    identityEpoch = AppSession.instance.identityEpoch;
    if (AppSession.instance.authenticated) _load();
  }

  bool _currentSession(int epoch, String? token) =>
      mounted &&
      AppSession.instance.authenticated &&
      AppSession.instance.identityEpoch == epoch &&
      AppSession.instance.token == token;

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _load() async {
    final session = AppSession.instance;
    if (!session.authenticated) return;
    final epoch = session.identityEpoch;
    final token = session.token;
    final request = ++requestVersion;
    setState(() {
      loading = true;
      loadError = null;
    });
    try {
      final query = <String, String>{
        'limit': '200',
        'status': ?status,
        'category': ?category,
        'deadline_status': ?deadlineStatus,
      };
      final results = await Future.wait([
        http.get(
          _opUri('/opportunities/dashboard'),
          headers: session.authHeaders,
        ),
        http.get(
          _opUri('/opportunities/sources'),
          headers: session.authHeaders,
        ),
        http.get(
          _opUri('/opportunities/items', query),
          headers: session.authHeaders,
        ),
      ]);
      if (!_currentSession(epoch, token) || request != requestVersion) return;
      for (final response in results) {
        if (response.statusCode != 200) throw StateError(_opError(response));
      }
      final sourceData = jsonDecode(utf8.decode(results[1].bodyBytes)) as List;
      final itemPayload = jsonDecode(utf8.decode(results[2].bodyBytes)) as Map;
      setState(() {
        dashboard = Map<String, dynamic>.from(
          jsonDecode(utf8.decode(results[0].bodyBytes)) as Map,
        );
        sources = sourceData
            .whereType<Map>()
            .map((entry) => Map<String, dynamic>.from(entry))
            .toList();
        items = (itemPayload['items'] as List? ?? const [])
            .whereType<Map>()
            .map((entry) => Map<String, dynamic>.from(entry))
            .toList();
      });
    } catch (error) {
      if (_currentSession(epoch, token) && request == requestVersion) {
        setState(() => loadError = workflowError(error));
      }
    } finally {
      if (mounted && request == requestVersion) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> _refreshAll() async {
    setState(() => loading = true);
    try {
      final response = await http.post(
        _opUri('/opportunities/refresh'),
        headers: AppSession.instance.authHeaders,
      );
      if (response.statusCode != 200) {
        _message(_opError(response));
        return;
      }
      final payload = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)),
      );
      final results = payload['sources'] as List<dynamic>? ?? const [];
      final failures = results
          .where((e) => e is Map && e['ok'] == false)
          .length;
      _message(
        failures == 0
            ? 'Fontes atualizadas.'
            : 'Atualização concluída com $failures fonte(s) com erro.',
      );
      await _load();
    } catch (e) {
      _message(workflowError(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _addSource() async {
    final sourceId = await showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AddFeedSourceDialog(),
    );
    if (sourceId != null && mounted) await _refreshSource(sourceId);
  }

  Future<void> _captureManual() async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const ManualOpportunityDialog(),
    );
    if (changed == true && mounted) await _load();
  }

  Future<void> _refreshSource(int sourceId) async {
    if (loading || !AppSession.instance.authenticated) return;
    setState(() => loading = true);
    try {
      final response = await http.post(
        _opUri('/opportunities/sources/$sourceId/refresh'),
        headers: AppSession.instance.authHeaders,
      );
      if (!mounted || !AppSession.instance.authenticated) return;
      if (response.statusCode != 200) throw StateError(_opError(response));
      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
      _message(
        'Fonte conferida: ${data['inserted'] ?? 0} novas oportunidades, '
        '${data['existing'] ?? 0} já conhecidas.',
      );
      await _load();
    } catch (error) {
      _message(workflowError(error));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _openItem(Map<String, dynamic> item) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => OpportunityDialog(itemId: item['id'] as int),
    );
    if (changed == true && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppSession.instance,
      builder: (context, _) {
        if (!AppSession.instance.authenticated) {
          return const SessionPrompt(
            title: 'Oportunidades',
            message:
                'Entre para conferir fontes, organizar chamadas e preparar pautas '
                'para o portal. Cada publicação passa pela revisão editorial.',
          );
        }
        return _content(context);
      },
    );
  }

  Widget _content(BuildContext context) {
    final d = dashboard ?? const <String, dynamic>{};
    final byStatus = Map<String, dynamic>.from(d['by_status'] as Map? ?? {});
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Caixa de oportunidades',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 6),
          const Text(
            'Confira a fonte, o prazo e a relação com o núcleo. '
            'Uma pauta aprovada segue como notícia para revisão.',
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.tonalIcon(
                onPressed: loading ? null : _captureManual,
                icon: const Icon(Icons.add_task_outlined),
                label: const Text('Registrar oportunidade'),
              ),
              OutlinedButton.icon(
                onPressed: loading ? null : _addSource,
                icon: const Icon(Icons.add_link),
                label: const Text('Adicionar fonte'),
              ),
              OutlinedButton.icon(
                onPressed: loading ? null : _refreshAll,
                icon: const Icon(Icons.sync),
                label: const Text('Buscar novidades'),
              ),
            ],
          ),
          if (loadError != null) ...[
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(loadError!),
                    TextButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Tentar novamente'),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _OpMetric('Fontes', '${d['active_sources'] ?? 0}'),
              _OpMetric('Itens', '${d['total_items'] ?? 0}'),
              _OpMetric('Novos', '${byStatus['novo'] ?? 0}'),
              _OpMetric('Em triagem', '${byStatus['em_triagem'] ?? 0}'),
              _OpMetric('Aprovados', '${byStatus['aprovado_pauta'] ?? 0}'),
              _OpMetric('Vencem em 7 dias', '${d['expiring_soon'] ?? 0}'),
              _OpMetric('Duplicidades', '${d['duplicates'] ?? 0}'),
              _OpMetric('Rascunhos', '${byStatus['rascunho_criado'] ?? 0}'),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            'Fontes monitoradas',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          if (sources.isEmpty)
            const Card(
              child: ListTile(
                leading: Icon(Icons.rss_feed),
                title: Text('Nenhuma fonte cadastrada ainda.'),
                subtitle: Text(
                  'Adicione a página oficial de uma instituição ou o endereço RSS/Atom. O sistema tenta descobrir o feed automaticamente.',
                ),
              ),
            )
          else
            ...sources.map(
              (source) => Card(
                child: ListTile(
                  leading: Icon(
                    _sourceHealthIcon(source['health']?.toString()),
                  ),
                  title: Text(source['name']?.toString() ?? 'Fonte'),
                  subtitle: Text(_sourceHealthDescription(source)),
                  trailing: IconButton(
                    tooltip: 'Atualizar esta fonte',
                    onPressed: loading
                        ? null
                        : () => _refreshSource(source['id'] as int),
                    icon: const Icon(Icons.refresh),
                  ),
                ),
              ),
            ),
          const Divider(height: 34),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Itens para curadoria',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (loading) const CircularProgressIndicator(),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              SizedBox(
                width: 250,
                child: DropdownButtonFormField<String?>(
                  isExpanded: true,
                  initialValue: category,
                  decoration: const InputDecoration(
                    labelText: 'Categoria',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('Todas as categorias'),
                    ),
                    ...categories.map(
                      (v) => DropdownMenuItem(value: v, child: Text(v)),
                    ),
                  ],
                  onChanged: (v) {
                    setState(() => category = v);
                    _load();
                  },
                ),
              ),
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String?>(
                  isExpanded: true,
                  initialValue: status,
                  decoration: const InputDecoration(
                    labelText: 'Situação',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('Todas as situações'),
                    ),
                    ...statuses.map(
                      (v) => DropdownMenuItem(
                        value: v,
                        child: Text(_statusLabel(v)),
                      ),
                    ),
                  ],
                  onChanged: (v) {
                    setState(() => status = v);
                    _load();
                  },
                ),
              ),
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String?>(
                  isExpanded: true,
                  initialValue: deadlineStatus,
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
                      value: 'upcoming',
                      child: Text('Vence em 7 dias'),
                    ),
                    DropdownMenuItem(
                      value: 'overdue',
                      child: Text('Prazo vencido'),
                    ),
                  ],
                  onChanged: (v) {
                    setState(() => deadlineStatus = v);
                    _load();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (items.isEmpty)
            const Card(
              child: ListTile(
                leading: Icon(Icons.inbox_outlined),
                title: Text('Nenhuma oportunidade com estes filtros.'),
              ),
            )
          else
            ...items.map(
              (item) => Card(
                child: ListTile(
                  onTap: () => _openItem(item),
                  leading: const Icon(Icons.campaign_outlined),
                  title: Text(item['title']?.toString() ?? 'Sem título'),
                  subtitle: Text(
                    '${item['category']} • ${_statusLabel(item['status']?.toString() ?? '')}\n'
                    'Fonte: ${item['source_name'] ?? ''}${_itemDeadline(item)}${item['is_duplicate'] == true ? ' • Duplicidade detectada' : ''}',
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

String _statusLabel(String value) {
  const labels = {
    'novo': 'Novo',
    'em_triagem': 'Em triagem',
    'verificado': 'Fonte verificada',
    'aprovado_pauta': 'Pauta aprovada',
    'descartado': 'Descartado',
    'rascunho_criado': 'Rascunho criado',
    'arquivado': 'Arquivado',
  };
  return labels[value] ?? value;
}

String _itemDeadline(Map<String, dynamic> item) {
  final deadline = item['deadline_at']?.toString();
  return deadline == null || deadline.isEmpty ? '' : ' • Prazo: $deadline';
}

IconData _sourceHealthIcon(String? health) {
  switch (health) {
    case 'healthy':
      return Icons.rss_feed;
    case 'stale':
      return Icons.schedule_outlined;
    case 'error':
      return Icons.error_outline;
    default:
      return Icons.hourglass_empty;
  }
}

String _sourceHealthDescription(Map<String, dynamic> source) {
  final health = source['health']?.toString();
  final base =
      source['feed_url']?.toString() ?? source['url']?.toString() ?? '';
  if (health == 'error') {
    return 'Erro: ${source['last_error'] ?? 'falha desconhecida'}';
  }
  const labels = {
    'healthy': 'Saudável',
    'stale': 'Sem atualização há mais de 7 dias',
    'pending': 'Ainda não atualizada',
  };
  return '${labels[health] ?? 'Estado desconhecido'} • $base';
}

class _OpMetric extends StatelessWidget {
  const _OpMetric(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 145,
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

class ManualOpportunityDialog extends StatelessWidget {
  const ManualOpportunityDialog({super.key});
  @override
  Widget build(BuildContext context) =>
      const _OpportunityInputDialog(sourceMode: false);
}

class AddFeedSourceDialog extends StatelessWidget {
  const AddFeedSourceDialog({super.key});
  @override
  Widget build(BuildContext context) =>
      const _OpportunityInputDialog(sourceMode: true);
}

Future<bool> _confirmDiscard(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Descartar as alterações?'),
        content: const Text(
          'Este preenchimento ainda não foi salvo. Você pode voltar para concluí-lo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Continuar preenchendo'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Descartar e fechar'),
          ),
        ],
      ),
    ) ??
    false;

bool _validWebUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host.isNotEmpty;
}

String? _deadlineError(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return null;
  final date = DateTime.tryParse(text);
  if (date == null || text.length < 10) {
    return 'Use uma data válida no formato AAAA-MM-DD ou deixe em branco.';
  }
  final expected = date.toIso8601String().substring(0, 10);
  if (text.length == 10 && text.substring(0, 10) != expected) {
    return 'Confira o dia e o mês informados.';
  }
  return null;
}

class _OpportunityInputDialog extends StatefulWidget {
  const _OpportunityInputDialog({required this.sourceMode});
  final bool sourceMode;

  @override
  State<_OpportunityInputDialog> createState() =>
      _OpportunityInputDialogState();
}

class _OpportunityInputDialogState extends State<_OpportunityInputDialog> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _url = TextEditingController();
  final _summary = TextEditingController();
  final _deadline = TextEditingController();
  late int _identityEpoch;
  String? _category;
  String? _error;
  bool _busy = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _category = widget.sourceMode ? null : 'Edital';
    _identityEpoch = AppSession.instance.identityEpoch;
    for (final controller in [_title, _url, _summary, _deadline]) {
      controller.addListener(_trackChanges);
    }
    AppSession.instance.addListener(_sessionChanged);
  }

  @override
  void dispose() {
    AppSession.instance.removeListener(_sessionChanged);
    UnsavedWork.instance.remove(this);
    for (final controller in [_title, _url, _summary, _deadline]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _sessionChanged() {
    if (!mounted) return;
    if (_identityEpoch != AppSession.instance.identityEpoch) {
      _identityEpoch = AppSession.instance.identityEpoch;
      _title.clear();
      _url.clear();
      _summary.clear();
      _deadline.clear();
      _category = widget.sourceMode ? null : 'Edital';
      _error = null;
      _trackChanges();
    }
    setState(() {});
  }

  void _trackChanges() {
    final changed =
        [
          _title,
          _url,
          _summary,
          _deadline,
        ].any((controller) => controller.text.isNotEmpty) ||
        _category != (widget.sourceMode ? null : 'Edital');
    if (changed != _dirty && mounted) setState(() => _dirty = changed);
    UnsavedWork.instance.setDirty(this, changed);
  }

  Future<void> _close() async {
    if (_busy) return;
    if (_dirty && !await _confirmDiscard(context)) return;
    if (mounted) Navigator.pop(context);
  }

  Future<void> _save() async {
    if (_busy ||
        !AppSession.instance.authenticated ||
        !(_form.currentState?.validate() ?? false)) {
      return;
    }
    final session = AppSession.instance;
    final epoch = session.identityEpoch;
    final token = session.token;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final payload = widget.sourceMode
          ? <String, dynamic>{
              'name': _title.text.trim(),
              'url': _url.text.trim(),
              'default_category': _category,
            }
          : <String, dynamic>{
              'title': _title.text.trim(),
              'url': _url.text.trim(),
              'category': _category,
              'summary': _summary.text.trim().isEmpty
                  ? null
                  : _summary.text.trim(),
              'deadline_at': _deadline.text.trim().isEmpty
                  ? null
                  : _deadline.text.trim(),
            };
      final response = await http.post(
        _opUri(
          widget.sourceMode
              ? '/opportunities/sources'
              : '/opportunities/items/manual',
        ),
        headers: session.authHeaders,
        body: jsonEncode(payload),
      );
      if (!mounted ||
          !session.authenticated ||
          session.identityEpoch != epoch ||
          session.token != token) {
        return;
      }
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw StateError(_opError(response));
      }
      final result = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
      _dirty = false;
      UnsavedWork.instance.setDirty(this, false);
      Navigator.pop(context, widget.sourceMode ? result['id'] as int : true);
    } catch (error) {
      if (mounted && session.authenticated && session.identityEpoch == epoch) {
        setState(
          () =>
              _error = 'Seu preenchimento foi mantido. ${workflowError(error)}',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy && !_dirty,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) _close();
    },
    child: AlertDialog(
      title: Text(
        widget.sourceMode
            ? 'Adicionar fonte institucional'
            : 'Registrar oportunidade',
      ),
      content: SizedBox(
        width: 600,
        child: !AppSession.instance.authenticated
            ? const SizedBox(
                height: 360,
                child: SessionPrompt(
                  title: 'Entre para continuar',
                  message:
                      'O preenchimento fica disponível ao retomar a mesma conta.',
                ),
              )
            : SingleChildScrollView(
                child: Form(
                  key: _form,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.sourceMode
                            ? 'Informe uma instituição e sua página oficial ou feed. '
                                  'As novidades entram para curadoria da equipe.'
                            : 'Registre a fonte original. A equipe confere os dados '
                                  'antes de preparar a notícia no portal.',
                      ),
                      const SizedBox(height: 18),
                      TextFormField(
                        controller: _title,
                        enabled: !_busy,
                        validator: (value) => (value?.trim().length ?? 0) < 3
                            ? 'Escreva um nome com pelo menos 3 caracteres.'
                            : null,
                        decoration: InputDecoration(
                          labelText: widget.sourceMode
                              ? 'Nome da instituição ou fonte'
                              : 'Título da oportunidade',
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _url,
                        enabled: !_busy,
                        validator: (value) => _validWebUrl(value ?? '')
                            ? null
                            : 'Informe o endereço completo, começando com https://.',
                        decoration: const InputDecoration(
                          labelText: 'Link da fonte oficial',
                          hintText: 'https://...',
                        ),
                      ),
                      const SizedBox(height: 14),
                      DropdownButtonFormField<String?>(
                        isExpanded: true,
                        initialValue: _category,
                        decoration: const InputDecoration(
                          labelText: 'Categoria',
                        ),
                        items: [
                          if (widget.sourceMode)
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text('Classificar na coleta'),
                            ),
                          ..._OpportunitiesPageState.categories.map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(value),
                            ),
                          ),
                        ],
                        onChanged: _busy
                            ? null
                            : (value) {
                                setState(() => _category = value);
                                _trackChanges();
                              },
                      ),
                      if (!widget.sourceMode) ...[
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _summary,
                          enabled: !_busy,
                          minLines: 3,
                          maxLines: 6,
                          decoration: const InputDecoration(
                            labelText: 'Por que interessa ao NERUDS?',
                            helperText:
                                'Público, área e relação com pesquisa ou extensão.',
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _deadline,
                          enabled: !_busy,
                          validator: _deadlineError,
                          decoration: const InputDecoration(
                            labelText: 'Prazo confirmado, se houver',
                            hintText: 'AAAA-MM-DD',
                          ),
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : _close,
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _busy || !AppSession.instance.authenticated ? null : _save,
          child: Text(
            _busy
                ? 'Salvando...'
                : widget.sourceMode
                ? 'Salvar fonte'
                : 'Enviar para triagem',
          ),
        ),
      ],
    ),
  );
}

class OpportunityDialog extends StatefulWidget {
  const OpportunityDialog({super.key, required this.itemId});
  final int itemId;

  @override
  State<OpportunityDialog> createState() => _OpportunityDialogState();
}

class _OpportunityDialogState extends State<OpportunityDialog> {
  final _form = GlobalKey<FormState>();
  final note = TextEditingController();
  final deadline = TextEditingController();
  Map<String, dynamic>? item;
  bool loading = true;
  bool actionBusy = false;
  bool _dirty = false;
  bool _applying = false;
  late int _identityEpoch;
  int _requestVersion = 0;
  String? _loadError;
  String? category;
  Set<String> fitTags = {};
  String _savedNote = '';
  String _savedDeadline = '';
  String? _savedCategory;
  Set<String> _savedFitTags = {};

  static const availableFitTags = [
    'ensino',
    'pesquisa',
    'extensão',
    'inovação',
    'interdisciplinaridade',
    'território',
    'formação',
    'rede de colaboração',
  ];

  bool get _linked =>
      item?['drupal_draft_id'] != null || item?['status'] == 'rascunho_criado';

  @override
  void initState() {
    super.initState();
    _identityEpoch = AppSession.instance.identityEpoch;
    note.addListener(_trackChanges);
    deadline.addListener(_trackChanges);
    AppSession.instance.addListener(_sessionChanged);
    _load();
  }

  @override
  void dispose() {
    AppSession.instance.removeListener(_sessionChanged);
    UnsavedWork.instance.remove(this);
    note.dispose();
    deadline.dispose();
    super.dispose();
  }

  void _sessionChanged() {
    if (!mounted) return;
    _requestVersion++;
    if (_identityEpoch != AppSession.instance.identityEpoch) {
      _identityEpoch = AppSession.instance.identityEpoch;
      _applying = true;
      note.clear();
      deadline.clear();
      _applying = false;
      _dirty = false;
      item = null;
      category = null;
      fitTags = {};
      UnsavedWork.instance.setDirty(this, false);
    }
    setState(() {});
    if (AppSession.instance.authenticated) _load();
  }

  bool _sameSession(int epoch, String? token) =>
      mounted &&
      AppSession.instance.authenticated &&
      AppSession.instance.identityEpoch == epoch &&
      AppSession.instance.token == token;

  void _trackChanges() {
    if (_applying || !mounted) return;
    final changed =
        note.text != _savedNote ||
        deadline.text != _savedDeadline ||
        category != _savedCategory ||
        fitTags.length != _savedFitTags.length ||
        !fitTags.containsAll(_savedFitTags);
    if (changed != _dirty) setState(() => _dirty = changed);
    UnsavedWork.instance.setDirty(this, changed);
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _load({bool replaceEdits = false}) async {
    final session = AppSession.instance;
    if (!session.authenticated) return;
    final epoch = session.identityEpoch;
    final token = session.token;
    final request = ++_requestVersion;
    setState(() {
      loading = true;
      _loadError = null;
    });
    try {
      final response = await http.get(
        _opUri('/opportunities/items/${widget.itemId}'),
        headers: session.authHeaders,
      );
      if (!_sameSession(epoch, token) || request != _requestVersion) return;
      if (response.statusCode != 200) throw StateError(_opError(response));
      final data = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map,
      );
      setState(() {
        item = data;
        if (!_dirty || replaceEdits) {
          _applying = true;
          category = data['category']?.toString();
          note.text = data['decision_note']?.toString() ?? '';
          deadline.text = data['deadline_at']?.toString() ?? '';
          fitTags = (data['fit_tags'] as List? ?? const [])
              .map((tag) => tag.toString())
              .toSet();
          _savedNote = note.text;
          _savedDeadline = deadline.text;
          _savedCategory = category;
          _savedFitTags = Set.of(fitTags);
          _dirty = false;
          _applying = false;
          UnsavedWork.instance.setDirty(this, false);
        }
      });
    } catch (error) {
      if (_sameSession(epoch, token) && request == _requestVersion) {
        setState(() => _loadError = workflowError(error));
      }
    } finally {
      if (mounted && request == _requestVersion) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> _close() async {
    if (actionBusy) return;
    if (_dirty && !await _confirmDiscard(context)) return;
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _decide(String status) async {
    if (actionBusy || _linked || !AppSession.instance.authenticated) return;
    if (status == 'aprovado_pauta' && !AppSession.instance.canReview) return;
    if (!(_form.currentState?.validate() ?? false)) return;
    final session = AppSession.instance;
    final epoch = session.identityEpoch;
    final token = session.token;
    setState(() => actionBusy = true);
    try {
      final response = await http.patch(
        _opUri('/opportunities/items/${widget.itemId}/decision'),
        headers: session.authHeaders,
        body: jsonEncode({
          'status': status,
          'note': note.text.trim().isEmpty ? null : note.text.trim(),
          'category': category,
          'deadline_at': deadline.text.trim(),
          'fit_tags': fitTags.toList(),
        }),
      );
      if (!_sameSession(epoch, token)) return;
      if (response.statusCode != 200) throw StateError(_opError(response));
      _message('Curadoria salva: ${_statusLabel(status)}.');
      await _load(replaceEdits: true);
    } catch (error) {
      if (_sameSession(epoch, token)) {
        _message('As alterações foram mantidas. ${workflowError(error)}');
      }
    } finally {
      if (mounted) setState(() => actionBusy = false);
    }
  }

  Future<void> _createDraft() async {
    if (actionBusy ||
        _linked ||
        _dirty ||
        item?['status'] != 'aprovado_pauta' ||
        item?['is_duplicate'] == true ||
        !AppSession.instance.authenticated) {
      return;
    }
    final session = AppSession.instance;
    final epoch = session.identityEpoch;
    final token = session.token;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Preparar notícia para revisão?'),
        content: Text(
          'A pauta “${item?['title'] ?? ''}” será enviada como rascunho '
          'ao portal NERUDS. O vínculo com esta oportunidade será preservado.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Voltar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Criar rascunho vinculado'),
          ),
        ],
      ),
    );
    if (confirmed != true || !_sameSession(epoch, token) || _linked) return;
    setState(() => actionBusy = true);
    try {
      final response = await http.post(
        _opUri('/opportunities/items/${widget.itemId}/draft'),
        headers: session.authHeaders,
      );
      if (!_sameSession(epoch, token)) return;
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw StateError(_opError(response));
      }
      final created = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map,
      );
      if (created['drupal_draft_id'] != null) {
        setState(() => item = {...?item, ...created});
      }
      _message(
        'Rascunho vinculado à pauta. Continue na ficha para revisar o texto.',
      );
      await _load(replaceEdits: true);
    } catch (error) {
      if (_sameSession(epoch, token)) {
        _message(workflowError(error));
        await _load();
      }
    } finally {
      if (mounted) setState(() => actionBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_dirty && !actionBusy,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) _close();
    },
    child: Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Curadoria da oportunidade'),
          leading: IconButton(
            tooltip: 'Fechar curadoria',
            onPressed: actionBusy ? null : _close,
            icon: const Icon(Icons.close),
          ),
        ),
        body: !AppSession.instance.authenticated
            ? const SessionPrompt(
                title: 'Entre para continuar a curadoria',
                message: 'Suas alterações permanecem ao retomar a mesma conta.',
              )
            : loading && item == null
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null && item == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_loadError!),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Tentar novamente'),
                      ),
                    ],
                  ),
                ),
              )
            : item == null
            ? const Center(
                child: Text(
                  'A oportunidade não está disponível para esta conta.',
                ),
              )
            : _body(context),
      ),
    ),
  );

  Widget _body(BuildContext context) {
    final data = item!;
    final status = data['status']?.toString() ?? 'novo';
    final events = (data['events'] as List? ?? const []).whereType<Map>();
    final editable = !actionBusy && !_linked;
    return Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (loading) const LinearProgressIndicator(),
          if (_loadError != null) ...[
            Text(
              _loadError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            TextButton.icon(
              onPressed: actionBusy ? null : _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Atualizar ficha'),
            ),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(label: Text(data['source_name']?.toString() ?? 'Fonte')),
              Chip(label: Text(_statusLabel(status))),
              if (data['is_duplicate'] == true)
                const Chip(
                  avatar: Icon(Icons.copy_outlined, size: 18),
                  label: Text('Possível duplicidade'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            data['title']?.toString() ?? 'Sem título',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          SelectableText(data['summary']?.toString() ?? ''),
          const SizedBox(height: 8),
          PortalLinkButton(
            label: 'Consultar fonte original',
            url: data['url']?.toString(),
          ),
          if (_linked) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Esta pauta já tem uma ficha no portal',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Continue a redação e a revisão na ficha existente. '
                      'A situação de publicação deve ser conferida no portal.',
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        PortalLinkButton(
                          label: 'Abrir ficha para revisão',
                          url: data['edit_url']?.toString(),
                          editing: true,
                        ),
                        PortalLinkButton(
                          label: 'Consultar página no portal',
                          url: data['public_url']?.toString(),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          Text(
            'Conferência da pauta',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'A fonte sustenta o fato; a curadoria registra a relevância para o núcleo. '
            'A aprovação da pauta antecede a revisão da notícia.',
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            key: ValueKey('op-category-$_identityEpoch-$_savedCategory'),
            isExpanded: true,
            initialValue: _OpportunitiesPageState.categories.contains(category)
                ? category
                : null,
            decoration: const InputDecoration(labelText: 'Categoria editorial'),
            items: _OpportunitiesPageState.categories
                .map(
                  (value) => DropdownMenuItem(value: value, child: Text(value)),
                )
                .toList(),
            onChanged: editable
                ? (value) {
                    setState(() => category = value);
                    _trackChanges();
                  }
                : null,
          ),
          const SizedBox(height: 14),
          TextFormField(
            key: const Key('op-deadline'),
            controller: deadline,
            enabled: editable,
            validator: _deadlineError,
            decoration: InputDecoration(
              labelText: 'Prazo confirmado, se houver',
              hintText: 'AAAA-MM-DD',
              helperText:
                  'Deixe em branco para remover um prazo incorreto. '
                  'Registre a correção na decisão.',
              helperMaxLines: 3,
              suffixIcon: IconButton(
                tooltip: 'Limpar prazo',
                onPressed: editable ? deadline.clear : null,
                icon: const Icon(Icons.clear),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'Relação com o NERUDS',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: availableFitTags
                .map(
                  (tag) => FilterChip(
                    label: Text(tag),
                    selected: fitTags.contains(tag),
                    onSelected: editable
                        ? (selected) {
                            setState(
                              () => selected
                                  ? fitTags.add(tag)
                                  : fitTags.remove(tag),
                            );
                            _trackChanges();
                          }
                        : null,
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 14),
          TextFormField(
            key: const Key('op-note'),
            controller: note,
            enabled: editable,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'Nota da curadoria',
              hintText:
                  'Registre a fonte conferida, o público, a decisão e a próxima ação.',
            ),
          ),
          if (!_linked) ...[
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed: editable ? () => _decide('em_triagem') : null,
                  icon: const Icon(Icons.manage_search),
                  label: const Text('Salvar em triagem'),
                ),
                OutlinedButton.icon(
                  onPressed: editable ? () => _decide('verificado') : null,
                  icon: const Icon(Icons.verified_outlined),
                  label: const Text('Confirmar fonte'),
                ),
                if (AppSession.instance.canReview)
                  FilledButton.icon(
                    onPressed: editable
                        ? () => _decide('aprovado_pauta')
                        : null,
                    icon: const Icon(Icons.thumb_up_alt_outlined),
                    label: const Text('Aprovar como pauta'),
                  ),
                OutlinedButton.icon(
                  onPressed: editable ? () => _decide('descartado') : null,
                  icon: const Icon(Icons.block_outlined),
                  label: const Text('Descartar pauta'),
                ),
              ],
            ),
            if (_dirty) ...[
              const SizedBox(height: 10),
              const Text(
                'Alterações ainda não salvas. Registre a decisão para continuar.',
              ),
            ],
          ],
          if (!_linked &&
              status == 'aprovado_pauta' &&
              data['is_duplicate'] != true) ...[
            const SizedBox(height: 18),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Pauta aprovada. O próximo passo prepara a notícia para revisão.',
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: actionBusy || _dirty ? null : _createDraft,
                      icon: const Icon(Icons.article_outlined),
                      label: const Text('Preparar rascunho de notícia'),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (!_linked && data['is_duplicate'] == true) ...[
            const SizedBox(height: 18),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Confira a oportunidade de referência antes de continuar.',
                    ),
                    if (data['duplicate_of_item_id'] is int)
                      TextButton.icon(
                        onPressed: actionBusy
                            ? null
                            : () async {
                                if (!context.mounted) return;
                                await showDialog<bool>(
                                  context: context,
                                  barrierDismissible: false,
                                  builder: (_) => OpportunityDialog(
                                    itemId: data['duplicate_of_item_id'] as int,
                                  ),
                                );
                              },
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('Abrir oportunidade de referência'),
                      ),
                  ],
                ),
              ),
            ),
          ],
          const Divider(height: 34),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('Histórico de decisões (${events.length})'),
            children: events
                .map(
                  (event) => ListTile(
                    leading: const Icon(Icons.history),
                    title: Text(
                      '${_statusLabel(event['event_type']?.toString() ?? '')} · '
                      '${event['actor'] ?? 'Equipe'}',
                    ),
                    subtitle: Text(
                      '${event['created_at'] ?? ''}\n${event['note'] ?? ''}',
                    ),
                  ),
                )
                .toList(),
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Referência do acompanhamento'),
            children: [
              ListTile(
                dense: true,
                title: Text('Oportunidade ${widget.itemId}'),
                subtitle: Text(
                  [
                    if (data['drupal_draft_id'] != null)
                      'Ficha no portal: ${data['drupal_draft_id']}',
                    if (data['duplicate_of_item_id'] != null)
                      'Referência: ${data['duplicate_of_item_id']}',
                  ].join(' · '),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

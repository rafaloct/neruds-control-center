import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'app_session.dart';

const _opBridgeUrl = String.fromEnvironment(
  'NERUDS_BRIDGE_URL',
  defaultValue: 'https://largeo.tail2faed0.ts.net:8443',
);

Uri _opUri(String path, [Map<String, String>? query]) {
  final base = _opBridgeUrl.endsWith('/')
      ? _opBridgeUrl.substring(0, _opBridgeUrl.length - 1)
      : _opBridgeUrl;
  return Uri.parse('$base$path').replace(queryParameters: query);
}

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
    if (AppSession.instance.authenticated) {
      _load();
    } else {
      setState(() {
        dashboard = null;
        sources = const [];
        items = const [];
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
      final query = <String, String>{'limit': '200'};
      if (status case final value?) query['status'] = value;
      if (category case final value?) query['category'] = value;
      if (deadlineStatus case final value?) {
        query['deadline_status'] = value;
      }
      final results = await Future.wait([
        http.get(
          _opUri('/opportunities/dashboard'),
          headers: AppSession.instance.authHeaders,
        ),
        http.get(
          _opUri('/opportunities/sources'),
          headers: AppSession.instance.authHeaders,
        ),
        http.get(
          _opUri('/opportunities/items', query),
          headers: AppSession.instance.authHeaders,
        ),
      ]);

      if (results.any((r) => r.statusCode == 401)) {
        AppSession.instance.clear();
        _message('Sessão expirada. Entre novamente na aba Conteúdo.');
        return;
      }
      for (final response in results) {
        if (response.statusCode != 200) {
          _message(_opError(response));
          return;
        }
      }

      final d = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(results[0].bodyBytes)),
      );
      final sourceData =
          jsonDecode(utf8.decode(results[1].bodyBytes)) as List<dynamic>;
      final itemPayload = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(results[2].bodyBytes)),
      );
      final feedItems = (itemPayload['items'] as List<dynamic>? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      if (mounted) {
        setState(() {
          dashboard = d;
          sources = sourceData
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          items = feedItems;
        });
      }
    } catch (e) {
      _message('Não foi possível carregar oportunidades: $e');
    } finally {
      if (mounted) setState(() => loading = false);
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
      _message('Erro ao atualizar fontes: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _addSource() async {
    final result = await showDialog<Map<String, String?>>(
      context: context,
      builder: (_) => const AddFeedSourceDialog(),
    );
    if (result == null) return;

    final response = await http.post(
      _opUri('/opportunities/sources'),
      headers: AppSession.instance.authHeaders,
      body: jsonEncode(result),
    );
    if (response.statusCode != 200) {
      _message(_opError(response));
      return;
    }
    final source = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(response.bodyBytes)),
    );
    _message('Fonte cadastrada. Vou procurar RSS/Atom ao atualizar.');
    await _refreshSource(source['id'] as int);
  }

  Future<void> _captureManual() async {
    final result = await showDialog<Map<String, String?>>(
      context: context,
      builder: (_) => const ManualOpportunityDialog(),
    );
    if (result == null) return;

    final response = await http.post(
      _opUri('/opportunities/items/manual'),
      headers: AppSession.instance.authHeaders,
      body: jsonEncode(result),
    );
    if (response.statusCode != 200) {
      _message(_opError(response));
      return;
    }
    _message('Oportunidade capturada para triagem humana.');
    await _load();
  }

  Future<void> _refreshSource(int sourceId) async {
    final response = await http.post(
      _opUri('/opportunities/sources/$sourceId/refresh'),
      headers: AppSession.instance.authHeaders,
    );
    if (response.statusCode == 200) {
      final data = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)),
      );
      _message(
        'Fonte processada: ${data['inserted'] ?? 0} nova(s), ${data['existing'] ?? 0} já conhecida(s).',
      );
      await _load();
    } else {
      _message(_opError(response));
      await _load();
    }
  }

  Future<void> _openItem(Map<String, dynamic> item) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => OpportunityDialog(itemId: item['id'] as int),
    );
    if (changed == true) await _load();
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
                'Oportunidades',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              const Card(
                child: ListTile(
                  leading: Icon(Icons.lock_outline),
                  title: Text('Entre no portal para fazer curadoria'),
                  subtitle: Text(
                    'RSS e Atom alimentam apenas uma caixa de sugestões. Nenhum item é publicado automaticamente.',
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
    final byStatus = Map<String, dynamic>.from(d['by_status'] as Map? ?? {});
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Caixa de oportunidades',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Editais, chamadas de revistas, extensão, bolsas, eventos e redes de pesquisa entram para triagem humana.',
                    ),
                  ],
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: loading ? null : _captureManual,
                icon: const Icon(Icons.add_task_outlined),
                label: const Text('Capturar URL'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: loading ? null : _addSource,
                icon: const Icon(Icons.add_link),
                label: const Text('Adicionar fonte'),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Buscar novidades em todas as fontes',
                onPressed: loading ? null : _refreshAll,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
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
                    onPressed: () => _refreshSource(source['id'] as int),
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

class ManualOpportunityDialog extends StatefulWidget {
  const ManualOpportunityDialog({super.key});

  @override
  State<ManualOpportunityDialog> createState() =>
      _ManualOpportunityDialogState();
}

class _ManualOpportunityDialogState extends State<ManualOpportunityDialog> {
  final title = TextEditingController();
  final url = TextEditingController();
  final summary = TextEditingController();
  final deadline = TextEditingController();
  String category = 'Edital';

  @override
  void dispose() {
    title.dispose();
    url.dispose();
    summary.dispose();
    deadline.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Capturar oportunidade oficial'),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Use quando a instituição não oferecer RSS/Atom. A URL entra como sugestão e ainda precisa ser verificada e aprovada.',
              ),
              const SizedBox(height: 14),
              TextField(
                controller: title,
                decoration: const InputDecoration(
                  labelText: 'Título da oportunidade',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: url,
                decoration: const InputDecoration(
                  labelText: 'URL da fonte oficial',
                  hintText: 'https://...',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: category,
                decoration: const InputDecoration(
                  labelText: 'Categoria',
                  border: OutlineInputBorder(),
                ),
                items: _OpportunitiesPageState.categories
                    .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                    .toList(),
                onChanged: (v) => setState(() => category = v ?? category),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: summary,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'Resumo / por que pode interessar ao NERUDS',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: deadline,
                decoration: const InputDecoration(
                  labelText: 'Prazo de inscrição/publicação (opcional)',
                  hintText: 'AAAA-MM-DD',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            if (title.text.trim().length < 3 ||
                !url.text.trim().startsWith('http')) {
              return;
            }
            Navigator.pop(context, {
              'title': title.text.trim(),
              'url': url.text.trim(),
              'category': category,
              'summary': summary.text.trim().isEmpty
                  ? null
                  : summary.text.trim(),
              'deadline_at': deadline.text.trim().isEmpty
                  ? null
                  : deadline.text.trim(),
            });
          },
          child: const Text('Enviar para triagem'),
        ),
      ],
    );
  }
}

class AddFeedSourceDialog extends StatefulWidget {
  const AddFeedSourceDialog({super.key});

  @override
  State<AddFeedSourceDialog> createState() => _AddFeedSourceDialogState();
}

class _AddFeedSourceDialogState extends State<AddFeedSourceDialog> {
  final name = TextEditingController();
  final url = TextEditingController();
  String? category;

  @override
  void dispose() {
    name.dispose();
    url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Adicionar fonte institucional'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(
                labelText: 'Nome da fonte',
                hintText: 'Ex.: Pró-Reitoria, agência de fomento, revista',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: url,
              decoration: const InputDecoration(
                labelText: 'Página oficial ou RSS/Atom',
                hintText: 'https://...',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: category,
              decoration: const InputDecoration(
                labelText: 'Categoria padrão, se houver',
              ),
              items: [
                const DropdownMenuItem(
                  value: null,
                  child: Text('Classificar automaticamente'),
                ),
                ..._OpportunitiesPageState.categories.map(
                  (v) => DropdownMenuItem(value: v, child: Text(v)),
                ),
              ],
              onChanged: (v) => setState(() => category = v),
            ),
            const SizedBox(height: 12),
            const Text(
              'Use fontes oficiais. O sistema não aceita endereços privados da rede e não publica conteúdo automaticamente.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            if (name.text.trim().length < 2 || url.text.trim().isEmpty) return;
            Navigator.pop(context, {
              'name': name.text.trim(),
              'url': url.text.trim(),
              'default_category': category,
            });
          },
          child: const Text('Adicionar'),
        ),
      ],
    );
  }
}

class OpportunityDialog extends StatefulWidget {
  const OpportunityDialog({super.key, required this.itemId});

  final int itemId;

  @override
  State<OpportunityDialog> createState() => _OpportunityDialogState();
}

class _OpportunityDialogState extends State<OpportunityDialog> {
  Map<String, dynamic>? item;
  bool loading = true;
  bool actionBusy = false;
  final note = TextEditingController();
  final deadline = TextEditingController();
  String? category;
  Set<String> fitTags = {};

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    note.dispose();
    deadline.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final response = await http.get(
      _opUri('/opportunities/items/${widget.itemId}'),
      headers: AppSession.instance.authHeaders,
    );
    if (!mounted) return;
    if (response.statusCode != 200) {
      setState(() => loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_opError(response))));
      return;
    }
    final data = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(response.bodyBytes)),
    );
    setState(() {
      item = data;
      category = data['category']?.toString();
      note.text = data['decision_note']?.toString() ?? '';
      deadline.text = data['deadline_at']?.toString() ?? '';
      fitTags = (data['fit_tags'] as List<dynamic>? ?? const [])
          .map((tag) => tag.toString())
          .toSet();
      loading = false;
    });
  }

  Future<void> _decide(String status) async {
    setState(() => actionBusy = true);
    try {
      final response = await http.patch(
        _opUri('/opportunities/items/${widget.itemId}/decision'),
        headers: AppSession.instance.authHeaders,
        body: jsonEncode({
          'status': status,
          'note': note.text.trim().isEmpty ? null : note.text.trim(),
          'category': category,
          'deadline_at': deadline.text.trim().isEmpty
              ? null
              : deadline.text.trim(),
          'fit_tags': fitTags.toList(),
        }),
      );
      if (response.statusCode != 200) throw Exception(_opError(response));
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erro: $e')));
      }
    } finally {
      if (mounted) setState(() => actionBusy = false);
    }
  }

  Future<void> _createDraft() async {
    setState(() => actionBusy = true);
    try {
      final response = await http.post(
        _opUri('/opportunities/items/${widget.itemId}/draft'),
        headers: AppSession.instance.authHeaders,
      );
      if (response.statusCode != 200) throw Exception(_opError(response));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Rascunho criado no Drupal. Ainda precisa de revisão editorial.',
          ),
        ),
      );
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erro: $e')));
      }
    } finally {
      if (mounted) setState(() => actionBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Curadoria da oportunidade'),
          leading: IconButton(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.close),
          ),
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : item == null
            ? const Center(child: Text('Item não encontrado.'))
            : _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final data = item!;
    final status = data['status']?.toString() ?? 'novo';
    final events = (data['events'] as List<dynamic>? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(label: Text(data['source_name']?.toString() ?? 'Fonte')),
            Chip(label: Text(_statusLabel(status))),
            if (data['source_verified'] == true)
              const Chip(
                avatar: Icon(Icons.verified_outlined, size: 18),
                label: Text('Origem RSS verificada'),
              ),
            if (data['is_duplicate'] == true)
              const Chip(
                avatar: Icon(Icons.copy_outlined, size: 18),
                label: Text('Duplicidade detectada'),
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
        const SizedBox(height: 12),
        const Text('Fonte original'),
        SelectableText(data['url']?.toString() ?? ''),
        if (data['duplicate_of_item_id'] != null) ...[
          const SizedBox(height: 8),
          Text(
            'Item de referência: #${data['duplicate_of_item_id']} (${data['duplicate_reason']})',
          ),
        ],
        const SizedBox(height: 18),
        DropdownButtonFormField<String>(
          initialValue: category,
          decoration: const InputDecoration(
            labelText: 'Categoria editorial',
            border: OutlineInputBorder(),
          ),
          items: _OpportunitiesPageState.categories
              .map((v) => DropdownMenuItem(value: v, child: Text(v)))
              .toList(),
          onChanged: (v) => setState(() => category = v),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: deadline,
          decoration: const InputDecoration(
            labelText: 'Prazo de inscrição/publicação',
            hintText: 'AAAA-MM-DD',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Aderência ao NERUDS',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: availableFitTags
              .map(
                (tag) => FilterChip(
                  label: Text(tag),
                  selected: fitTags.contains(tag),
                  onSelected: (selected) => setState(() {
                    if (selected) {
                      fitTags.add(tag);
                    } else {
                      fitTags.remove(tag);
                    }
                  }),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: note,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(
            labelText: 'Nota da curadoria',
            hintText:
                'Registre prazo, aderência ao NERUDS, público interessado, limitações ou motivo do descarte.',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton.icon(
              onPressed: actionBusy ? null : () => _decide('em_triagem'),
              icon: const Icon(Icons.manage_search),
              label: const Text('Em triagem'),
            ),
            OutlinedButton.icon(
              onPressed: actionBusy ? null : () => _decide('verificado'),
              icon: const Icon(Icons.verified_outlined),
              label: const Text('Fonte verificada'),
            ),
            FilledButton.icon(
              onPressed: actionBusy ? null : () => _decide('aprovado_pauta'),
              icon: const Icon(Icons.thumb_up_alt_outlined),
              label: const Text('Aprovar como pauta'),
            ),
            OutlinedButton.icon(
              onPressed: actionBusy ? null : () => _decide('descartado'),
              icon: const Icon(Icons.block_outlined),
              label: const Text('Descartar'),
            ),
          ],
        ),
        if (status == 'aprovado_pauta' && data['is_duplicate'] != true) ...[
          const SizedBox(height: 18),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Pauta aprovada. O próximo passo cria somente um rascunho não publicado no Drupal.',
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: actionBusy ? null : _createDraft,
                    icon: const Icon(Icons.article_outlined),
                    label: const Text('Criar rascunho'),
                  ),
                ],
              ),
            ),
          ),
        ],
        if (status == 'aprovado_pauta' && data['is_duplicate'] == true) ...[
          const SizedBox(height: 18),
          const Card(
            child: ListTile(
              leading: Icon(Icons.copy_outlined),
              title: Text('Rascunho bloqueado para duplicidade'),
              subtitle: Text(
                'Use o item de referência para criar a pauta e manter a rastreabilidade.',
              ),
            ),
          ),
        ],
        if (status == 'rascunho_criado') ...[
          const SizedBox(height: 18),
          Card(
            child: ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: const Text('Rascunho criado no Drupal'),
              subtitle: Text(
                'ID: ${data['drupal_draft_id'] ?? '-'} • ainda não publicado',
              ),
            ),
          ),
        ],
        const Divider(height: 34),
        Text(
          'Histórico de decisões',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (events.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Nenhuma decisão registrada ainda.'),
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

import 'dart:convert';

import 'package:flutter/material.dart';

import 'app_config.dart';
import 'app_session.dart';
import 'bridge_http.dart' as http;
import 'session_widgets.dart';
import 'unsaved_work.dart';
import 'workflow_widgets.dart';

class EditorialPage extends StatefulWidget {
  const EditorialPage({super.key});

  @override
  State<EditorialPage> createState() => _EditorialPageState();
}

class _EditorialPageState extends State<EditorialPage>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _summary = TextEditingController();
  final _body = TextEditingController();
  final _opportunityItemId = TextEditingController();
  final _missionTaskId = TextEditingController();
  late final TabController _tabs;
  late int _identityEpoch;
  int _step = 0;
  int _requestVersion = 0;
  bool _busy = false;
  bool _loadingDrafts = false;
  String? _loadError;
  String? _reviewStatus = 'pending';
  bool _mineOnly = false;
  List<Map<String, dynamic>> _drafts = const [];
  Map<String, dynamic>? _createdDraft;

  List<TextEditingController> get _controllers => [
    _title,
    _summary,
    _body,
    _opportunityItemId,
    _missionTaskId,
  ];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _identityEpoch = AppSession.instance.identityEpoch;
    for (final controller in _controllers) {
      controller.addListener(_trackChanges);
    }
    AppSession.instance.addListener(_sessionChanged);
    if (AppSession.instance.authenticated) _loadDrafts();
  }

  @override
  void dispose() {
    AppSession.instance.removeListener(_sessionChanged);
    UnsavedWork.instance.remove(this);
    _tabs.dispose();
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _trackChanges() {
    UnsavedWork.instance.setDirty(
      this,
      _controllers.any((controller) => controller.text.isNotEmpty),
    );
  }

  void _clearComposition() {
    for (final controller in _controllers) {
      controller.clear();
    }
    _step = 0;
    UnsavedWork.instance.setDirty(this, false);
  }

  void _sessionChanged() {
    if (!mounted) return;
    final session = AppSession.instance;
    _requestVersion++;
    if (_identityEpoch != session.identityEpoch) {
      _identityEpoch = session.identityEpoch;
      _clearComposition();
      _createdDraft = null;
    }
    setState(() {
      _drafts = const [];
      _loadError = null;
      _loadingDrafts = false;
    });
    if (session.authenticated) _loadDrafts();
  }

  bool _sameSession(int epoch, String? token) =>
      mounted &&
      AppSession.instance.authenticated &&
      AppSession.instance.identityEpoch == epoch &&
      AppSession.instance.token == token;

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(value)));
  }

  Future<void> _loadDrafts() async {
    final session = AppSession.instance;
    if (!session.authenticated) return;
    final epoch = session.identityEpoch;
    final token = session.token;
    final request = ++_requestVersion;
    setState(() {
      _loadingDrafts = true;
      _loadError = null;
    });
    try {
      final query = <String, String>{
        'status': ?_reviewStatus,
        if (_mineOnly) 'mine_only': 'true',
      };
      final response = await http.get(
        AppConfig.endpoint(
          '/content/news/drafts',
        ).replace(queryParameters: query),
        headers: session.authHeaders,
      );
      if (!_sameSession(epoch, token) || request != _requestVersion) return;
      if (response.statusCode != 200) {
        throw workflowResponseError(response);
      }
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      setState(() {
        _drafts = (data['items'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
      });
    } catch (error) {
      if (_sameSession(epoch, token) && request == _requestVersion) {
        setState(() => _loadError = workflowError(error));
      }
    } finally {
      if (mounted && request == _requestVersion) {
        setState(() => _loadingDrafts = false);
      }
    }
  }

  bool _validateComposition() {
    final fieldsValid = _formKey.currentState?.validate() ?? true;
    final textValid =
        _title.text.trim().length >= 3 && _body.text.trim().isNotEmpty;
    final linksValid = [_opportunityItemId, _missionTaskId].every((controller) {
      final value = controller.text.trim();
      return value.isEmpty || (int.tryParse(value) ?? 0) > 0;
    });
    if (!linksValid) {
      _message(
        'Confira os identificadores em Vínculos com trabalho existente.',
      );
    }
    return fieldsValid && textValid && linksValid;
  }

  Future<void> _createDraft() async {
    if (_busy || !AppSession.instance.authenticated) return;
    if (!_validateComposition()) {
      setState(() => _step = 0);
      return;
    }
    final session = AppSession.instance;
    final epoch = session.identityEpoch;
    final token = session.token;
    setState(() => _busy = true);
    try {
      final response = await http.post(
        AppConfig.endpoint('/content/news/draft'),
        headers: session.authHeaders,
        body: jsonEncode({
          'title': _title.text.trim(),
          'summary': _summary.text.trim(),
          'body': _body.text.trim(),
          if (int.tryParse(_opportunityItemId.text.trim()) != null)
            'opportunity_item_id': int.parse(_opportunityItemId.text.trim()),
          if (int.tryParse(_missionTaskId.text.trim()) != null)
            'mission_task_id': int.parse(_missionTaskId.text.trim()),
        }),
      );
      if (!_sameSession(epoch, token)) return;
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw workflowResponseError(response);
      }
      final data = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map,
      );
      setState(() {
        _createdDraft = {...data, 'title': _title.text.trim()};
        _clearComposition();
        _reviewStatus = 'pending';
      });
      _tabs.animateTo(1);
      _message(
        data['notification'] is Map &&
                (data['notification'] as Map)['sent'] == true
            ? 'Rascunho salvo. A equipe de revisão foi avisada por e-mail.'
            : 'Rascunho salvo. Acompanhe o próximo passo na fila de revisão.',
      );
      await _loadDrafts();
    } catch (error) {
      if (_sameSession(epoch, token)) {
        _message('Seu texto foi mantido. ${workflowError(error)}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reviewDraft(Map<String, dynamic> item, String status) async {
    final session = AppSession.instance;
    if (_busy || !session.authenticated) return;
    if (status != 'pending' && !session.canReview) return;
    final nid = item['nid'] ?? item['id'];
    if (nid == null) return;
    final epoch = session.identityEpoch;
    final token = session.token;
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _ReviewDecisionDialog(item: item, status: status),
    );
    if (note == null || !_sameSession(epoch, token)) return;
    setState(() => _busy = true);
    try {
      final response = await http.patch(
        AppConfig.endpoint('/content/news/drafts/$nid/review'),
        headers: session.authHeaders,
        body: jsonEncode({'status': status, if (note.isNotEmpty) 'note': note}),
      );
      if (!_sameSession(epoch, token)) return;
      if (response.statusCode != 200) {
        throw workflowResponseError(response);
      }
      _message(
        status == 'approved'
            ? 'Revisão aprovada. A publicação é o próximo passo.'
            : status == 'pending'
            ? 'Rascunho reenviado para revisão.'
            : 'Orientações de ajuste registradas.',
      );
      await _loadDrafts();
    } catch (error) {
      if (_sameSession(epoch, token)) _message(workflowError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _publishDraft(Map<String, dynamic> item) async {
    final session = AppSession.instance;
    if (_busy || !session.authenticated || !session.canPublish) return;
    final nid = item['nid'] ?? item['id'];
    if (nid == null || _reviewState(item) != 'approved') return;
    final epoch = session.identityEpoch;
    final token = session.token;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Publicar esta notícia?'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(item['title']?.toString() ?? 'Notícia'),
              const SizedBox(height: 12),
              const Text(
                'O texto ficará disponível ao público no portal NERUDS. '
                'Depois, confira a página, os links e a apresentação.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Voltar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Publicar no portal'),
          ),
        ],
      ),
    );
    if (confirmed != true || !_sameSession(epoch, token)) return;
    setState(() => _busy = true);
    try {
      final response = await http.post(
        AppConfig.endpoint('/content/news/drafts/$nid/publish'),
        headers: session.authHeaders,
      );
      if (!_sameSession(epoch, token)) return;
      if (response.statusCode != 200) {
        throw workflowResponseError(response);
      }
      setState(() => _reviewStatus = 'published');
      _message('Notícia publicada. Abra a página para conferir o resultado.');
      await _loadDrafts();
    } catch (error) {
      if (_sameSession(epoch, token)) _message(workflowError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AppSession.instance.authenticated) {
      return const SessionPrompt(
        title: 'Conteúdo do portal',
        message:
            'Entre para preparar e revisar notícias, chamadas e vagas. '
            'Sua redação permanece nesta sessão quando o acesso expira.',
      );
    }
    return Column(
      children: [
        TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.edit_note_outlined), text: 'Redigir notícia'),
            Tab(
              icon: Icon(Icons.rate_review_outlined),
              text: 'Revisão e publicação',
            ),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [_draftForm(context), _draftQueue(context)],
          ),
        ),
      ],
    );
  }

  Widget _draftForm(BuildContext context) {
    const steps = ['Conteúdo', 'Conferir texto', 'Enviar rascunho'];
    return ListView(
      key: const PageStorageKey('editorial-compose-scroll'),
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Preparar uma notícia',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        const Text(
          'Conte uma atividade, divulgue uma chamada ou apresente uma vaga. '
          'Antes de criar, confira na fila se essa notícia já existe.',
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: List.generate(
            steps.length,
            (index) => Chip(
              avatar: Icon(
                index < _step ? Icons.check : Icons.circle_outlined,
                size: 18,
              ),
              label: Text('${index + 1}. ${steps[index]}'),
              backgroundColor: index == _step
                  ? Theme.of(context).colorScheme.secondaryContainer
                  : null,
            ),
          ),
        ),
        const SizedBox(height: 20),
        if (_step == 0)
          Form(
            key: _formKey,
            child: Column(
              children: [
                TextFormField(
                  key: const Key('news-title'),
                  controller: _title,
                  enabled: !_busy,
                  maxLength: 255,
                  textInputAction: TextInputAction.next,
                  validator: (value) => (value?.trim().length ?? 0) < 3
                      ? 'Escreva um título com pelo menos 3 caracteres.'
                      : null,
                  decoration: const InputDecoration(
                    labelText: 'Título da notícia',
                    hintText: 'Apresente o fato ou a oportunidade com clareza',
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('news-summary'),
                  controller: _summary,
                  enabled: !_busy,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Resumo',
                    helperText:
                        'Uma apresentação curta para quem consulta o portal.',
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('news-body'),
                  controller: _body,
                  enabled: !_busy,
                  minLines: 8,
                  maxLines: 18,
                  validator: (value) => (value?.trim().isEmpty ?? true)
                      ? 'Inclua o texto que será revisado.'
                      : null,
                  decoration: const InputDecoration(
                    labelText: 'Texto da notícia',
                    alignLabelWithHint: true,
                    helperText:
                        'Inclua fonte, data do fato e autoria confirmadas. '
                        'Para chamadas e vagas, confira prazo e link de inscrição.',
                    helperMaxLines: 3,
                  ),
                ),
                const SizedBox(height: 12),
                ExpansionTile(
                  key: const PageStorageKey('editorial-composition-links'),
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Vínculos com trabalho existente'),
                  subtitle: const Text(
                    'Opcional. Use a tarefa ou oportunidade já cadastrada.',
                  ),
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        'Oportunidades aprovadas já oferecem a ação de criar rascunho. '
                        'Use estes identificadores apenas para associar uma redação manual.',
                      ),
                    ),
                    _identifierField(
                      _opportunityItemId,
                      'Identificador da oportunidade',
                    ),
                    const SizedBox(height: 12),
                    _identifierField(_missionTaskId, 'Identificador da tarefa'),
                    const SizedBox(height: 12),
                  ],
                ),
              ],
            ),
          )
        else if (_step == 1)
          _NewsPreview(
            title: _title.text.trim(),
            summary: _summary.text.trim(),
            body: _body.text.trim(),
          )
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Destino: Notícias do portal NERUDS',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  Text(_title.text.trim()),
                  const SizedBox(height: 12),
                  const Text(
                    'Será criado um rascunho para revisão. '
                    'Você poderá acompanhar ajustes e publicação na fila.',
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'A redação só será limpa depois da confirmação de salvamento.',
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            if (_step > 0)
              OutlinedButton(
                onPressed: _busy ? null : () => setState(() => _step--),
                child: const Text('Voltar ao texto'),
              ),
            FilledButton.icon(
              key: const Key('news-next'),
              onPressed: _busy
                  ? null
                  : () {
                      if (_step == 2) {
                        _createDraft();
                      } else if (_step != 0 || _validateComposition()) {
                        setState(() => _step++);
                      }
                    },
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _step == 2 ? Icons.send_outlined : Icons.arrow_forward,
                    ),
              label: Text(
                _busy
                    ? 'Salvando...'
                    : _step == 0
                    ? 'Conferir texto'
                    : _step == 1
                    ? 'Confirmar destino'
                    : 'Enviar rascunho',
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _identifierField(TextEditingController controller, String label) =>
      TextFormField(
        controller: controller,
        enabled: !_busy,
        keyboardType: TextInputType.number,
        validator: (value) =>
            value != null &&
                value.trim().isNotEmpty &&
                (int.tryParse(value.trim()) == null ||
                    int.parse(value.trim()) <= 0)
            ? 'Use o identificador numérico de um registro existente.'
            : null,
        decoration: InputDecoration(labelText: label),
      );

  Widget _draftQueue(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _loadDrafts,
      child: ListView(
        key: const PageStorageKey('editorial-queue-scroll'),
        padding: const EdgeInsets.all(24),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Revisão e publicação',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              IconButton(
                tooltip: 'Atualizar fila',
                onPressed: _busy || _loadingDrafts ? null : _loadDrafts,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Confira o texto e a fonte antes de decidir. '
            'Uma aprovação editorial e a conferência da página pública são etapas diferentes.',
          ),
          if (_createdDraft != null) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Rascunho salvo',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(_createdDraft!['title']?.toString() ?? ''),
                    PortalLinkButton(
                      label: 'Abrir rascunho no portal',
                      url: _createdDraft!['edit_url']?.toString(),
                      editing: true,
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _queueFilter('Todos', null),
              _queueFilter('Aguardando revisão', 'pending'),
              _queueFilter('Para ajuste', 'changes_requested'),
              _queueFilter('Aprovados', 'approved'),
              _queueFilter('Publicados', 'published'),
              FilterChip(
                label: const Text('Meu trabalho'),
                selected: _mineOnly,
                onSelected: _busy
                    ? null
                    : (selected) {
                        setState(() => _mineOnly = selected);
                        _loadDrafts();
                      },
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_loadingDrafts)
            const LinearProgressIndicator()
          else if (_loadError != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_loadError!),
                    TextButton.icon(
                      onPressed: _loadDrafts,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Tentar novamente'),
                    ),
                  ],
                ),
              ),
            )
          else if (_drafts.isEmpty)
            const Card(
              child: ListTile(
                leading: Icon(Icons.inbox_outlined),
                title: Text('Nenhuma notícia neste filtro.'),
                subtitle: Text(
                  'Mude a situação ou confira apenas o seu trabalho.',
                ),
              ),
            )
          else
            ..._drafts.map((item) => _draftCard(context, item)),
        ],
      ),
    );
  }

  Widget _draftCard(BuildContext context, Map<String, dynamic> item) {
    final review = item['review'] is Map
        ? Map<String, dynamic>.from(item['review'] as Map)
        : const <String, dynamic>{};
    final status = _reviewState(item);
    final isAuthor =
        item['is_owner'] == true ||
        (item['is_owner'] == null &&
            review['author'] == AppSession.instance.username);
    final body = item['body']?.toString().trim() ?? '';
    final events = (review['events'] as List<dynamic>? ?? const [])
        .whereType<Map>();
    final canReview =
        AppSession.instance.canReview &&
        status != 'published' &&
        body.isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item['title']?.toString() ?? 'Sem título',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Chip(label: Text(_statusLabel(status))),
                Text('Responsável: ${review['author'] ?? 'não informado'}'),
              ],
            ),
            if ((review['review_note']?.toString() ?? '').isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Orientações da revisão: ${review['review_note']}'),
            ],
            const SizedBox(height: 8),
            ExpansionTile(
              key: PageStorageKey('news-preview-${item['nid'] ?? item['id']}'),
              tilePadding: EdgeInsets.zero,
              title: const Text('Conferir texto e fontes'),
              initiallyExpanded: true,
              children: [
                if (body.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text(
                      'O texto não está disponível nesta consulta. '
                      'Abra a ficha no portal para conferir o conteúdo.',
                    ),
                  )
                else
                  _NewsPreview(
                    title: null,
                    summary: item['summary']?.toString() ?? '',
                    body: body,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (status != 'published')
                  PortalLinkButton(
                    label: 'Editar a ficha existente',
                    url: item['edit_url']?.toString(),
                    editing: true,
                  ),
                if (status == 'published')
                  PortalLinkButton(
                    label: 'Conferir página pública',
                    url: item['public_url']?.toString(),
                  ),
                if (canReview)
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _reviewDraft(item, 'changes_requested'),
                    icon: const Icon(Icons.assignment_return_outlined),
                    label: const Text('Solicitar ajustes'),
                  ),
                if (canReview && status != 'approved')
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _reviewDraft(item, 'approved'),
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Aprovar revisão'),
                  ),
                if (isAuthor && status == 'changes_requested')
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _reviewDraft(item, 'pending'),
                    icon: const Icon(Icons.send_outlined),
                    label: const Text('Reenviar para revisão'),
                  ),
                if (AppSession.instance.canPublish &&
                    status == 'approved' &&
                    body.isNotEmpty)
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _publishDraft(item),
                    icon: const Icon(Icons.publish_outlined),
                    label: const Text('Publicar'),
                  ),
              ],
            ),
            if (events.isNotEmpty)
              ExpansionTile(
                key: PageStorageKey(
                  'news-history-${item['nid'] ?? item['id']}',
                ),
                tilePadding: EdgeInsets.zero,
                title: Text('Histórico de decisões (${events.length})'),
                children: events
                    .map(
                      (event) => ListTile(
                        dense: true,
                        title: Text(
                          '${_statusLabel(event['event_type']?.toString() ?? '')} · '
                          '${event['actor'] ?? 'Sistema'}',
                        ),
                        subtitle: Text(event['note']?.toString() ?? ''),
                      ),
                    )
                    .toList(),
              ),
            ExpansionTile(
              key: PageStorageKey('news-links-${item['nid'] ?? item['id']}'),
              tilePadding: EdgeInsets.zero,
              title: const Text('Referência e vínculos'),
              children: [
                ListTile(
                  dense: true,
                  title: Text(
                    'Ficha ${item['nid'] ?? item['id'] ?? 'não identificada'}',
                  ),
                  subtitle: Text(
                    [
                      if (review['opportunity_item_id'] != null)
                        'Oportunidade ${review['opportunity_item_id']}',
                      if (review['mission_task_id'] != null)
                        'Tarefa ${review['mission_task_id']}',
                    ].join(' · '),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _queueFilter(String label, String? status) => ChoiceChip(
    label: Text(label),
    selected: _reviewStatus == status,
    onSelected: _busy
        ? null
        : (_) {
            setState(() => _reviewStatus = status);
            _loadDrafts();
          },
  );
}

String _reviewState(Map<String, dynamic> item) {
  if (item['published'] == true || item['status'] == 'published') {
    return 'published';
  }
  if (item['status'] is String) return item['status'] as String;
  final review = item['review'];
  return review is Map
      ? review['review_status']?.toString() ?? 'pending'
      : 'pending';
}

String _statusLabel(String status) =>
    const {
      'pending': 'Aguardando revisão',
      'changes_requested': 'Ajustes solicitados',
      'approved': 'Revisão aprovada',
      'published': 'Publicado',
      'draft_registered': 'Rascunho criado',
    }[status] ??
    status;

class _NewsPreview extends StatelessWidget {
  const _NewsPreview({
    required this.title,
    required this.summary,
    required this.body,
  });
  final String? title;
  final String summary;
  final String body;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          SelectableText(
            title!,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
        ],
        if (summary.isNotEmpty) ...[
          SelectableText(
            summary,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Divider(height: 28),
        ],
        SelectableText(body),
      ],
    ),
  );
}

class _ReviewDecisionDialog extends StatefulWidget {
  const _ReviewDecisionDialog({required this.item, required this.status});
  final Map<String, dynamic> item;
  final String status;

  @override
  State<_ReviewDecisionDialog> createState() => _ReviewDecisionDialogState();
}

class _ReviewDecisionDialogState extends State<_ReviewDecisionDialog> {
  final _note = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final changes = widget.status == 'changes_requested';
    final resend = widget.status == 'pending';
    return AlertDialog(
      title: Text(
        changes
            ? 'Solicitar ajustes'
            : resend
            ? 'Reenviar para revisão'
            : 'Aprovar esta revisão?',
      ),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.item['title']?.toString() ?? 'Notícia'),
              const SizedBox(height: 12),
              Text(
                resend
                    ? 'Confirme que os ajustes foram salvos na mesma ficha do portal.'
                    : 'Confira fato, autoria, datas e fontes. A decisão ficará no histórico.',
              ),
              const SizedBox(height: 16),
              if (!changes && !resend) ...[
                _NewsPreview(
                  title: null,
                  summary: widget.item['summary']?.toString() ?? '',
                  body: widget.item['body']?.toString() ?? '',
                ),
                const SizedBox(height: 16),
              ],
              TextField(
                controller: _note,
                minLines: 3,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: changes
                      ? 'O que precisa ser ajustado?'
                      : 'Comentário da revisão',
                  errorText: _error,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Voltar'),
        ),
        FilledButton(
          onPressed: () {
            if (changes && _note.text.trim().isEmpty) {
              setState(
                () => _error = 'Indique uma próxima ação para quem escreveu.',
              );
              return;
            }
            Navigator.pop(context, _note.text.trim());
          },
          child: Text(
            changes
                ? 'Registrar ajustes'
                : resend
                ? 'Reenviar'
                : 'Confirmar aprovação',
          ),
        ),
      ],
    );
  }
}

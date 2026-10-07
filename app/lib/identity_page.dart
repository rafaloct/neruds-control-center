import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'bridge_http.dart' as http;

import 'app_session.dart';
import 'app_config.dart';
import 'session_widgets.dart';
import 'workflow_widgets.dart';

Uri _idUri(String path, [Map<String, String>? query]) =>
    AppConfig.endpoint(path).replace(queryParameters: query);

String _idError(http.Response response) {
  try {
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final detail = data['detail'];
    if (detail is Map && detail['message'] != null) {
      return detail['message'].toString();
    }
    return detail?.toString() ?? 'A ação não foi autorizada pelo portal.';
  } catch (_) {
    return 'O serviço não conseguiu concluir a ação. Tente novamente.';
  }
}

String _epoch(int? value) {
  if (value == null || value <= 0) return 'nunca';
  final date = DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
  return '${date.day.toString().padLeft(2, '0')}/'
      '${date.month.toString().padLeft(2, '0')}/${date.year}';
}

class IdentityPage extends StatefulWidget {
  const IdentityPage({super.key});

  @override
  State<IdentityPage> createState() => _IdentityPageState();
}

class _IdentityPageState extends State<IdentityPage> {
  bool loading = false;
  bool working = false;
  String? _loadedToken;
  String? _loadError;
  String? _historyError;
  List<Map<String, dynamic>> accounts = const [];
  List<Map<String, dynamic>> events = const [];

  @override
  void initState() {
    super.initState();
    AppSession.instance.addListener(_sessionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    AppSession.instance.removeListener(_sessionChanged);
    super.dispose();
  }

  void _sessionChanged() {
    if (!mounted) return;
    setState(() {
      accounts = const [];
      events = const [];
    });
    if (AppSession.instance.authenticated &&
        AppSession.instance.canAdminUsers) {
      _load();
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _load() async {
    if (!mounted ||
        !AppSession.instance.authenticated ||
        !AppSession.instance.canAdminUsers) {
      return;
    }
    final requestToken = AppSession.instance.token;
    _loadedToken = requestToken;
    setState(() {
      loading = true;
      _loadError = null;
      _historyError = null;
    });
    try {
      final roster = await http.get(
        _idUri('/identity/roster'),
        headers: AppSession.instance.authHeaders,
      );
      if (AppSession.instance.token != requestToken) return;
      if (roster.statusCode == 401) {
        _message('Sessão expirada. Entre novamente com sua conta.');
        return;
      }
      if (roster.statusCode != 200) {
        setState(() {
          _loadError = _idError(roster);
          _historyError = 'O histórico não pôde ser consultado.';
        });
        return;
      }
      final rosterData = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(roster.bodyBytes)),
      );
      List<Map<String, dynamic>> history = const [];
      try {
        final ev = await http.get(
          _idUri('/identity/events', {'limit': '30'}),
          headers: AppSession.instance.authHeaders,
        );
        if (ev.statusCode == 200) {
          history =
              (Map<String, dynamic>.from(
                            jsonDecode(utf8.decode(ev.bodyBytes)),
                          )['items']
                          as List? ??
                      const [])
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList();
        } else {
          _historyError =
              'Não foi possível consultar o histórico. Tente novamente.';
        }
      } catch (_) {
        _historyError =
            'Não foi possível consultar o histórico. Confira a conexão.';
      }
      if (mounted && AppSession.instance.token == requestToken) {
        setState(() {
          accounts = (rosterData['accounts'] as List? ?? const [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          events = history;
        });
      }
    } catch (e) {
      if (mounted && AppSession.instance.token == requestToken) {
        setState(() {
          _loadError = workflowError(e);
          _historyError = 'O histórico não pôde ser consultado.';
        });
      }
    } finally {
      if (mounted && _loadedToken == requestToken) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> _setStatus(Map<String, dynamic> account, bool active) async {
    if (working || !AppSession.instance.canAdminUsers) return;
    final requestToken = AppSession.instance.token;
    final uid = account['uid'];
    setState(() => working = true);
    try {
      final response = await http.post(
        _idUri('/identity/accounts/$uid/status'),
        headers: AppSession.instance.authHeaders,
        body: jsonEncode({'active': active}),
      );
      if (!mounted || AppSession.instance.token != requestToken) return;
      if (response.statusCode != 200) {
        _message(_idError(response));
        return;
      }
      _message(
        active
            ? 'Conta ${account['name']} reativada.'
            : 'Conta ${account['name']} bloqueada.',
      );
      await _load();
    } catch (e) {
      _message(workflowError(e));
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _passwordReset(Map<String, dynamic> account) async {
    if (working || !AppSession.instance.canAdminUsers) return;
    final requestToken = AppSession.instance.token;
    final uid = account['uid'];
    setState(() => working = true);
    try {
      final response = await http.post(
        _idUri('/identity/accounts/$uid/password-reset'),
        headers: AppSession.instance.authHeaders,
      );
      if (!mounted || AppSession.instance.token != requestToken) return;
      if (response.statusCode != 200) {
        _message(_idError(response));
        return;
      }
      final data = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)),
      );
      final url = data['reset_url']?.toString() ?? '';
      if (!mounted) return;
      await _showSecret(
        title: 'Recuperar acesso — ${account['name']}',
        explanation:
            'Link de uso único gerado pelo portal. Entregue por canal '
            'seguro à pessoa responsável pela conta.',
        value: url,
        copyLabel: 'Copiar link',
        token: requestToken,
      );
      await _load();
    } catch (e) {
      _message(workflowError(e));
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _showSecret({
    required String title,
    required String explanation,
    required String value,
    required String copyLabel,
    required String? token,
  }) async {
    if (!mounted || AppSession.instance.token != token) return;
    await showDialog<void>(
      context: context,
      builder: (_) => ListenableBuilder(
        listenable: AppSession.instance,
        builder: (context, _) {
          final valid =
              AppSession.instance.authenticated &&
              AppSession.instance.canAdminUsers &&
              AppSession.instance.token == token;
          return AlertDialog(
            title: Text(valid ? title : 'Sessão encerrada'),
            content: SingleChildScrollView(
              child: valid
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(explanation),
                        const SizedBox(height: 12),
                        SelectableText(value),
                      ],
                    )
                  : const Text(
                      'Este resultado deixou de ser exibido porque o acesso terminou. '
                      'Entre novamente para consultar as ações disponíveis.',
                    ),
            ),
            actions: [
              if (valid && value.isNotEmpty)
                TextButton.icon(
                  onPressed: () {
                    if (AppSession.instance.token == token &&
                        AppSession.instance.canAdminUsers) {
                      Clipboard.setData(ClipboardData(text: value));
                    }
                  },
                  icon: const Icon(Icons.copy_outlined),
                  label: Text(copyLabel),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Fechar'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _provision() async {
    if (working || !AppSession.instance.canAdminUsers) return;
    final creationToken = AppSession.instance.token;
    final name = TextEditingController();
    final mail = TextEditingController();
    final form = GlobalKey<FormState>();
    var submitting = false;
    String? error;
    Map<String, dynamic>? created;
    try {
      final route = DialogRoute<Map<String, dynamic>>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setInner) => PopScope(
            canPop: !submitting,
            child: AlertDialog(
              title: const Text('Criar conta extensionista'),
              content: SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: Form(
                    key: form,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Cada pessoa usa sua própria conta. Criar uma conta '
                          'extensionista não concede autorização para publicar.',
                        ),
                        const SizedBox(height: 20),
                        TextFormField(
                          controller: name,
                          enabled: !submitting,
                          decoration: const InputDecoration(
                            labelText: 'Usuário',
                          ),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? 'Informe um usuário.'
                              : null,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: mail,
                          enabled: !submitting,
                          decoration: const InputDecoration(
                            labelText: 'E-mail',
                          ),
                          keyboardType: TextInputType.emailAddress,
                          validator: (value) =>
                              value == null ||
                                  !RegExp(
                                    r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                                  ).hasMatch(value.trim())
                              ? 'Informe um e-mail válido.'
                              : null,
                        ),
                        if (error != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            error!,
                            style: TextStyle(
                              color: Theme.of(dialogContext).colorScheme.error,
                            ),
                          ),
                        ],
                        if (submitting) ...[
                          const SizedBox(height: 16),
                          const LinearProgressIndicator(),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: submitting
                      ? null
                      : () => Navigator.pop(dialogContext),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: submitting
                      ? null
                      : () async {
                          if (!form.currentState!.validate()) return;
                          setInner(() {
                            submitting = true;
                            error = null;
                          });
                          try {
                            final requestToken = AppSession.instance.token;
                            final response = await http.post(
                              _idUri('/identity/accounts'),
                              headers: AppSession.instance.authHeaders,
                              body: jsonEncode({
                                'name': name.text.trim(),
                                'mail': mail.text.trim(),
                              }),
                            );
                            if (!dialogContext.mounted) return;
                            if (AppSession.instance.token != requestToken) {
                              setInner(
                                () => error =
                                    'Sua sessão expirou. Feche esta janela e entre novamente.',
                              );
                            } else if (response.statusCode >= 400) {
                              setInner(() => error = _idError(response));
                            } else {
                              Navigator.pop(
                                dialogContext,
                                Map<String, dynamic>.from(
                                  jsonDecode(utf8.decode(response.bodyBytes)),
                                ),
                              );
                            }
                          } catch (failure) {
                            if (dialogContext.mounted) {
                              setInner(() => error = workflowError(failure));
                            }
                          } finally {
                            if (dialogContext.mounted) {
                              setInner(() => submitting = false);
                            }
                          }
                        },
                  child: Text(submitting ? 'Criando…' : 'Criar conta'),
                ),
              ],
            ),
          ),
        ),
      );
      created = await Navigator.of(context, rootNavigator: true).push(route);
      await route.completed;
    } finally {
      name.dispose();
      mail.dispose();
    }
    if (!mounted || created == null) return;
    final temp = created['drupal'] is Map
        ? (created['drupal']['temporary_password']?.toString() ?? '')
        : '';
    await _showSecret(
      title: 'Conta criada',
      explanation: temp.isEmpty
          ? 'A conta foi criada. Use a recuperação de acesso para orientar a entrada.'
          : 'Senha temporária, mostrada apenas agora. Entregue por canal seguro '
                'à pessoa responsável pela conta.',
      value: temp,
      copyLabel: 'Copiar senha',
      token: creationToken,
    );
    await _load();
  }

  Future<void> _offboard(Map<String, dynamic> account) async {
    if (working || !AppSession.instance.canAdminUsers) return;
    final requestToken = AppSession.instance.token;
    String? transferTo;
    final note = TextEditingController();
    final others = accounts
        .where((a) => a['uid'] != account['uid'] && a['active'] == true)
        .map((a) => a['name'].toString())
        .toList();
    var submitting = false;
    String? error;
    Map<String, dynamic>? result;
    try {
      final route = DialogRoute<Map<String, dynamic>>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setInner) => PopScope(
            canPop: !submitting,
            child: AlertDialog(
              title: Text('Encerrar vínculo — ${account['name']}'),
              content: SizedBox(
                width: 440,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'A conta será bloqueada no portal. Você pode transferir '
                        'as tarefas abertas para outra conta extensionista.',
                      ),
                      if ((account['pending_drafts'] ?? 0) > 0) ...[
                        const SizedBox(height: 12),
                        Text(
                          '${account['pending_drafts']} rascunhos ainda precisam de revisão.',
                        ),
                      ],
                      const SizedBox(height: 20),
                      DropdownButtonFormField<String>(
                        initialValue: transferTo,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Transferir tarefas abertas para',
                        ),
                        items: [
                          const DropdownMenuItem<String>(
                            value: null,
                            child: Text('Não transferir agora'),
                          ),
                          ...others.map(
                            (name) => DropdownMenuItem(
                              value: name,
                              child: Text(name),
                            ),
                          ),
                        ],
                        onChanged: submitting
                            ? null
                            : (value) => setInner(() => transferTo = value),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('offboarding-note'),
                        controller: note,
                        enabled: !submitting,
                        decoration: const InputDecoration(
                          labelText: 'Observação para a continuidade',
                          helperText: 'Opcional',
                        ),
                        maxLines: 3,
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(dialogContext).colorScheme.error,
                          ),
                        ),
                      ],
                      if (submitting) ...[
                        const SizedBox(height: 16),
                        const LinearProgressIndicator(),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: submitting
                      ? null
                      : () => Navigator.pop(dialogContext),
                  child: const Text('Voltar'),
                ),
                FilledButton(
                  onPressed: submitting
                      ? null
                      : () async {
                          setInner(() {
                            submitting = true;
                            error = null;
                          });
                          try {
                            final response = await http.post(
                              _idUri(
                                '/identity/accounts/${account['uid']}/offboarding',
                              ),
                              headers: AppSession.instance.authHeaders,
                              body: jsonEncode({
                                'transfer_to': transferTo,
                                'note': note.text.trim().isEmpty
                                    ? null
                                    : note.text.trim(),
                              }),
                            );
                            if (!dialogContext.mounted) return;
                            if (AppSession.instance.token != requestToken) {
                              setInner(
                                () => error =
                                    'Sua sessão expirou. Feche esta janela e entre novamente.',
                              );
                            } else if (response.statusCode != 200) {
                              setInner(() => error = _idError(response));
                            } else {
                              Navigator.pop(
                                dialogContext,
                                Map<String, dynamic>.from(
                                  jsonDecode(utf8.decode(response.bodyBytes)),
                                ),
                              );
                            }
                          } catch (failure) {
                            if (dialogContext.mounted) {
                              setInner(() => error = workflowError(failure));
                            }
                          } finally {
                            if (dialogContext.mounted) {
                              setInner(() => submitting = false);
                            }
                          }
                        },
                  child: Text(submitting ? 'Registrando…' : 'Encerrar acesso'),
                ),
              ],
            ),
          ),
        ),
      );
      result = await Navigator.of(context, rootNavigator: true).push(route);
      await route.completed;
    } finally {
      note.dispose();
    }
    if (!mounted ||
        result == null ||
        AppSession.instance.token != requestToken) {
      return;
    }
    final advisories = (result['advisories'] as List? ?? const [])
        .map((e) => e.toString())
        .join('\n');
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Encerramento registrado'),
        content: SingleChildScrollView(
          child: Text(
            'Tarefas transferidas: ${result!['tasks_transferred']}\n\n$advisories',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Entendi'),
          ),
        ],
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (!AppSession.instance.authenticated) {
      return const SessionPrompt(
        title: 'Equipe e acessos',
        message: 'Entre com sua conta para consultar as operações disponíveis.',
      );
    }
    if (!AppSession.instance.canAdminUsers) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Sua conta não gerencia acessos da equipe. '
            'Peça à coordenação uma criação de conta ou mudança de acesso.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Wrap(
          spacing: 24,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Usuários e papéis',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            FilledButton.icon(
              onPressed: loading || working ? null : _provision,
              icon: const Icon(Icons.person_add_alt_1_outlined),
              label: const Text('Criar conta extensionista'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Acompanhe as contas, recupere acessos e transfira tarefas ao encerrar '
          'um vínculo. As ações ficam registradas no histórico da equipe.',
        ),
        const SizedBox(height: 16),
        if (loading || working) const LinearProgressIndicator(),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: loading || working ? null : _load,
            icon: const Icon(Icons.refresh),
            label: const Text('Atualizar equipe'),
          ),
        ),
        if (_loadError != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.cloud_off_outlined),
              title: const Text('A consulta à equipe falhou'),
              subtitle: Text(_loadError!),
            ),
          )
        else if (accounts.isEmpty && !loading)
          const Card(
            child: ListTile(title: Text('Nenhuma conta extensionista.')),
          )
        else
          ...accounts.map(_accountCard),
        const SizedBox(height: 20),
        Text(
          'Histórico de contas operacionais',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        if (_historyError != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.history_outlined),
              title: Text(_historyError!),
            ),
          )
        else if (events.isEmpty && !loading)
          const Card(child: ListTile(title: Text('Nenhum evento registrado.')))
        else
          ...events.map(
            (e) => Card(
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.history_outlined),
                title: Text(
                  '${e['kind']} — ${e['username'] ?? 'conta removida'}',
                ),
                subtitle: Text(
                  'por ${e['actor']} em ${(DateTime.tryParse(e['created_at']?.toString() ?? '')?.toLocal().toString().substring(0, 16) ?? '')}',
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _accountCard(Map<String, dynamic> account) {
    final active = account['active'] == true;
    final progress = account['offboarding'] as Map<String, dynamic>?;
    final openTasks = account['open_tasks'] ?? 0;
    final pendingDrafts = account['pending_drafts'] ?? 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            ListTile(
              leading: Icon(
                active ? Icons.person_outline : Icons.person_off_outlined,
                color: active ? null : Theme.of(context).colorScheme.error,
              ),
              title: Text('${account['name']} — ${account['mail'] ?? ''}'),
              subtitle: Text(
                'Último acesso: ${_epoch(account['last_access'] as int?)}  •  '
                'tarefas abertas: $openTasks  •  '
                'rascunhos pendentes: $pendingDrafts',
              ),
              trailing: PopupMenuButton<String>(
                enabled: !working && !loading,
                tooltip: 'Ações da conta ${account['name']}',
                onSelected: (action) {
                  switch (action) {
                    case 'activate':
                      _setStatus(account, true);
                    case 'block':
                      _setStatus(account, false);
                    case 'reset':
                      _passwordReset(account);
                    case 'offboard':
                      _offboard(account);
                  }
                },
                itemBuilder: (context) => [
                  if (!active)
                    const PopupMenuItem(
                      value: 'activate',
                      child: Text('Reativar conta'),
                    )
                  else
                    const PopupMenuItem(
                      value: 'block',
                      child: Text('Bloquear conta'),
                    ),
                  const PopupMenuItem(
                    value: 'reset',
                    child: Text('Gerar link de reset de senha'),
                  ),
                  if (active)
                    const PopupMenuItem(
                      value: 'offboard',
                      child: Text('Offboarding (fim da bolsa)'),
                    ),
                ],
              ),
            ),
            if (progress != null && !active)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: (progress['total'] ?? 0) == 0
                            ? 0
                            : (progress['done'] ?? 0) / progress['total'],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Encerramento ${progress['done']}/${progress['total']}',
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

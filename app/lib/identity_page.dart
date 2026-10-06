import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'app_session.dart';

const _bridgeUrl = String.fromEnvironment(
  'NERUDS_BRIDGE_URL',
  defaultValue: 'https://largeo.tail2faed0.ts.net:8443',
);

Uri _idUri(String path, [Map<String, String>? query]) {
  final base = _bridgeUrl.endsWith('/')
      ? _bridgeUrl.substring(0, _bridgeUrl.length - 1)
      : _bridgeUrl;
  return Uri.parse('$base$path').replace(queryParameters: query);
}

String _idError(http.Response response) {
  try {
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final detail = data['detail'];
    if (detail is Map && detail['message'] != null) {
      return detail['message'].toString();
    }
    return detail?.toString() ?? 'Erro HTTP ${response.statusCode}';
  } catch (_) {
    return 'Erro HTTP ${response.statusCode}';
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
  List<Map<String, dynamic>> accounts = const [];
  List<Map<String, dynamic>> events = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final roster = await http.get(
        _idUri('/identity/roster'),
        headers: AppSession.instance.authHeaders,
      );
      if (roster.statusCode == 401) {
        _message('Sessão expirada. Entre novamente na aba Conteúdo.');
        return;
      }
      if (roster.statusCode != 200) {
        _message(_idError(roster));
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
          history = (Map<String, dynamic>.from(
                    jsonDecode(utf8.decode(ev.bodyBytes)),
                  )['items'] as List? ??
                  const [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        }
      } catch (_) {}
      if (mounted) {
        setState(() {
          accounts = (rosterData['accounts'] as List? ?? const [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          events = history;
        });
      }
    } catch (e) {
      _message('Não foi possível carregar as contas: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _setStatus(Map<String, dynamic> account, bool active) async {
    final uid = account['uid'];
    try {
      final response = await http.post(
        _idUri('/identity/accounts/$uid/status'),
        headers: AppSession.instance.authHeaders,
        body: jsonEncode({'active': active}),
      );
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
      _message('Não foi possível alterar o status: $e');
    }
  }

  Future<void> _passwordReset(Map<String, dynamic> account) async {
    final uid = account['uid'];
    try {
      final response = await http.post(
        _idUri('/identity/accounts/$uid/password-reset'),
        headers: AppSession.instance.authHeaders,
      );
      if (response.statusCode != 200) {
        _message(_idError(response));
        return;
      }
      final data = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)),
      );
      final url = data['reset_url']?.toString() ?? '';
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Reset de senha — ${account['name']}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Link de uso único gerado pelo Drupal. Envie por canal seguro; '
                'ele não fica salvo no bridge.',
              ),
              const SizedBox(height: 12),
              SelectableText(url),
            ],
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: url));
                Navigator.pop(context);
              },
              icon: const Icon(Icons.copy_outlined),
              label: const Text('Copiar'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Fechar'),
            ),
          ],
        ),
      );
      await _load();
    } catch (e) {
      _message('Não foi possível gerar o link: $e');
    }
  }

  Future<void> _provision() async {
    final name = TextEditingController();
    final mail = TextEditingController();
    final created = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Provisionar conta extensionista'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(
                labelText: 'Usuário (ex.: extensionista.3)',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: mail,
              decoration: const InputDecoration(labelText: 'E-mail'),
              keyboardType: TextInputType.emailAddress,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () async {
              try {
                final response = await http.post(
                  _idUri('/identity/accounts'),
                  headers: AppSession.instance.authHeaders,
                  body: jsonEncode({
                    'name': name.text.trim(),
                    'mail': mail.text.trim(),
                  }),
                );
                if (response.statusCode >= 400) {
                  if (context.mounted) {
                    Navigator.pop(context);
                    _message(_idError(response));
                  }
                  return;
                }
                if (context.mounted) {
                  Navigator.pop(
                    context,
                    Map<String, dynamic>.from(
                      jsonDecode(utf8.decode(response.bodyBytes)),
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  Navigator.pop(context);
                  _message('Falha ao provisionar: $e');
                }
              }
            },
            child: const Text('Criar'),
          ),
        ],
      ),
    );
    if (!mounted || created == null) return;
    final temp = created['drupal'] is Map
        ? (created['drupal']['temporary_password']?.toString() ?? '')
        : '';
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Conta criada'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (temp.isNotEmpty) ...[
              const Text(
                'Senha temporária (mostrada só agora — entregue por canal seguro):',
              ),
              const SizedBox(height: 8),
              SelectableText(
                temp,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ] else
              const Text('Conta criada sem senha temporária no retorno.'),
          ],
        ),
        actions: [
          if (temp.isNotEmpty)
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: temp));
              },
              icon: const Icon(Icons.copy_outlined),
              label: const Text('Copiar senha'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
    await _load();
  }

  Future<void> _offboard(Map<String, dynamic> account) async {
    String? transferTo;
    final note = TextEditingController();
    final others = accounts
        .where((a) => a['uid'] != account['uid'] && a['active'] == true)
        .map((a) => a['name'].toString())
        .toList();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setInner) => AlertDialog(
          title: Text('Offboarding — ${account['name']}'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'A conta será bloqueada no Drupal e as tarefas abertas '
                  'podem ser transferidas para outra conta extensionista.',
                ),
                const SizedBox(height: 12),
                if ((account['pending_drafts'] ?? 0) > 0)
                  Text(
                    'Atenção: ${account['pending_drafts']} rascunhos pendentes '
                    'aguardam revisão.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: transferTo,
                  decoration: const InputDecoration(
                    labelText: 'Transferir tarefas abertas para',
                  ),
                  items: others
                      .map(
                        (n) => DropdownMenuItem(value: n, child: Text(n)),
                      )
                      .toList(),
                  onChanged: (v) => setInner(() => transferTo = v),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: note,
                  decoration: const InputDecoration(
                    labelText: 'Observação (opcional)',
                  ),
                  maxLines: 2,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Encerrar acesso'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;

    try {
      final response = await http.post(
        _idUri('/identity/accounts/${account['uid']}/offboarding'),
        headers: AppSession.instance.authHeaders,
        body: jsonEncode({
          'transfer_to': transferTo,
          'note': note.text.trim().isEmpty ? null : note.text.trim(),
        }),
      );
      if (response.statusCode != 200) {
        _message(_idError(response));
        return;
      }
      final data = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)),
      );
      final advisories = (data['advisories'] as List? ?? const [])
          .map((e) => '• ${e.toString()}')
          .join('\n');
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Offboarding registrado'),
          content: Text(
            'Tarefas transferidas: ${data['tasks_transferred']}\n\n'
            '$advisories',
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
    } catch (e) {
      _message('Falha no offboarding: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AppSession.instance.canAdminUsers) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Gerenciar contas extensionistas requer a permissão '
            '"administer neruds extensionistas" no Drupal.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Usuários e papéis',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            FilledButton.icon(
              onPressed: loading ? null : _provision,
              icon: const Icon(Icons.person_add_alt_1_outlined),
              label: const Text('Provisionar conta'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Ciclo de vida das contas extensionistas: provisão, bloqueio, '
          'reset de senha e offboarding. Tudo registrado no histórico do bridge.',
        ),
        const SizedBox(height: 16),
        if (loading) const LinearProgressIndicator(),
        if (accounts.isEmpty && !loading)
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
        if (events.isEmpty)
          const Card(
            child: ListTile(title: Text('Nenhum evento registrado.')),
          )
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
                  'por ${e['actor']} em ${e['created_at']?.toString().substring(0, 16) ?? ''}',
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
                active
                    ? Icons.person_outline
                    : Icons.person_off_outlined,
                color: active ? null : Theme.of(context).colorScheme.error,
              ),
              title: Text('${account['name']} — ${account['mail'] ?? ''}'),
              subtitle: Text(
                'Último acesso: ${_epoch(account['last_access'] as int?)}  •  '
                'tarefas abertas: $openTasks  •  '
                'rascunhos pendentes: $pendingDrafts',
              ),
              trailing: PopupMenuButton<String>(
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
                      'Offboarding ${progress['done']}/${progress['total']}',
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

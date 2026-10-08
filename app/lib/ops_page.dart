import 'dart:convert';

import 'package:flutter/material.dart';
import 'bridge_http.dart' as http;

import 'app_config.dart';
import 'app_session.dart';

Uri _opsUri(String path) => AppConfig.endpoint(path);

String _opsError(http.Response response) {
  try {
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    return data['detail']?.toString() ?? 'O serviço não conseguiu concluir a ação.';
  } catch (_) {
    return 'O serviço não conseguiu concluir a ação. Tente novamente.';
  }
}

String _fmtDate(String? iso) {
  if (iso == null || iso.isEmpty) return 'nunca';
  final date = DateTime.tryParse(iso)?.toLocal();
  if (date == null) return iso;
  return '${date.day.toString().padLeft(2, '0')}/'
      '${date.month.toString().padLeft(2, '0')}/${date.year} '
      '${date.hour.toString().padLeft(2, '0')}:'
      '${date.minute.toString().padLeft(2, '0')}';
}

const _probeLabels = {
  'drupal_portal': 'Portal Drupal (neruds.org)',
  'tailscale_serve': 'Tailscale Serve',
  'posteio_smtp': 'E-mail Poste.io (SMTP)',
  'mission_db': 'Banco de tarefas (SQLite)',
};

class OpsPage extends StatefulWidget {
  const OpsPage({super.key});

  @override
  State<OpsPage> createState() => _OpsPageState();
}

class _OpsPageState extends State<OpsPage> {
  bool loading = false;
  bool backingUp = false;
  String? _loadError;
  Map<String, dynamic>? _status;

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
    if (!mounted ||
        !AppSession.instance.authenticated ||
        !AppSession.instance.canAdminUsers) {
      return;
    }
    setState(() {
      loading = true;
      _loadError = null;
    });
    try {
      final response = await http.get(
        _opsUri('/ops/status'),
        headers: AppSession.instance.authHeaders,
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        setState(() {
          _status = jsonDecode(utf8.decode(response.bodyBytes))
              as Map<String, dynamic>;
        });
      } else {
        setState(() => _loadError = _opsError(response));
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _loadError = 'Não foi possível contatar o bridge no momento.',
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _backupNow() async {
    if (backingUp) return;
    setState(() => backingUp = true);
    try {
      final response = await http.post(
        _opsUri('/ops/backup'),
        headers: AppSession.instance.authHeaders,
        // Um zip grande de evidências pode passar do timeout padrão de 25s.
        timeout: const Duration(seconds: 120),
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        final body = jsonDecode(utf8.decode(response.bodyBytes));
        _message('Backup gravado: ${body['file']}');
        await _load();
      } else {
        _message(_opsError(response));
      }
    } catch (_) {
      if (mounted) _message('Não foi possível contatar o bridge no momento.');
    } finally {
      if (mounted) setState(() => backingUp = false);
    }
  }

  Widget _probeTile(Map<String, dynamic> probe) {
    final name = probe['name']?.toString() ?? '';
    final label = _probeLabels[name] ?? name;
    final ms = probe['duration_ms'];
    final duration = ms == null ? '' : ' · ${ms}ms';
    if (probe['status'] == 'skipped') {
      return ListTile(
        dense: true,
        leading: const Icon(Icons.remove_circle_outline),
        title: Text(label),
        subtitle: const Text('Monitoramento não configurado'),
      );
    }
    final ok = probe['ok'] == true;
    final detail = ok
        ? 'Respondendo$duration'
        : 'Falhou (${probe['error'] ?? 'HTTP ${probe['http_status']}'})$duration';
    return ListTile(
      dense: true,
      leading: Icon(
        ok ? Icons.check_circle_outline : Icons.error_outline,
        color: ok ? Colors.green : Theme.of(context).colorScheme.error,
      ),
      title: Text(label),
      subtitle: Text(detail),
    );
  }

  @override
  Widget build(BuildContext context) {
    final probes =
        (_status?['probes'] as List?)?.cast<Map<String, dynamic>>() ??
            const [];
    final backup = _status?['backup'] as Map<String, dynamic>?;
    final latest = backup?['latest'] as Map<String, dynamic>?;
    final uptime = _status?['uptime_seconds'];
    final uptimeText = uptime is int
        ? (uptime >= 3600
            ? '${uptime ~/ 3600}h${(uptime % 3600) ~/ 60}min'
            : '${uptime ~/ 60}min')
        : '—';

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Saúde do serviço', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        const Text(
          'Dependências verificadas pelo bridge agora. Falhas aqui indicam '
          'incidente na infraestrutura, não na sua conta.',
        ),
        const SizedBox(height: 16),
        if (loading && _status == null)
          const Center(child: CircularProgressIndicator())
        else if (_loadError != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.error_outline),
              title: const Text('Status indisponível'),
              subtitle: Text(_loadError!),
              trailing: TextButton(onPressed: _load, child: const Text('Tentar de novo')),
            ),
          )
        else ...[
          Card(
            child: Column(
              children: [
                for (final probe in probes) _probeTile(probe),
                const Divider(height: 1),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.schedule),
                  title: const Text('Bridge ativo há'),
                  subtitle: Text(uptimeText),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.backup_outlined),
                  title: const Text('Backup do quadro de trabalho'),
                  subtitle: Text(
                    latest == null
                        ? 'Nenhum backup registrado ainda.'
                        : 'Último: ${latest['file']}\n'
                            'Criado em ${_fmtDate(latest['created_at']?.toString())} · '
                            '${backup?['count'] ?? 0} arquivo(s) retidos',
                  ),
                  isThreeLine: latest != null,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: backingUp || loading ? null : _backupNow,
                      icon: backingUp
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined),
                      label: Text(backingUp ? 'Gravando…' : 'Fazer backup agora'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

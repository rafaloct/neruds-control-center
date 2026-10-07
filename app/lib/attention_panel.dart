import 'package:flutter/material.dart';

import 'app_config.dart';
import 'app_session.dart';
import 'portal_read.dart';
import 'session_widgets.dart';
import 'workflow_widgets.dart';

/// Home attention panel: real deadlines, review queue, field gaps and portal
/// news — every item comes from the bridge read layer with its fetch time.
class AttentionPanel extends StatefulWidget {
  const AttentionPanel({super.key, required this.onNavigate});

  /// Tab switcher callback (1 = Conteúdo, 2 = Inventário).
  final ValueChanged<int> onNavigate;

  @override
  State<AttentionPanel> createState() => _AttentionPanelState();
}

class _AttentionPanelState extends State<AttentionPanel> {
  final PortalReadApi _api = PortalReadApi();
  AttentionData? _data;
  bool _loading = false;

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
    if (!AppSession.instance.authenticated) {
      setState(() => _data = null);
      return;
    }
    setState(() => _loading = true);
    final data = await _api.loadAttention();
    if (mounted) {
      setState(() {
        _data = data;
        _loading = false;
      });
    }
  }

  String _when(PortalEvent event) {
    final days = event.daysUntil;
    if (days == null) return 'sem data';
    if (days == 0) return 'hoje';
    if (days == 1) return 'amanhã';
    if (days > 1) return 'em $days dias';
    return 'há ${-days} dias';
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = AppSession.instance;

    if (!session.authenticated) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Precisa de atenção',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'Entre com sua conta para ver prazos de eventos, a fila de '
                'revisão e as lacunas do inventário.',
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Precisa de atenção',
              style: theme.textTheme.titleLarge,
            ),
            if (data?.fetchedAt != null)
              Chip(
                avatar: const Icon(Icons.schedule, size: 16),
                label: Text(_stamp(data!.fetchedAt)),
              ),
            IconButton(
              tooltip: 'Atualizar painel',
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
        const SizedBox(height: 8),
        if (data == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          _eventsSection(data),
          _reviewSection(data),
          _gapsSection(data),
          _feedsSection(data),
        ],
      ],
    );
  }

  Widget _section({
    required IconData icon,
    required String title,
    required Widget child,
    required String? error,
    Widget? trailing,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 10),
            if (error != null)
              Text(
                error,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              )
            else
              child,
          ],
        ),
      ),
    );
  }

  Widget _eventsSection(AttentionData data) {
    final result = data.eventos;
    final upcoming = (result.data ?? const <PortalEvent>[])
        .where((e) => !e.past)
        .take(3)
        .toList();
    return _section(
      icon: Icons.event_outlined,
      title: 'Prazos de eventos',
      error: result.error,
      trailing: PortalLinkButton(
        label: 'Todos os eventos',
        url: '${AppConfig.portalUrl}/eventos',
      ),
      child: upcoming.isEmpty
          ? const Text('Nenhum evento futuro com data registrada no portal.')
          : Column(
              children: [
                for (final event in upcoming)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(event.title),
                    subtitle: Text(
                      [
                        _when(event),
                        if ((event.local ?? '').isNotEmpty) event.local!,
                      ].join(' · '),
                    ),
                    trailing: Wrap(
                      spacing: 4,
                      children: [
                        if ((event.signupUrl ?? '').isNotEmpty)
                          PortalLinkButton(
                            label: 'Inscrição',
                            url: event.signupUrl,
                          ),
                        if ((event.submissionUrl ?? '').isNotEmpty)
                          PortalLinkButton(
                            label: 'Submissão',
                            url: event.submissionUrl,
                          ),
                        PortalLinkButton(
                          label: 'Ver',
                          url: event.viewUrl,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _reviewSection(AttentionData data) {
    final result = data.pendingReview;
    final count = result.data ?? 0;
    return _section(
      icon: Icons.rate_review_outlined,
      title: 'Revisão editorial',
      error: result.error,
      trailing: TextButton(
        onPressed: () => widget.onNavigate(1),
        child: const Text('Abrir conteúdo'),
      ),
      child: Text(
        count == 0
            ? 'Nenhum rascunho aguardando revisão.'
            : '$count ${count == 1 ? 'rascunho aguarda' : 'rascunhos aguardam'} '
                  'revisão antes de qualquer publicação.',
      ),
    );
  }

  Widget _gapsSection(AttentionData data) {
    final result = data.lacunas;
    final rows = <({String typeLabel, String fieldLabel, int missing, String? url})>[];
    for (final type in result.data ?? const <GapType>[]) {
      for (final field in type.fields) {
        rows.add((
          typeLabel: type.label,
          fieldLabel: field.label,
          missing: field.missing,
          url: type.listingUrl,
        ));
      }
    }
    rows.sort((a, b) => b.missing.compareTo(a.missing));
    final top = rows.take(3).toList();
    return _section(
      icon: Icons.fact_check_outlined,
      title: 'Lacunas do inventário',
      error: result.error,
      trailing: TextButton(
        onPressed: () => widget.onNavigate(2),
        child: const Text('Abrir inventário'),
      ),
      child: top.isEmpty
          ? const Text('Nenhuma lacuna de campo monitorado nesta consulta.')
          : Column(
              children: [
                for (final row in top)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text('${row.typeLabel} · ${row.fieldLabel}'),
                    subtitle: Text(
                      '${row.missing} ${row.missing == 1 ? 'ficha sem' : 'fichas sem'} '
                      'este campo',
                    ),
                    trailing: PortalLinkButton(
                      label: 'Ver fichas',
                      url: row.url,
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _feedsSection(AttentionData data) {
    final result = data.feeds;
    final items = (result.data ?? const <FeedItem>[]).take(4).toList();
    return _section(
      icon: Icons.newspaper_outlined,
      title: 'Novidades do portal',
      error: result.error,
      child: items.isEmpty
          ? const Text('Nenhuma novidade retornada nesta consulta.')
          : Column(
              children: [
                for (final item in items)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(item.title),
                    trailing: PortalLinkButton(
                      label: 'Abrir',
                      url: item.link,
                    ),
                  ),
              ],
            ),
    );
  }
}

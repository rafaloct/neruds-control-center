import 'package:flutter/material.dart';

import 'app_session.dart';
import 'portal_read.dart';
import 'session_widgets.dart';

/// Home onboarding for new bolsistas: three guided first steps plus a single
/// recommended action ("O que faço agora?") ranked from the live attention
/// data — never from invented content.
class OnboardingCard extends StatelessWidget {
  const OnboardingCard({
    super.key,
    required this.data,
    required this.loading,
    required this.onNavigate,
  });

  /// Latest attention snapshot shared with [AttentionPanel]; null while
  /// unauthenticated or until the first load finishes.
  final AttentionData? data;

  /// True while a fresh attention load is in flight.
  final bool loading;

  /// Tab switcher callback shared with the dashboard navigation.
  final ValueChanged<int> onNavigate;

  _Recommendation _recommendation(AppSession session) {
    if (!session.authenticated) {
      return const _Recommendation(
        reason:
            'Entre com a sua conta para liberar as tarefas e o painel '
            'de atenção.',
        label: 'Entrar com minha conta',
        icon: Icons.login,
      );
    }
    final data = this.data;
    if (data == null) {
      return _Recommendation(
        reason: loading
            ? 'Consultando o que precisa de atenção…'
            : 'O painel de atenção não respondeu nesta consulta. '
                  'O inventário é sempre um bom começo.',
        label: 'Abrir tarefas do inventário',
        icon: Icons.inventory_2_outlined,
        destination: 2,
      );
    }
    final review = data.pendingReview.data;
    if (session.canReview && (review?.count ?? 0) > 0) {
      final count = review!.count;
      final suffix = review.truncated ? '+' : '';
      return _Recommendation(
        reason:
            '$count$suffix '
            '${count == 1 ? 'rascunho aguarda' : 'rascunhos aguardam'} '
            'revisão antes da publicação.',
        label: 'Revisar rascunhos pendentes',
        icon: Icons.rate_review_outlined,
        destination: 1,
      );
    }
    // Soonest published deadline inside the next month outranks routine work.
    final events = data.eventos.data ?? const <PortalEvent>[];
    PortalEvent? soonest;
    for (final event in events) {
      final days = event.daysUntil;
      if (!event.published ||
          event.past ||
          days == null ||
          days < 0 ||
          days > 30) {
        continue;
      }
      if (soonest == null || days < soonest.daysUntil!) soonest = event;
    }
    final event = soonest;
    if (event != null) {
      final days = event.daysUntil!;
      final when = days == 0
          ? 'hoje'
          : days == 1
          ? 'amanhã'
          : 'em $days dias';
      return _Recommendation(
        reason: 'O prazo de "${event.title}" é $when.',
        label: 'Ver prazos em Monitoramento',
        icon: Icons.event_outlined,
        destination: 3,
      );
    }
    // Largest monitored-field gap names real, continuable work.
    ({String typeLabel, String fieldLabel, int missing})? top;
    for (final type in data.lacunas.data ?? const <GapType>[]) {
      for (final field in type.fields) {
        if (field.missing <= 0) continue;
        if (top == null || field.missing > top.missing) {
          top = (
            typeLabel: type.label,
            fieldLabel: field.label,
            missing: field.missing,
          );
        }
      }
    }
    final gap = top;
    if (gap != null) {
      return _Recommendation(
        reason:
            '${gap.missing} '
            '${gap.missing == 1 ? 'ficha de' : 'fichas de'} '
            '${gap.typeLabel} '
            '${gap.missing == 1 ? 'está sem' : 'estão sem'} '
            '${gap.fieldLabel}.',
        label: 'Completar fichas do inventário',
        icon: Icons.fact_check_outlined,
        destination: 2,
      );
    }
    return const _Recommendation(
      reason:
          'Nenhum prazo urgente nesta consulta. Aproveite para examinar '
          'a caixa de oportunidades.',
      label: 'Examinar oportunidades',
      icon: Icons.rss_feed_outlined,
      destination: 4,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = AppSession.instance;
    final signedIn = session.authenticated;
    final recommendation = _recommendation(session);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.signpost_outlined,
                  color: theme.colorScheme.secondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Comece por aqui',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Três passos até a primeira tarefa. Você não precisa de '
              'treinamento nem de documentação externa.',
            ),
            const SizedBox(height: 16),
            _OnboardingStep(
              index: 1,
              title: 'Entre com a sua conta',
              description:
                  'Cada pessoa usa a conta individual do portal; '
                  'as permissões acompanham o usuário.',
              state: signedIn ? _StepState.done : _StepState.current,
            ),
            _OnboardingStep(
              index: 2,
              title: 'Veja o que precisa de atenção',
              description:
                  'O painel abaixo traz prazos, revisões e lacunas '
                  'reais do portal.',
              state: !signedIn
                  ? _StepState.pending
                  : data != null
                  ? _StepState.done
                  : _StepState.current,
            ),
            _OnboardingStep(
              index: 3,
              title: 'Escolha uma tarefa e registre o que fez',
              description:
                  'No Inventário, filtre por responsável e registre a '
                  'evidência na própria tarefa.',
              state: _StepState.pending,
            ),
            const SizedBox(height: 4),
            const Divider(),
            const SizedBox(height: 10),
            Text('O que faço agora?', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            // liveRegion announces the new reason whenever the ranking
            // changes (sign-in, fresh data, resolved review queue).
            Semantics(liveRegion: true, child: Text(recommendation.reason)),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: () => recommendation.run(context, onNavigate),
              icon: Icon(recommendation.icon, size: 20),
              label: Text(recommendation.label),
            ),
          ],
        ),
      ),
    );
  }
}

enum _StepState { done, current, pending }

/// One read-only checklist row; the recommended action below is the single
/// place that offers a button, so the steps stay calm for novices.
class _OnboardingStep extends StatelessWidget {
  const _OnboardingStep({
    required this.index,
    required this.title,
    required this.description,
    required this.state,
  });

  static const _total = 3;

  final int index;
  final String title;
  final String description;
  final _StepState state;

  String get _stateLabel => switch (state) {
    _StepState.done => 'concluído',
    _StepState.current => 'em andamento',
    _StepState.pending => 'pendente',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = state == _StepState.current;
    return Semantics(
      container: true,
      label: 'Passo $index de $_total: $title — $_stateLabel',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StepBadge(index: index, state: state),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: current ? FontWeight.w700 : FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepBadge extends StatelessWidget {
  const _StepBadge({required this.index, required this.state});

  final int index;
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (state == _StepState.done) {
      return Icon(
        Icons.check_circle,
        size: 26,
        color: theme.colorScheme.secondary,
      );
    }
    final current = state == _StepState.current;
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // Soft highlight marks the next action per the design system.
        color: current ? theme.colorScheme.primaryContainer : null,
        border: Border.all(
          color: current
              ? theme.colorScheme.secondary
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Text('$index', style: theme.textTheme.labelMedium),
    );
  }
}

/// One ranked next action: a plain-language reason plus a destination tab,
/// or the shared sign-in dialog when [destination] is null.
class _Recommendation {
  const _Recommendation({
    required this.reason,
    required this.label,
    required this.icon,
    this.destination,
  });

  final String reason;
  final String label;
  final IconData icon;

  /// Target tab (1 = Conteúdo, 2 = Inventário, 3 = Monitoramento,
  /// 4 = Oportunidades); null opens the sign-in dialog.
  final int? destination;

  void run(BuildContext context, ValueChanged<int> onNavigate) {
    final target = destination;
    if (target == null) {
      showSignInDialog(context);
    } else {
      onNavigate(target);
    }
  }
}

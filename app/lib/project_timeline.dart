import 'package:flutter/material.dart';

import 'manage_models.dart';
import 'manage_service.dart';

/// Um item do gráfico — período com rótulo e cor por setor.
class TimelineItem {
  const TimelineItem({
    required this.label,
    required this.start,
    required this.end,
    required this.color,
    this.status,
  });

  final String label;
  final DateTime start;
  final DateTime end;
  final Color color;
  final String? status;
}

/// Gantt simples renderizado sem dependências — barras posicionadas por
/// fração do intervalo total. Integrável em qualquer página de detalhe.
class ProjectTimeline extends StatelessWidget {
  const ProjectTimeline({super.key, required this.items});

  final List<TimelineItem> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('Nenhum item com período definido.'),
      );
    }
    var min = items.first.start;
    var max = items.first.end;
    for (final i in items) {
      if (i.start.isBefore(min)) min = i.start;
      if (i.end.isAfter(max)) max = i.end;
    }
    final span = max.difference(min).inDays.clamp(1, 3650);
    final monthNames = [
      '', 'jan', 'fev', 'mar', 'abr', 'mai', 'jun',
      'jul', 'ago', 'set', 'out', 'nov', 'dez',
    ];
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Cronograma', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            for (final item in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        Text(
                          '${monthNames[item.start.month]}/${item.start.year} '
                          '→ ${monthNames[item.end.month]}/${item.end.year}',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    LayoutBuilder(
                      builder: (context, c) {
                        final left = item.start
                                .difference(min)
                                .inDays /
                            span *
                            c.maxWidth;
                        final width = (item.end
                                    .difference(item.start)
                                    .inDays
                                    .clamp(1, span) /
                                span *
                                c.maxWidth)
                            .clamp(6.0, c.maxWidth - left);
                        return Container(
                          height: 14,
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: EdgeInsets.only(left: left),
                              child: Container(
                                width: width,
                                height: 14,
                                decoration: BoxDecoration(
                                  color: item.color,
                                  borderRadius: BorderRadius.circular(7),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${monthNames[min.month]}/${min.year}',
                    style: Theme.of(context).textTheme.labelSmall),
                Text('${monthNames[max.month]}/${max.year}',
                    style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Página de cronograma do projeto — agrega o projeto, seus relatórios,
/// reuniões e ações extensionistas vinculadas em um único eixo temporal.
class ProjectTimelinePage extends StatefulWidget {
  const ProjectTimelinePage({super.key, required this.project});

  final ManageItem project;

  @override
  State<ProjectTimelinePage> createState() => _ProjectTimelinePageState();
}

class _ProjectTimelinePageState extends State<ProjectTimelinePage> {
  List<TimelineItem> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  DateTime? _date(dynamic raw) {
    if (raw is Map) raw = raw['value'] ?? raw['start'];
    if (raw == null) return null;
    return DateTime.tryParse(raw.toString());
  }

  Future<void> _load() async {
    final scheme = Theme.of(context).colorScheme;
    final items = <TimelineItem>[];
    try {
      final project = await ManageService.detail(
        'projeto_pesquisa_extensao',
        widget.project.nid,
      );
      final values = (project['values'] as Map?) ?? const {};
      final start = _date(values['field_data_inicio']);
      final end = _date(values['field_data_fim']) ?? start;
      if (start != null && end != null) {
        items.add(TimelineItem(
          label: 'Projeto: ${widget.project.title}',
          start: start,
          end: end,
          color: scheme.primary,
        ));
      }
      // Relatórios e reuniões vinculados ao projeto (filtro por relação).
      const linked = [
        ('relatorio', 'field_projeto_vinculado', 'field_periodo_relatorio'),
        ('reuniao', 'field_projeto', 'field_data_reuniao'),
      ];
      for (final (bundle, relField, dateField) in linked) {
        final linked = await ManageService.list(
          bundle,
          rel: relField,
          relId: widget.project.uuid,
          limit: 10,
        );
        for (final it in linked) {
          final detail = await ManageService.detail(bundle, it.nid);
          final v = (detail['values'] as Map?) ?? const {};
          final raw = v[dateField];
          final s = _date(raw);
          var e = s;
          if (raw is Map) e = _date(raw['end_value']) ?? s;
          if (s != null && e != null) {
            items.add(TimelineItem(
              label: it.title,
              start: s,
              end: e,
              color: bundle == 'relatorio'
                  ? scheme.tertiary
                  : scheme.secondary,
              status: it.status ? null : 'rascunho',
            ));
          }
        }
      }
    } catch (_) {
      // linha do tempo vazia já é comunicada pelo widget
    }
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Cronograma — ${widget.project.title}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                ProjectTimeline(items: _items),
                if (_items.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 16,
                      children: [
                        _Legend(
                          color: Theme.of(context).colorScheme.primary,
                          label: 'Projeto',
                        ),
                        _Legend(
                          color: Theme.of(context).colorScheme.tertiary,
                          label: 'Relatórios',
                        ),
                        _Legend(
                          color: Theme.of(context).colorScheme.secondary,
                          label: 'Reuniões',
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

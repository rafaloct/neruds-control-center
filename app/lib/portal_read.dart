import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'app_config.dart';
import 'app_session.dart';
import 'bridge_http.dart' as http;
import 'workflow_widgets.dart';

/// Read-only data from the portal's real structure (bridge issue #22).
/// Every collection is stamped with the bridge fetch time, never invented.

/// Bumped whenever a mission task is created outside the Inventário page
/// (e.g. from a monitoring gap), so the retained page reloads.
final missionBoardChanged = ValueNotifier<int>(0);

class GapNodeRef {
  const GapNodeRef({
    required this.nid,
    required this.title,
    this.viewUrl,
    this.editUrl,
  });

  final int? nid;
  final String title;
  final String? viewUrl;
  final String? editUrl;
}

class GapField {
  const GapField({
    required this.field,
    required this.label,
    required this.missing,
    required this.nodes,
  });

  final String field;
  final String label;
  final int missing;
  final List<GapNodeRef> nodes;
}

class GapType {
  const GapType({
    required this.type,
    required this.label,
    required this.published,
    this.listingUrl,
    required this.fields,
  });

  final String type;
  final String label;
  final int published;
  final String? listingUrl;
  final List<GapField> fields;
}

/// Aggregated gap rows plus whether the bridge truncated the sample
/// (a field's `missing` count exceeded the returned node list).
class GapReport {
  const GapReport({required this.nodes, this.truncated = false});

  final List<GapNode> nodes;
  final bool truncated;
}

/// One node aggregated across the monitored fields it is missing.
class GapNode {
  const GapNode({
    required this.title,
    required this.type,
    this.nid,
    this.viewUrl,
    this.editUrl,
    required this.missing,
    required this.missingFields,
  });

  final int? nid;

  /// Bundle machine name (e.g. `publicacao_cientifica`) — needed to create
  /// a gap task and to re-check the node later.
  final String type;
  final String title;
  final String? viewUrl;
  final String? editUrl;
  final List<String> missing;

  /// Machine names of the missing fields, parallel to [missing].
  final List<String> missingFields;
}

/// Fresh per-node gap state from the reconciliation endpoint — never
/// cached, it reads the portal's current values.
class NodeGapCheck {
  const NodeGapCheck({
    required this.found,
    this.published = true,
    this.title,
    this.viewUrl,
    this.editUrl,
    this.missingFields = const [],
    this.missingLabels = const [],
  });

  final bool found;
  final bool published;
  final String? title;
  final String? viewUrl;
  final String? editUrl;
  final List<String> missingFields;
  final List<String> missingLabels;
}

/// One node inside a shared-DOI group.
class DuplicateNode {
  const DuplicateNode({
    required this.title,
    required this.type,
    required this.typeLabel,
    this.nid,
    this.viewUrl,
    this.editUrl,
  });

  final int? nid;
  final String title;
  final String type;
  final String typeLabel;
  final String? viewUrl;
  final String? editUrl;
}

/// Nodes that repeat the same normalized DOI — a review signal only.
class DuplicateGroup {
  const DuplicateGroup({required this.doi, required this.nodes});

  final String doi;
  final List<DuplicateNode> nodes;
}

/// Mission option for the gap-task picker.
class MissionRef {
  const MissionRef({required this.id, required this.title});

  final int id;
  final String title;
}

class PortalEvent {
  const PortalEvent({
    required this.title,
    this.nid,
    this.date,
    this.daysUntil,
    this.past = false,
    this.published = true,
    this.local,
    this.signupUrl,
    this.submissionUrl,
    this.callOpen,
    this.viewUrl,
    this.editUrl,
  });

  final int? nid;
  final String title;
  final String? date;
  final int? daysUntil;
  final bool past;

  /// False when the node is an unpublished draft (monitoring surfaces
  /// it so "in preparation" events stay visible).
  final bool published;
  final String? local;
  final String? signupUrl;
  final String? submissionUrl;

  /// False means the call for papers is closed — do not offer submission.
  final bool? callOpen;
  final String? viewUrl;
  final String? editUrl;
}

class FeedItem {
  const FeedItem({
    required this.title,
    required this.link,
    this.published,
    this.section,
  });

  final String title;
  final String link;
  final String? published;

  /// Feed section this item came from (`noticias`, `eventos`, ...).
  final String? section;
}

/// Latest portal items plus the feed sections that failed to answer.
class FeedList {
  const FeedList({required this.items, this.failedSections = const []});

  final List<FeedItem> items;
  final List<String> failedSections;
}

/// Pending-review count; [truncated] means the bridge hit the page cap and
/// the real number is higher.
class ReviewCount {
  const ReviewCount({required this.count, this.truncated = false});

  final int count;
  final bool truncated;
}

class PortalProject {
  const PortalProject({
    required this.title,
    this.nid,
    this.coordinator,
    this.start,
    this.end,
    this.summary,
    this.status = const [],
    this.kind = const [],
    this.eixos = const [],
    this.linhas = const [],
    this.ods = const [],
    this.viewUrl,
    this.editUrl,
  });

  final int? nid;
  final String title;
  final String? coordinator;
  final String? start;
  final String? end;
  final String? summary;
  final List<String> status;
  final List<String> kind;
  final List<String> eixos;
  final List<String> linhas;
  final List<String> ods;
  final String? viewUrl;
  final String? editUrl;
}

class PortalAction {
  const PortalAction({
    required this.title,
    this.nid,
    this.local,
    this.participants,
    this.municipality = const [],
    this.kind = const [],
    this.viewUrl,
    this.editUrl,
  });

  final int? nid;
  final String title;
  final String? local;
  final int? participants;
  final List<String> municipality;
  final List<String> kind;
  final String? viewUrl;
  final String? editUrl;
}

class ProjectBoard {
  const ProjectBoard({
    required this.projects,
    required this.actions,
    this.listingUrl,
    this.mapUrl,
  });

  final List<PortalProject> projects;
  final List<PortalAction> actions;
  final String? listingUrl;
  final String? mapUrl;
}

/// One panel section: either real data or an explained failure.
class SectionResult<T> {
  const SectionResult._(this.data, this.error);

  const SectionResult.ok(T data) : this._(data, null);
  const SectionResult.failure(String error) : this._(null, error);

  final T? data;
  final String? error;
  bool get ok => error == null;
}

class AttentionData {
  AttentionData({
    this.fetchedAt,
    required this.eventos,
    required this.lacunas,
    required this.feeds,
    required this.pendingReview,
    this.eventsListingUrl,
  });

  /// Oldest fetch timestamp across the sections that answered.
  final String? fetchedAt;
  final SectionResult<List<PortalEvent>> eventos;
  final SectionResult<List<GapType>> lacunas;
  final SectionResult<FeedList> feeds;
  final SectionResult<ReviewCount> pendingReview;

  /// Public events listing reported by the bridge (absolute portal URL).
  final String? eventsListingUrl;
}

class MonitoringData {
  MonitoringData({
    this.fetchedAt,
    required this.projetos,
    required this.eventos,
    required this.publicacoes,
    required this.noticias,
    required this.feeds,
    required this.projetoGaps,
    required this.acaoGaps,
    required this.eventoGaps,
    required this.duplicates,
    this.eventsListingUrl,
    this.projetosListingUrl,
    this.projetosMapUrl,
    this.publicacoesListingUrl,
    this.noticiasListingUrl,
  });

  final String? fetchedAt;
  final SectionResult<ProjectBoard> projetos;
  final SectionResult<List<PortalEvent>> eventos;
  final SectionResult<GapReport> publicacoes;
  final SectionResult<GapReport> noticias;
  final SectionResult<FeedList> feeds;

  /// Per-node field gaps for the project/action and event axes.
  final SectionResult<GapReport> projetoGaps;
  final SectionResult<GapReport> acaoGaps;
  final SectionResult<GapReport> eventoGaps;

  /// Nodes sharing a DOI across portal bundles — review signal only.
  final SectionResult<List<DuplicateGroup>> duplicates;
  final String? eventsListingUrl;
  final String? projetosListingUrl;
  final String? projetosMapUrl;
  final String? publicacoesListingUrl;
  final String? noticiasListingUrl;

  /// Missing-field details keyed by node id, merged across gap sections.
  Map<int, GapNode> gapsByNode() {
    final map = <int, GapNode>{};
    for (final section in [projetoGaps, acaoGaps, eventoGaps]) {
      for (final gap in section.data?.nodes ?? const <GapNode>[]) {
        final nid = gap.nid;
        if (nid != null) map[nid] = gap;
      }
    }
    return map;
  }
}

class PortalReadApi {
  PortalReadApi();

  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, String>? q,
  ]) async {
    final uri = AppConfig.endpoint(path);
    final response = await http.get(
      q == null ? uri : uri.replace(queryParameters: q),
      headers: AppSession.instance.authHeaders,
    );
    if (response.statusCode != 200) {
      throw HttpStatusException(response.statusCode);
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  Future<SectionResult<T>> _section<T>(
    List<String> stamps,
    FutureOr<T> Function(Map<String, dynamic> body) parse,
    String path, [
    Map<String, String>? q,
    void Function(Map<String, dynamic> body)? inspect,
  ]) async {
    try {
      final body = await _get(path, q);
      final stamp = body['fetched_at']?.toString();
      if (stamp != null && stamp.isNotEmpty) stamps.add(stamp);
      inspect?.call(body);
      return SectionResult.ok(await parse(body));
    } catch (error) {
      return SectionResult.failure(workflowError(error));
    }
  }

  static List<PortalEvent> _parseEvents(Map<String, dynamic> body) =>
      (body['events'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (e) => PortalEvent(
              nid: e['nid'] as int?,
              title: (e['title'] ?? 'Sem título').toString(),
              date: e['date']?.toString(),
              daysUntil: e['days_until'] as int?,
              past: e['past'] == true,
              published: e['published'] != false,
              local: e['local']?.toString(),
              signupUrl: e['signup_url']?.toString(),
              submissionUrl: e['submission_url']?.toString(),
              callOpen: e['call_open'] as bool?,
              viewUrl: e['view_url']?.toString(),
              editUrl: e['edit_url']?.toString(),
            ),
          )
          .toList();

  static List<GapType> _parseGapTypes(Map<String, dynamic> body) =>
      (body['types'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (t) => GapType(
              type: (t['type'] ?? '').toString(),
              label: (t['label'] ?? t['type'] ?? '').toString(),
              published: (t['published'] as int?) ?? 0,
              listingUrl: t['listing_url']?.toString(),
              fields: (t['fields'] as List? ?? const [])
                  .whereType<Map>()
                  .map(
                    (f) => GapField(
                      field: (f['field'] ?? '').toString(),
                      label: (f['label'] ?? f['field'] ?? '').toString(),
                      missing: (f['missing'] as int?) ?? 0,
                      nodes: (f['nodes'] as List? ?? const [])
                          .whereType<Map>()
                          .map(
                            (n) => GapNodeRef(
                              nid: n['nid'] as int?,
                              title: (n['title'] ?? 'Sem título').toString(),
                              viewUrl: n['view_url']?.toString(),
                              editUrl: n['edit_url']?.toString(),
                            ),
                          )
                          .toList(),
                    ),
                  )
                  .toList(),
            ),
          )
          .toList();

  /// Aggregate a bundle's gap report into one row per node with the labels
  /// and machine names of every monitored field it is missing.
  static GapReport _gapNodes(Map<String, dynamic> body) {
    final byNid = <String, GapNode>{};
    var truncated = false;
    for (final type in _parseGapTypes(body)) {
      for (final field in type.fields) {
        if (field.missing > field.nodes.length) truncated = true;
        for (final node in field.nodes) {
          final key = (node.nid ?? node.title).toString();
          final existing = byNid[key];
          if (existing == null) {
            byNid[key] = GapNode(
              nid: node.nid,
              type: type.type,
              title: node.title,
              viewUrl: node.viewUrl,
              editUrl: node.editUrl,
              missing: [field.label],
              missingFields: [field.field],
            );
          } else if (!existing.missingFields.contains(field.field)) {
            existing.missing.add(field.label);
            existing.missingFields.add(field.field);
          }
        }
      }
    }
    final nodes = byNid.values.toList()
      ..sort((a, b) => b.missing.length.compareTo(a.missing.length));
    return GapReport(nodes: nodes, truncated: truncated);
  }

  static FeedList _parseFeeds(Map<String, dynamic> body) {
    final items = <FeedItem>[];
    final failed = <String>[];
    final sections = body['sections'] as Map? ?? const {};
    for (final entry in sections.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      if (value['ok'] != true) {
        failed.add(entry.key.toString());
        continue;
      }
      for (final item in (value['items'] as List? ?? const [])) {
        if (item is! Map) continue;
        items.add(
          FeedItem(
            title: (item['title'] ?? '').toString(),
            link: (item['link'] ?? '').toString(),
            published: item['published']?.toString(),
            section: entry.key.toString(),
          ),
        );
      }
    }
    items.sort((a, b) => (b.published ?? '').compareTo(a.published ?? ''));
    return FeedList(items: items, failedSections: failed);
  }

  static List<DuplicateGroup> _parseDuplicates(Map<String, dynamic> body) =>
      (body['groups'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (g) => DuplicateGroup(
              doi: (g['doi'] ?? '').toString(),
              nodes: (g['nodes'] as List? ?? const [])
                  .whereType<Map>()
                  .map(
                    (n) => DuplicateNode(
                      nid: n['nid'] as int?,
                      title: (n['title'] ?? 'Sem título').toString(),
                      type: (n['type'] ?? '').toString(),
                      typeLabel:
                          (n['type_label'] ?? n['type'] ?? '').toString(),
                      viewUrl: n['view_url']?.toString(),
                      editUrl: n['edit_url']?.toString(),
                    ),
                  )
                  .toList(),
            ),
          )
          .toList();

  static ProjectBoard _parseProjects(Map<String, dynamic> body) => ProjectBoard(
    projects: (body['projetos'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (p) => PortalProject(
            nid: p['nid'] as int?,
            title: (p['title'] ?? 'Sem título').toString(),
            coordinator: p['coordinator']?.toString(),
            start: p['start']?.toString(),
            end: p['end']?.toString(),
            summary: p['summary']?.toString(),
            status:
                (p['status'] as List? ?? const [])
                    .map((s) => s.toString())
                    .toList(),
            kind:
                (p['kind'] as List? ?? const []).map((s) => s.toString()).toList(),
            eixos:
                (p['eixos'] as List? ?? const [])
                    .map((s) => s.toString())
                    .toList(),
            linhas:
                (p['linhas_pesquisa'] as List? ?? const [])
                    .map((s) => s.toString())
                    .toList(),
            ods:
                (p['ods'] as List? ?? const []).map((s) => s.toString()).toList(),
            viewUrl: p['view_url']?.toString(),
            editUrl: p['edit_url']?.toString(),
          ),
        )
        .toList(),
    actions: (body['acoes'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (a) => PortalAction(
            nid: a['nid'] as int?,
            title: (a['title'] ?? 'Sem título').toString(),
            local: a['local']?.toString(),
            participants: a['participants'] as int?,
            municipality:
                (a['municipality'] as List? ?? const [])
                    .map((s) => s.toString())
                    .toList(),
            kind:
                (a['kind'] as List? ?? const []).map((s) => s.toString()).toList(),
            viewUrl: a['view_url']?.toString(),
            editUrl: a['edit_url']?.toString(),
          ),
        )
        .toList(),
    listingUrl: body['listing_url']?.toString(),
    mapUrl: body['map_url']?.toString(),
  );

  Future<AttentionData> loadAttention() async {
    final stamps = <String>[];
    String? eventsListingUrl;

    final results = await Future.wait([
      _section<List<PortalEvent>>(
        stamps,
        _parseEvents,
        '/portal/eventos',
        null,
        (body) => eventsListingUrl = body['listing_url']?.toString(),
      ),
      _section<List<GapType>>(stamps, _parseGapTypes, '/portal/lacunas'),
      _section<FeedList>(stamps, _parseFeeds, '/portal/feeds'),
      _section<ReviewCount>(stamps, (body) {
        final items = body['items'] as List? ?? const [];
        // Bridges older than the `truncated` flag cap the upstream page at
        // 50 — a full page without the flag can still hide more drafts.
        final truncated =
            body['truncated'] == true ||
            (body['truncated'] == null && items.length >= 50);
        return ReviewCount(count: items.length, truncated: truncated);
      }, '/content/news/drafts', {
        'status': 'pending',
        'limit': '200',
      }),
    ]);

    // The panel shows the oldest fetch: nothing is fresher than that.
    stamps.sort();
    return AttentionData(
      fetchedAt: stamps.isEmpty ? null : stamps.first,
      eventos: results[0] as SectionResult<List<PortalEvent>>,
      lacunas: results[1] as SectionResult<List<GapType>>,
      feeds: results[2] as SectionResult<FeedList>,
      pendingReview: results[3] as SectionResult<ReviewCount>,
      eventsListingUrl: eventsListingUrl,
    );
  }

  /// All four real monitoring axes in one parallel load.
  Future<MonitoringData> loadMonitoring() async {
    final stamps = <String>[];
    String? eventsListingUrl;
    String? projetosListingUrl;
    String? projetosMapUrl;
    String? publicacoesListingUrl;
    String? noticiasListingUrl;

    String? typeListingUrl(Map<String, dynamic> body, String tipo) {
      for (final type in _parseGapTypes(body)) {
        if (type.type == tipo) return type.listingUrl;
      }
      return null;
    }

    final results = await Future.wait([
      _section<ProjectBoard>(
        stamps,
        _parseProjects,
        '/portal/projetos',
        null,
        (body) {
          projetosListingUrl = body['listing_url']?.toString();
          projetosMapUrl = body['map_url']?.toString();
        },
      ),
      _section<List<PortalEvent>>(
        stamps,
        _parseEvents,
        '/portal/eventos',
        null,
        (body) => eventsListingUrl = body['listing_url']?.toString(),
      ),
      _section<GapReport>(
        stamps,
        _gapNodes,
        '/portal/lacunas',
        {'tipo': 'publicacao_cientifica', 'limite_nodes': '200'},
        (body) =>
            publicacoesListingUrl = typeListingUrl(body, 'publicacao_cientifica'),
      ),
      _section<GapReport>(
        stamps,
        _gapNodes,
        '/portal/lacunas',
        {'tipo': 'noticia', 'limite_nodes': '200'},
        (body) => noticiasListingUrl = typeListingUrl(body, 'noticia'),
      ),
      _section<FeedList>(stamps, _parseFeeds, '/portal/feeds'),
      // Per-node gaps for the remaining monitored bundles (plan §axes).
      _section<GapReport>(
        stamps,
        _gapNodes,
        '/portal/lacunas',
        {'tipo': 'projeto_pesquisa_extensao', 'limite_nodes': '200'},
      ),
      _section<GapReport>(
        stamps,
        _gapNodes,
        '/portal/lacunas',
        {'tipo': 'acao_extensionista', 'limite_nodes': '200'},
      ),
      _section<GapReport>(
        stamps,
        _gapNodes,
        '/portal/lacunas',
        // Drafts included so the event tab can show gaps on rascunhos
        // the session can see; the bridge scopes this cache per user.
        {
          'tipo': 'evento_cientifico',
          'limite_nodes': '200',
          'incluir_rascunhos': 'true',
        },
      ),
      _section<List<DuplicateGroup>>(
        stamps,
        _parseDuplicates,
        '/portal/duplicatas',
      ),
    ]);

    stamps.sort();
    // Listing URLs come from the live response when it succeeds; static
    // portal paths keep the links working when the gap query fails.
    final portal = AppConfig.portalUrl.replaceAll(RegExp(r'/+$'), '');
    return MonitoringData(
      fetchedAt: stamps.isEmpty ? null : stamps.first,
      projetos: results[0] as SectionResult<ProjectBoard>,
      eventos: results[1] as SectionResult<List<PortalEvent>>,
      publicacoes: results[2] as SectionResult<GapReport>,
      noticias: results[3] as SectionResult<GapReport>,
      feeds: results[4] as SectionResult<FeedList>,
      projetoGaps: results[5] as SectionResult<GapReport>,
      acaoGaps: results[6] as SectionResult<GapReport>,
      eventoGaps: results[7] as SectionResult<GapReport>,
      duplicates: results[8] as SectionResult<List<DuplicateGroup>>,
      eventsListingUrl: eventsListingUrl ?? '$portal/eventos',
      projetosListingUrl: projetosListingUrl ?? '$portal/projetos',
      projetosMapUrl: projetosMapUrl ?? '$portal/mapa-projetos',
      publicacoesListingUrl:
          publicacoesListingUrl ?? '$portal/publicacoes',
      noticiasListingUrl: noticiasListingUrl ?? '$portal/noticias',
    );
  }

  /// Re-check one node's monitored fields against the portal right now —
  /// the bridge answers uncached so reconciliation reflects real state.
  Future<NodeGapCheck> nodeGapCheck(int nid, String tipo) async {
    final body = await _get('/portal/nodes/$nid/lacunas', {'tipo': tipo});
    return NodeGapCheck(
      found: body['found'] == true,
      published: body['published'] != false,
      title: body['title']?.toString(),
      viewUrl: body['view_url']?.toString(),
      editUrl: body['edit_url']?.toString(),
      missingFields: (body['missing_fields'] as List? ?? const [])
          .map((f) => f.toString())
          .toList(),
      missingLabels: (body['missing_labels'] as List? ?? const [])
          .map((f) => f.toString())
          .toList(),
    );
  }

  /// Missions the signed-in user can attach gap tasks to.
  Future<List<MissionRef>> listMissions() async {
    final response = await http.get(
      AppConfig.endpoint('/missions'),
      headers: AppSession.instance.authHeaders,
    );
    if (response.statusCode != 200) {
      throw HttpStatusException(response.statusCode);
    }
    return (jsonDecode(utf8.decode(response.bodyBytes)) as List? ?? const [])
        .whereType<Map>()
        .map(
          (m) => MissionRef(
            id: m['id'] as int? ?? 0,
            title: (m['title'] ?? m['code'] ?? 'Missão').toString(),
          ),
        )
        .where((m) => m.id > 0)
        .toList();
  }

  /// Turn a portal gap into a tracked mission task. The bridge validates
  /// the ficha links and the monitored field names server-side.
  Future<Map<String, dynamic>> createGapTask(
    int missionId, {
    required GapNode node,
    required String title,
    required String responsible,
    required String action,
  }) async {
    final portal = AppConfig.portalUrl.replaceAll(RegExp(r'/+$'), '');
    final nid = node.nid;
    // Prefer the canonical links the gap endpoint already returned — the
    // portal snapshot may not have populated AppConfig.portalUrl yet.
    final viewUrl = node.viewUrl ??
        ((nid != null && portal.isNotEmpty) ? '$portal/node/$nid' : null);
    final editUrl = node.editUrl ??
        ((nid != null && portal.isNotEmpty)
            ? '$portal/node/$nid/edit'
            : null);
    final payload = <String, dynamic>{
      'title': title,
      'responsible': responsible,
      'action': action,
      'gaps': 'Faltam no portal: ${node.missing.join(', ')}',
      'gap_bundle': node.type,
      'gap_fields': node.missingFields,
      // primary_owner is a controlled field — only review-capable
      // sessions may set it; others keep the free-text responsible.
      if (AppSession.instance.canReview) 'primary_owner': responsible,
      'public_url': ?viewUrl,
      'edit_url': ?editUrl,
    };
    final response = await http.post(
      AppConfig.endpoint('/missions/$missionId/tasks'),
      headers: AppSession.instance.authHeaders,
      body: jsonEncode(payload),
    );
    if (response.statusCode != 201) {
      throw HttpStatusException(response.statusCode);
    }
    return Map<String, dynamic>.from(
      jsonDecode(utf8.decode(response.bodyBytes)) as Map,
    );
  }
}

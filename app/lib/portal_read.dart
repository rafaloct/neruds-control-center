import 'dart:async';
import 'dart:convert';

import 'app_config.dart';
import 'app_session.dart';
import 'bridge_http.dart' as http;
import 'workflow_widgets.dart';

/// Read-only data from the portal's real structure (bridge issue #22).
/// Every collection is stamped with the bridge fetch time, never invented.

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

class PortalEvent {
  const PortalEvent({
    required this.title,
    this.nid,
    this.date,
    this.daysUntil,
    this.past = false,
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
  final String? local;
  final String? signupUrl;
  final String? submissionUrl;

  /// False means the call for papers is closed — do not offer submission.
  final bool? callOpen;
  final String? viewUrl;
  final String? editUrl;
}

class FeedItem {
  const FeedItem({required this.title, required this.link, this.published});

  final String title;
  final String link;
  final String? published;
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

class PortalReadApi {
  PortalReadApi();

  Future<AttentionData> loadAttention() async {
    final session = AppSession.instance;
    final headers = session.authHeaders;

    Future<Map<String, dynamic>> get(String path, [Map<String, String>? q]) async {
      final uri = AppConfig.endpoint(path);
      final response = await http.get(
        q == null ? uri : uri.replace(queryParameters: q),
        headers: headers,
      );
      if (response.statusCode != 200) {
        throw http.ClientException('HTTP ${response.statusCode}');
      }
      return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    }

    final stamps = <String>[];
    Future<SectionResult<T>> section<T>(
      FutureOr<T> Function(Map<String, dynamic> body) parse,
      String path, [
      Map<String, String>? q,
      void Function(Map<String, dynamic> body)? inspect,
    ]) async {
      try {
        final body = await get(path, q);
        final stamp = body['fetched_at']?.toString();
        if (stamp != null && stamp.isNotEmpty) stamps.add(stamp);
        inspect?.call(body);
        return SectionResult.ok(await parse(body));
      } catch (error) {
        return SectionResult.failure(workflowError(error));
      }
    }

    String? eventsListingUrl;

    final results = await Future.wait([
      section<List<PortalEvent>>(
        (body) => (body['events'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (e) => PortalEvent(
                nid: e['nid'] as int?,
                title: (e['title'] ?? 'Sem título').toString(),
                date: e['date']?.toString(),
                daysUntil: e['days_until'] as int?,
                past: e['past'] == true,
                local: e['local']?.toString(),
                signupUrl: e['signup_url']?.toString(),
                submissionUrl: e['submission_url']?.toString(),
                callOpen: e['call_open'] as bool?,
                viewUrl: e['view_url']?.toString(),
                editUrl: e['edit_url']?.toString(),
              ),
            )
            .toList(),
        '/portal/eventos',
        null,
        (body) => eventsListingUrl = body['listing_url']?.toString(),
      ),
      section<List<GapType>>(
        (body) => (body['types'] as List? ?? const [])
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
            .toList(),
        '/portal/lacunas',
      ),
      section<FeedList>((body) {
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
              ),
            );
          }
        }
        items.sort(
          (a, b) => (b.published ?? '').compareTo(a.published ?? ''),
        );
        return FeedList(items: items, failedSections: failed);
      }, '/portal/feeds'),
      section<ReviewCount>((body) {
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
}

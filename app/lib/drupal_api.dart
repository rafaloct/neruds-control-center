import 'dart:convert';

import 'app_config.dart';
import 'bridge_http.dart' as http;
import 'workflow_widgets.dart';

class PortalSnapshot {
  const PortalSnapshot({
    required this.online,
    required this.generator,
    required this.contentTypes,
    required this.latestNews,
    required this.error,
    this.portalUrl = '',
    this.contentTypeLabels = const {},
    this.workflows = const {},
  });

  final bool online;
  final String generator;
  final List<String> contentTypes;
  final List<Map<String, String>> latestNews;
  final String? error;
  final String portalUrl;
  final Map<String, String> contentTypeLabels;
  final Map<String, String> workflows;
}

class DrupalApi {
  DrupalApi({String? baseUrl, String? bridgeUrl})
    : baseUrl = baseUrl ?? AppConfig.portalUrl,
      bridgeUrl = bridgeUrl ?? AppConfig.bridgeUrl;

  final String baseUrl;
  final String bridgeUrl;

  Future<PortalSnapshot> loadSnapshot() async {
    try {
      if (bridgeUrl.trim().isNotEmpty) {
        // Await here so asynchronous connection errors become a useful UI state.
        return await _loadFromBridge();
      }
      return await _loadDirectly();
    } catch (error) {
      return PortalSnapshot(
        online: false,
        generator: '',
        contentTypes: const [],
        latestNews: const [],
        portalUrl: baseUrl,
        error: workflowError(error),
      );
    }
  }

  Uri _endpoint(String base, String path) {
    final uri = AppConfig.webUri(base);
    if (uri == null || uri.hasQuery || uri.hasFragment) {
      throw const AppConfigurationException();
    }
    return Uri.parse('${base.replaceAll(RegExp(r'/+$'), '')}$path');
  }

  Future<PortalSnapshot> _loadFromBridge() async {
    if (AppConfig.bridgeUri(bridgeUrl) == null) {
      throw const AppConfigurationException();
    }
    final response = await http.get(_endpoint(bridgeUrl, '/portal/snapshot'));
    if (response.statusCode != 200) {
      throw http.ClientException('Portal consultation unavailable');
    }
    final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    final portal = payload['portal_url']?.toString() ?? baseUrl;
    AppConfig.rememberPortalUrl(portal);
    return PortalSnapshot(
      online: payload['online'] == true,
      generator: (payload['generator'] ?? 'Drupal').toString(),
      portalUrl: portal,
      contentTypes: (payload['content_types'] as List? ?? const [])
          .map((item) => item.toString())
          .toList(),
      contentTypeLabels: _stringMap(payload['content_type_labels']),
      workflows: _stringMap(payload['workflows']),
      latestNews: (payload['latest_news'] as List? ?? const [])
          .whereType<Map>()
          .where((item) => item['published'] == true)
          .map<Map<String, String>>(
            (item) => {
              'title': (item['title'] ?? 'Sem título').toString(),
              'created': (item['created'] ?? '').toString(),
              'state': 'published',
              'public_url': (item['public_url'] ?? '').toString(),
            },
          )
          .toList(),
      error: payload['online'] == true
          ? null
          : 'O portal não respondeu à última consulta. Tente novamente.',
    );
  }

  Map<String, String> _stringMap(Object? value) => value is Map
      ? value.map((key, value) => MapEntry(key.toString(), value.toString()))
      : const {};

  Future<PortalSnapshot> _loadDirectly() async {
    final home = await http.get(_endpoint(baseUrl, '/'));
    if (home.statusCode != 200) {
      throw http.ClientException('Portal consultation unavailable');
    }
    final root = await http.get(_endpoint(baseUrl, '/jsonapi'));
    if (root.statusCode != 200) {
      throw http.ClientException('Portal catalogue unavailable');
    }
    final rootJson = jsonDecode(utf8.decode(root.bodyBytes)) as Map;
    final links = rootJson['links'] as Map? ?? const {};
    final nodeTypes =
        links.keys
            .map((key) => key.toString())
            .where((key) => key.startsWith('node--'))
            .map((key) => key.substring('node--'.length))
            .toList()
          ..sort();
    final news = await http.get(
      _endpoint(baseUrl, '/jsonapi/node/noticia').replace(
        queryParameters: {
          'filter[status]': '1',
          'sort': '-created',
          'page[limit]': '5',
        },
      ),
    );
    if (news.statusCode != 200) {
      throw http.ClientException('Portal news unavailable');
    }
    final newsJson = jsonDecode(utf8.decode(news.bodyBytes)) as Map;
    final latest = (newsJson['data'] as List? ?? const [])
        .whereType<Map>()
        .map<Map<String, String>>((item) {
          final attrs = item['attributes'] as Map? ?? const {};
          final alias = (attrs['path'] as Map?)?['alias']?.toString();
          final nid = attrs['drupal_internal__nid'];
          final path =
              alias != null && alias.startsWith('/') && !alias.startsWith('//')
              ? alias
              : nid != null
              ? '/node/$nid'
              : '';
          return {
            'title': (attrs['title'] ?? 'Sem título').toString(),
            'created': (attrs['created'] ?? '').toString(),
            'state': 'published',
            'public_url': path.isEmpty
                ? ''
                : _endpoint(baseUrl, path).toString(),
          };
        })
        .toList();
    AppConfig.rememberPortalUrl(baseUrl);
    return PortalSnapshot(
      online: true,
      generator: home.headers['x-generator'] ?? 'Drupal',
      portalUrl: baseUrl,
      contentTypes: nodeTypes,
      latestNews: latest,
      error: null,
    );
  }
}

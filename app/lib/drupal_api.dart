import 'dart:convert';

import 'package:http/http.dart' as http;

class PortalSnapshot {
  const PortalSnapshot({
    required this.online,
    required this.generator,
    required this.contentTypes,
    required this.latestNews,
    required this.error,
  });

  final bool online;
  final String generator;
  final List<String> contentTypes;
  final List<Map<String, String>> latestNews;
  final String? error;
}

class DrupalApi {
  DrupalApi({
    this.baseUrl = 'https://neruds.org',
    this.bridgeUrl = const String.fromEnvironment(
      'NERUDS_BRIDGE_URL',
      defaultValue: 'https://largeo.tail2faed0.ts.net:8443',
    ),
  });

  final String baseUrl;
  final String bridgeUrl;

  Future<PortalSnapshot> loadSnapshot() async {
    try {
      if (bridgeUrl.trim().isNotEmpty) {
        return _loadFromBridge();
      }
      return _loadDirectly();
    } catch (error) {
      return PortalSnapshot(
        online: false,
        generator: 'indisponível',
        contentTypes: const [],
        latestNews: const [],
        error: error.toString(),
      );
    }
  }

  Future<PortalSnapshot> _loadFromBridge() async {
    final endpoint = bridgeUrl.endsWith('/')
        ? '${bridgeUrl}portal/snapshot'
        : '$bridgeUrl/portal/snapshot';
    final response =
        await http.get(Uri.parse(endpoint)).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw Exception('Bridge respondeu HTTP ${response.statusCode}');
    }

    final payload = jsonDecode(utf8.decode(response.bodyBytes));
    return PortalSnapshot(
      online: payload['online'] == true,
      generator: (payload['generator'] ?? 'Drupal').toString(),
      contentTypes: (payload['content_types'] as List<dynamic>? ?? const [])
          .map((item) => item.toString())
          .toList(),
      latestNews: (payload['latest_news'] as List<dynamic>? ?? const [])
          .map<Map<String, String>>((item) => {
                'title': (item['title'] ?? 'Sem título').toString(),
                'created': (item['created'] ?? '').toString(),
                'state': (item['state'] ?? '').toString(),
              })
          .toList(),
      error: null,
    );
  }

  Future<PortalSnapshot> _loadDirectly() async {
    final home = await http
        .get(Uri.parse('$baseUrl/'))
        .timeout(const Duration(seconds: 12));
    if (home.statusCode != 200) {
      throw Exception('Portal respondeu HTTP ${home.statusCode}');
    }

    final root = await http
        .get(Uri.parse('$baseUrl/jsonapi'))
        .timeout(const Duration(seconds: 12));
    if (root.statusCode != 200) {
      throw Exception('JSON:API respondeu HTTP ${root.statusCode}');
    }

    final rootJson = jsonDecode(utf8.decode(root.bodyBytes));
    final links = (rootJson['links'] as Map<String, dynamic>? ?? {});
    final nodeTypes = links.keys
        .where((key) => key.startsWith('node--'))
        .map((key) => key.substring('node--'.length))
        .where((key) => key != 'page')
        .toList()
      ..sort();

    final news = await http
        .get(Uri.parse(
            '$baseUrl/jsonapi/node/noticia?sort=-created&page%5Blimit%5D=5'))
        .timeout(const Duration(seconds: 12));
    final newsJson = news.statusCode == 200
        ? jsonDecode(utf8.decode(news.bodyBytes))
        : const <String, dynamic>{};
    final data = newsJson['data'] as List<dynamic>? ?? const [];
    final latest = data.map<Map<String, String>>((item) {
      final attrs = item['attributes'] as Map<String, dynamic>? ?? {};
      return {
        'title': (attrs['title'] ?? 'Sem título').toString(),
        'created': (attrs['created'] ?? '').toString(),
        'state': (attrs['moderation_state'] ?? '').toString(),
      };
    }).toList();

    return PortalSnapshot(
      online: true,
      generator: home.headers['x-generator'] ?? 'Drupal',
      contentTypes: nodeTypes,
      latestNews: latest,
      error: null,
    );
  }
}

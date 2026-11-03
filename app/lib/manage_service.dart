import 'dart:convert';

import 'app_config.dart';
import 'app_session.dart';
import 'bridge_http.dart' as bridge;
import 'manage_models.dart';

/// Cliente fino sobre o gateway /manage — toda a inteligência
/// (campos, permissões) vem dos schemas do bridge.
class ManageService {
  const ManageService._();

  static Future<List<ManageBundle>> schemas() async {
    final response = await bridge.get(
      AppConfig.endpoint('/manage/schemas'),
      headers: AppSession.instance.authHeaders,
    );
    if (response.statusCode != 200) {
      throw Exception('schemas ${response.statusCode}');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    final canCreate =
        Map<String, dynamic>.from(data['can_create'] as Map? ?? {});
    final schemas = Map<String, dynamic>.from(data['schemas'] as Map? ?? {});
    return schemas.entries
        .map((e) => ManageBundle.fromJson(
              e.key,
              Map<String, dynamic>.from(e.value as Map),
              canCreate: canCreate[e.key] == true,
            ))
        .toList();
  }

  static Future<List<ManageItem>> list(
    String bundle, {
    String? status,
    String? search,
    int limit = 30,
    int offset = 0,
  }) async {
    final query = <String, String>{
      'limit': '$limit',
      'offset': '$offset',
      'status': ?status,
      if (search != null && search.isNotEmpty) 'search': search,
    };
    final response = await bridge.get(
      AppConfig.endpoint('/manage/$bundle').replace(queryParameters: query),
      headers: AppSession.instance.authHeaders,
    );
    if (response.statusCode != 200) {
      throw Exception('list ${response.statusCode}: ${response.body}');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    return ((data['items'] as List?) ?? const [])
        .map((it) => ManageItem.fromJson(Map<String, dynamic>.from(it as Map)))
        .toList();
  }

  static Future<List<ManageOption>> options(String target,
      {String? search}) async {
    final parts = target.split(':');
    final query = <String, String>{
      if (search != null && search.isNotEmpty) 'search': search,
    };
    final response = await bridge.get(
      AppConfig.endpoint('/manage/options/${parts[0]}/${parts[1]}')
          .replace(queryParameters: query),
      headers: AppSession.instance.authHeaders,
    );
    if (response.statusCode != 200) return const [];
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    return ((data['options'] as List?) ?? const [])
        .map((it) => ManageOption.fromJson(Map<String, dynamic>.from(it as Map)))
        .toList();
  }

  static Future<Map<String, dynamic>> detail(String bundle, int nid) async {
    final response = await bridge.get(
      AppConfig.endpoint('/manage/$bundle/$nid'),
      headers: AppSession.instance.authHeaders,
    );
    if (response.statusCode != 200) {
      throw Exception('detail ${response.statusCode}');
    }
    return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map);
  }

  static Future<Map<String, dynamic>> save(
    String bundle, {
    int? nid,
    required Map<String, dynamic> values,
    required bool published,
  }) async {
    final body = jsonEncode({'values': values, 'published': published});
    final response = nid == null
        ? await bridge.post(
            AppConfig.endpoint('/manage/$bundle'),
            headers: AppSession.instance.authHeaders,
            body: body,
          )
        : await bridge.patch(
            AppConfig.endpoint('/manage/$bundle/$nid'),
            headers: AppSession.instance.authHeaders,
            body: body,
          );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception(
          'save ${response.statusCode}: ${utf8.decode(response.bodyBytes)}');
    }
    return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map);
  }

  static Future<void> unpublish(String bundle, int nid) async {
    final response = await bridge.delete(
      AppConfig.endpoint('/manage/$bundle/$nid'),
      headers: AppSession.instance.authHeaders,
    );
    if (response.statusCode != 200) {
      throw Exception('unpublish ${response.statusCode}');
    }
  }

  static Future<String> upload(
    String bundle,
    String field, {
    required String filename,
    required List<int> bytes,
  }) async {
    final response = await bridge.post(
      AppConfig.endpoint('/manage/$bundle/files/$field?filename=$filename'),
      headers: {
        ...AppSession.instance.authHeaders,
        'Content-Type': 'application/octet-stream',
      },
      body: bytes,
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('upload ${response.statusCode}');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    return data['id']?.toString() ?? '';
  }
}

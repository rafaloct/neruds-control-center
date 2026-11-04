import 'dart:convert';

import 'app_config.dart';
import 'app_session.dart';
import 'bridge_http.dart' as bridge;
import 'manage_models.dart';

/// Cliente fino sobre o gateway /manage — toda a inteligência
/// (campos, permissões) vem dos schemas do bridge.
class ManageService {
  const ManageService._();

  // Cada GET /manage/schemas dispara ~9 probes de permissão ao Drupal
  // (~1s+). Detalhe/edição/picker abrem várias vezes em sequência —
  // cache curto evita re-probes sem sacrificar atualidade.
  static List<ManageBundle>? _schemasCache;
  static DateTime? _schemasAt;
  static const _schemasTtl = Duration(minutes: 2);

  static void resetSchemasCache() {
    _schemasCache = null;
    _schemasAt = null;
  }

  static Future<List<ManageBundle>> schemas() async {
    final cached = _schemasCache;
    final at = _schemasAt;
    if (cached != null &&
        at != null &&
        DateTime.now().difference(at) < _schemasTtl) {
      return cached;
    }
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
    final result = schemas.entries
        .map((e) => ManageBundle.fromJson(
              e.key,
              Map<String, dynamic>.from(e.value as Map),
              canCreate: canCreate[e.key] == true,
            ))
        .toList();
    _schemasCache = result;
    _schemasAt = DateTime.now();
    return result;
  }

  static Future<List<ManageItem>> list(
    String bundle, {
    String? status,
    String? search,
    String? rel,
    String? relId,
    int limit = 30,
    int offset = 0,
  }) async {
    final query = <String, String>{
      'limit': '$limit',
      'offset': '$offset',
      'status': ?status,
      'rel': ?rel,
      'rel_id': ?relId,
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

  // --- Taxonomia ------------------------------------------------------------

  static Future<List<Map<String, String>>> vocabularies() async {
    final response = await bridge.get(
      AppConfig.endpoint('/manage/taxonomy'),
      headers: AppSession.instance.authHeaders,
    );
    if (response.statusCode != 200) {
      throw Exception('vocabularies ${response.statusCode}');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    return ((data['vocabularies'] as List?) ?? const [])
        .map((v) => {
              'vid': v['vid']?.toString() ?? '',
              'label': v['label']?.toString() ?? '',
            })
        .toList();
  }

  static Future<List<ManageItem>> terms(String vocab,
      {String? search}) async {
    final query = <String, String>{
      'limit': '100',
      'search': ?search,
    };
    final response = await bridge.get(
      AppConfig.endpoint('/manage/taxonomy/$vocab')
          .replace(queryParameters: query),
      headers: AppSession.instance.authHeaders,
    );
    if (response.statusCode != 200) {
      throw Exception('terms ${response.statusCode}');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    return ((data['items'] as List?) ?? const [])
        .map((it) => ManageItem.fromJson(Map<String, dynamic>.from(it as Map)))
        .toList();
  }

  static Future<void> saveTerm(
    String vocab, {
    int? tid,
    required Map<String, dynamic> values,
  }) async {
    final body = jsonEncode({'values': values});
    final response = tid == null
        ? await bridge.post(
            AppConfig.endpoint('/manage/taxonomy/$vocab'),
            headers: AppSession.instance.authHeaders,
            body: body,
          )
        : await bridge.patch(
            AppConfig.endpoint('/manage/taxonomy/$vocab/$tid'),
            headers: AppSession.instance.authHeaders,
            body: body,
          );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('term ${response.statusCode}: ${response.body}');
    }
  }

  static Future<void> deleteTerm(String vocab, int tid) async {
    final response = await bridge.delete(
      AppConfig.endpoint('/manage/taxonomy/$vocab/$tid'),
      headers: AppSession.instance.authHeaders,
    );
    if (response.statusCode != 200) {
      throw Exception('delete term ${response.statusCode}');
    }
  }

  // --- Moderação --------------------------------------------------------------

  static Future<List<Map<String, dynamic>>> moderationPending() async {
    final response = await bridge.get(
      AppConfig.endpoint('/manage/moderation/pending'),
      headers: AppSession.instance.authHeaders,
    );
    if (response.statusCode != 200) {
      throw Exception('pending ${response.statusCode}');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    return ((data['items'] as List?) ?? const [])
        .map((it) => Map<String, dynamic>.from(it as Map))
        .toList();
  }

  static Future<void> approve(String bundle, int nid) async {
    final response = await bridge.post(
      AppConfig.endpoint('/manage/moderation/$bundle/$nid/approve'),
      headers: AppSession.instance.authHeaders,
    );
    if (response.statusCode != 200) {
      throw Exception('approve ${response.statusCode}: ${response.body}');
    }
  }

  // --- Usuários ----------------------------------------------------------------

  static Future<List<Map<String, dynamic>>> users({String? search}) async {
    final query = <String, String>{'limit': '100', 'search': ?search};
    final response = await bridge.get(
      AppConfig.endpoint('/manage/users').replace(queryParameters: query),
      headers: AppSession.instance.authHeaders,
    );
    if (response.statusCode != 200) {
      throw Exception('users ${response.statusCode}');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    return ((data['items'] as List?) ?? const [])
        .map((it) => Map<String, dynamic>.from(it as Map))
        .toList();
  }

  static Future<List<Map<String, String>>> userRoles() async {
    final response = await bridge.get(
      AppConfig.endpoint('/manage/users/roles'),
      headers: AppSession.instance.authHeaders,
    );
    if (response.statusCode != 200) return const [];
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    return ((data['roles'] as List?) ?? const [])
        .map((r) => {
              'id': r['id']?.toString() ?? '',
              'label': r['label']?.toString() ?? '',
            })
        .toList();
  }

  static Future<void> updateUser(int uid, Map<String, dynamic> patch) async {
    final response = await bridge.patch(
      AppConfig.endpoint('/manage/users/$uid'),
      headers: AppSession.instance.authHeaders,
      body: jsonEncode(patch),
    );
    if (response.statusCode != 200) {
      throw Exception('user ${response.statusCode}: ${response.body}');
    }
  }

  // --- Mídia -------------------------------------------------------------------

  static Future<List<Map<String, dynamic>>> media(
    String type, {
    String? search,
  }) async {
    final query = <String, String>{'limit': '60', 'search': ?search};
    final response = await bridge.get(
      AppConfig.endpoint('/manage/media/$type')
          .replace(queryParameters: query),
      headers: AppSession.instance.authHeaders,
    );
    if (response.statusCode != 200) {
      throw Exception('media ${response.statusCode}');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    return ((data['items'] as List?) ?? const [])
        .map((it) => Map<String, dynamic>.from(it as Map))
        .toList();
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

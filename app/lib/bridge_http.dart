import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as upstream;

import 'app_session.dart';

export 'package:http/http.dart'
    show
        BaseRequest,
        ByteStream,
        Client,
        ClientException,
        MultipartFile,
        MultipartRequest,
        Request,
        Response,
        StreamedResponse;

upstream.Client _client = upstream.Client();
const requestTimeout = Duration(seconds: 25);

void _checkSession(int statusCode, Map<String, String>? headers) {
  if (statusCode != 401 || headers == null) return;
  String? authorization;
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'authorization') {
      authorization = entry.value;
    }
  }
  final session = AppSession.instance;
  // A delayed response for an older token must not expire a newer session.
  if (session.authenticated && authorization == 'Bearer ${session.token}') {
    session.expire();
  }
}

Future<upstream.Response> _response(
  Future<upstream.Response> request,
  Map<String, String>? headers, [
  Duration? timeout,
]) async {
  final response = await request.timeout(timeout ?? requestTimeout);
  _checkSession(response.statusCode, headers);
  return response;
}

Future<upstream.Response> get(Uri url, {Map<String, String>? headers}) =>
    _response(_client.get(url, headers: headers), headers);

Future<upstream.Response> post(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
  Duration? timeout,
}) => _response(
  _client.post(url, headers: headers, body: body, encoding: encoding),
  headers,
  timeout,
);

Future<upstream.Response> patch(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
}) => _response(
  _client.patch(url, headers: headers, body: body, encoding: encoding),
  headers,
);

Future<upstream.Response> delete(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
}) => _response(
  _client.delete(url, headers: headers, body: body, encoding: encoding),
  headers,
);

Future<upstream.StreamedResponse> send(upstream.BaseRequest request) async {
  final response = await _client.send(request).timeout(requestTimeout);
  _checkSession(response.statusCode, request.headers);
  return upstream.StreamedResponse(
    response.stream.timeout(requestTimeout),
    response.statusCode,
    contentLength: response.contentLength,
    request: response.request,
    headers: response.headers,
    isRedirect: response.isRedirect,
    persistentConnection: response.persistentConnection,
    reasonPhrase: response.reasonPhrase,
  );
}

@visibleForTesting
void setClientForTesting(upstream.Client client) {
  _client.close();
  _client = client;
}

@visibleForTesting
void resetClientForTesting() {
  _client.close();
  _client = upstream.Client();
}

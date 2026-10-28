import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiException implements Exception {
  final String code;
  ApiException(this.code);
  @override
  String toString() => code;
}

/// Talks to our server (Mosque IDs, PIN check, tokens, status, schedule, questions, recordings).
class Api {
  static String baseUrl = '';

  static String get base => baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

  /// Full URL for a server path such as /recordings/JMFM/x.m4a
  static String abs(String path) => path.startsWith('http') ? path : base + path;

  static Uri _uri(String path) => Uri.parse(base + path);

  static Future<Map<String, dynamic>> _send(Future<http.Response> Function() request) async {
    http.Response r;
    try {
      r = await request().timeout(const Duration(seconds: 15));
    } catch (_) {
      throw ApiException('network');
    }
    Map<String, dynamic> body = {};
    try {
      final d = jsonDecode(utf8.decode(r.bodyBytes));
      if (d is Map<String, dynamic>) body = d;
    } catch (_) {}
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ApiException((body['code'] ?? 'error').toString());
    }
    return body;
  }

  static Future<Map<String, dynamic>> get(String path) => _send(() => http.get(_uri(path)));

  static Future<Map<String, dynamic>> post(String path, Map<String, dynamic> data) => _send(() => http.post(
        _uri(path),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(data),
      ));

  static Future<Map<String, dynamic>> mosque(String id) => get('/api/mosques/${Uri.encodeComponent(id)}');
}

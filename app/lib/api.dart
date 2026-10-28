import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiException implements Exception {
  final String code;
  ApiException(this.code);
  @override
  String toString() => code;
}

/// Talks to our server (Mosque IDs, PIN check, tokens, LIVE status).
class Api {
  static String baseUrl = '';

  static Uri _uri(String path) => Uri.parse(baseUrl.trim().replaceAll(RegExp(r'/+$'), '') + path);

  static Future<Map<String, dynamic>> _send(Future<http.Response> Function() request) async {
    http.Response r;
    try {
      r = await request().timeout(const Duration(seconds: 15));
    } catch (_) {
      throw ApiException('network');
    }
    Map<String, dynamic> body = {};
    try {
      final d = jsonDecode(r.body);
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

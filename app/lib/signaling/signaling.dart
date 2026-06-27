import 'dart:convert';
import 'package:http/http.dart' as http;

class SignalingClient {
  final String baseUrl;
  final http.Client _http;

  SignalingClient({required this.baseUrl}) : _http = http.Client();

  Future<Map<String, dynamic>> authenticate() async {
    final response = await _http.post(Uri.parse('$baseUrl/auth'));
    if (response.statusCode != 200) {
      throw SignalingException('Auth failed: ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> createRoom({
    required String token,
    String? name,
  }) async {
    final response = await _http.post(
      Uri.parse('$baseUrl/rooms'),
      headers: _authHeader(token),
      body: jsonEncode({'name': name ?? 'ridevoice-room'}),
    );
    if (response.statusCode != 201) {
      throw SignalingException('Create room failed: ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getJoinToken({
    required String token,
    required String roomId,
    required String userId,
  }) async {
    final response = await _http.post(
      Uri.parse('$baseUrl/rooms/$roomId/join-token'),
      headers: _authHeader(token),
      body: jsonEncode({'user_id': userId}),
    );
    if (response.statusCode != 200) {
      throw SignalingException('Join token failed: ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Map<String, String> _authHeader(String token) {
    return {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};
  }

  void dispose() {
    _http.close();
  }
}

class SignalingException implements Exception {
  final String message;
  SignalingException(this.message);
  @override
  String toString() => 'SignalingException: $message';
}

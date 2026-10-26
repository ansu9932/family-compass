import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';

/// Exchanges only authenticated, encrypted signaling. The pairing secret and
/// media encryption keys are never sent to the relay.
class InternetSignalClient {
  InternetSignalClient({
    required String baseUrl,
    required this.sharedSecret,
    required this.role,
  }) : base = Uri.parse(baseUrl) {
    if (base.scheme != 'https' ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment) {
      throw const FormatException('A secure HTTPS relay address is required.');
    }
    if (!['parent', 'child'].contains(role) || sharedSecret.length < 32) {
      throw const FormatException('A valid paired device is required.');
    }
  }
  final Uri base;
  final String sharedSecret;
  final String role;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  final _cipher = AesGcm.with256bits();
  Future<List<int>> _derive(String label) async =>
      (await Hmac.sha256().calculateMac(
        utf8.encode(label),
        secretKey: SecretKey(utf8.encode(sharedSecret)),
      )).bytes;
  String _hex(List<int> bytes) =>
      bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  Future<String> get token async =>
      _hex(await _derive('familycompass-relay-auth-v1'));
  Future<String> get room async => _hex(
    (await Sha256().hash(
      utf8.encode('familycompass-room-v1:${await token}'),
    )).bytes,
  );
  Future<Map<String, dynamic>> seal(
    Map<String, dynamic> message,
    String sender,
  ) async {
    final bytes = utf8.encode(jsonEncode(message));
    if (bytes.length > 32768) {
      throw const FormatException('Signaling message is too large.');
    }
    final box = await _cipher.encrypt(
      bytes,
      secretKey: SecretKey(await _derive('familycompass-media-signal-key-v1')),
      aad: utf8.encode('${await room}:$sender'),
    );
    return {
      'v': 1,
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    };
  }

  Future<Map<String, dynamic>> open(
    Map<String, dynamic> envelope,
    String sender,
  ) async {
    if (envelope['v'] != 1) {
      throw const FormatException('Unsupported signaling version.');
    }
    final box = SecretBox(
      base64Decode(envelope['ciphertext'] as String),
      nonce: base64Decode(envelope['nonce'] as String),
      mac: Mac(base64Decode(envelope['mac'] as String)),
    );
    if (box.nonce.length != 12 ||
        box.mac.bytes.length != 16 ||
        box.cipherText.length > 32768) {
      throw const FormatException('Invalid signaling envelope.');
    }
    final clear = await _cipher.decrypt(
      box,
      secretKey: SecretKey(await _derive('familycompass-media-signal-key-v1')),
      aad: utf8.encode('${await room}:$sender'),
    );
    return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
  }

  Future<void> send(Map<String, dynamic> message) async {
    await _request('PUT', role, await seal(message, role));
  }

  Future<void> sendDeviceStatus(Map<String, dynamic> status) async {
    await _requestPath(
      'PUT',
      '/v1/rooms/${await room}/status',
      await seal(status, 'status'),
    );
  }

  Future<Map<String, dynamic>?> receiveDeviceStatus() async {
    final envelope = await _requestPath(
      'GET',
      '/v1/rooms/${await room}/status',
      null,
    );
    return envelope == null ? null : open(envelope, 'status');
  }

  Future<Map<String, dynamic>?> receive() async {
    final other = role == 'parent' ? 'child' : 'parent';
    final envelope = await _request('GET', other, null);
    return envelope == null ? null : open(envelope, other);
  }

  Future<List<dynamic>> iceServers() async {
    final result = await _requestPath(
      'GET',
      '/v1/rooms/${await room}/ice-servers',
      null,
    );
    final servers = result?['iceServers'];
    if (servers is! List || servers.isEmpty) {
      throw const FormatException('The relay returned no ICE servers.');
    }
    return servers;
  }

  Future<Map<String, dynamic>?> _request(
    String method,
    String mailbox,
    Map<String, dynamic>? body,
  ) async => _requestPath(method, '/v1/rooms/${await room}/$mailbox', body);

  Future<Map<String, dynamic>?> _requestPath(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    final url = base.resolve(path);
    final request = await _http
        .openUrl(method, url)
        .timeout(const Duration(seconds: 12));
    request.followRedirects = false;
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${await token}',
    );
    const deploymentKey = String.fromEnvironment('FC_RELAY_KEY');
    if (deploymentKey.isNotEmpty) {
      request.headers.set('X-Family-Compass-Client', deploymentKey);
    }
    if (body != null) {
      final payload = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType.json;
      request.contentLength = payload.length;
      request.add(payload);
    }
    final response = await request.close().timeout(const Duration(seconds: 12));
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 12))) {
      if (bytes.length + chunk.length > 50000) {
        throw const FormatException('Relay response is too large.');
      }
      bytes.addAll(chunk);
    }
    if (response.statusCode == 204) return null;
    if (response.statusCode != 200) {
      throw HttpException(
        'Relay request failed (${response.statusCode}). Try again.',
      );
    }
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  void close() => _http.close(force: true);
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

const int localPairingPort = 39751;

String secureToken(int length) {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final random = Random.secure();
  return List.generate(
    length,
    (_) => alphabet[random.nextInt(alphabet.length)],
  ).join();
}

String newPairingCode() =>
    (Random.secure().nextInt(900000) + 100000).toString();

bool isPrivateIpv4(String value) {
  final address = InternetAddress.tryParse(value);
  if (address == null || address.type != InternetAddressType.IPv4) return false;
  final octets = address.rawAddress;
  return octets[0] == 10 ||
      (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
      (octets[0] == 192 && octets[1] == 168);
}

class PendingPairRequest {
  PendingPairRequest({
    required this.requestId,
    required this.deviceId,
    required this.deviceName,
    required this.remoteAddress,
  }) : decision = Completer<bool>();

  final String requestId;
  final String deviceId;
  final String deviceName;
  final String remoteAddress;
  final Completer<bool> decision;
}

class PairingServer extends ChangeNotifier {
  PairingServer({
    required this.familyId,
    required this.pairingCode,
    required this.existingSecret,
    required this.onPaired,
    required this.onLocation,
  }) : _secret = existingSecret;

  final String familyId;
  String pairingCode;
  final String? existingSecret;
  final Future<void> Function(String deviceId, String deviceName, String secret)
  onPaired;
  final Future<void> Function(Map<String, dynamic> location) onLocation;

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  Timer? _codeExpiry;
  String? _secret;
  List<String> addresses = const [];
  String? error;
  PendingPairRequest? pending;

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        localPairingPort,
      );
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      addresses =
          interfaces
              .expand((interface) => interface.addresses)
              .map((address) => address.address)
              .where(isPrivateIpv4)
              .toSet()
              .toList()
            ..sort();
      _subscription = _server!.listen(
        _handle,
        onError: (Object value, StackTrace stack) {
          error = value.toString();
          notifyListeners();
        },
      );
      _codeExpiry = Timer(const Duration(minutes: 2), () {
        pairingCode = '';
        notifyListeners();
      });
      error = null;
    } catch (value) {
      error = value.toString();
      await _server?.close(force: true);
      _server = null;
      addresses = const [];
    }
    notifyListeners();
  }

  Future<void> stop() async {
    _codeExpiry?.cancel();
    _codeExpiry = null;
    final request = pending;
    if (request != null && !request.decision.isCompleted) {
      request.decision.complete(false);
    }
    pending = null;
    await _subscription?.cancel();
    _subscription = null;
    await _server?.close(force: true);
    _server = null;
    addresses = const [];
    notifyListeners();
  }

  void approvePending() {
    final request = pending;
    if (request != null && !request.decision.isCompleted) {
      request.decision.complete(true);
    }
  }

  void denyPending() {
    final request = pending;
    if (request != null && !request.decision.isCompleted) {
      request.decision.complete(false);
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method == 'GET' && request.uri.path == '/health') {
        await _respond(request.response, HttpStatus.ok, {'ready': true});
        return;
      }
      if (request.method != 'POST') {
        await _respond(request.response, HttpStatus.methodNotAllowed, {
          'error': 'POST required',
        });
        return;
      }
      if (request.contentLength > 8192) {
        await _respond(request.response, HttpStatus.requestEntityTooLarge, {
          'error': 'Request is too large',
        });
        return;
      }
      final body = await _readJson(request);
      if (request.uri.path == '/pair') {
        await _handlePair(request, body);
      } else if (request.uri.path == '/location') {
        await _handleLocation(request, body);
      } else {
        await _respond(request.response, HttpStatus.notFound, {
          'error': 'Unknown local endpoint',
        });
      }
    } on FormatException catch (error) {
      try {
        await _respond(request.response, HttpStatus.badRequest, {
          'error': error.message,
        });
      } on Object {
        // A malformed request may come from a peer that already disconnected.
      }
    } on Object {
      try {
        await _respond(request.response, HttpStatus.internalServerError, {
          'error': 'Local request failed',
        });
      } on Object {
        // The peer may have closed the connection before the error response.
      }
    }
  }

  Future<void> _handlePair(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final remoteAddress = request.connectionInfo?.remoteAddress.address;
    if (remoteAddress == null || !isPrivateIpv4(remoteAddress)) {
      await _respond(request.response, HttpStatus.forbidden, {
        'error': 'Pairing is available only to private Wi-Fi devices',
      });
      return;
    }
    if (pairingCode.isEmpty || body['code'] != pairingCode) {
      await _respond(request.response, HttpStatus.forbidden, {
        'error': 'Pairing code is incorrect or has expired',
      });
      return;
    }
    final deviceId = body['deviceId'];
    final deviceName = body['deviceName'];
    if (deviceId is! String ||
        deviceId.length > 80 ||
        deviceName is! String ||
        deviceName.trim().isEmpty ||
        deviceName.length > 80) {
      await _respond(request.response, HttpStatus.badRequest, {
        'error': 'A device ID and name are required',
      });
      return;
    }
    if (pending != null && !pending!.decision.isCompleted) {
      await _respond(request.response, HttpStatus.conflict, {
        'error': 'Another device request is waiting for approval',
      });
      return;
    }

    final pendingRequest = PendingPairRequest(
      requestId: secureToken(12),
      deviceId: deviceId,
      deviceName: deviceName.trim(),
      remoteAddress:
          request.connectionInfo?.remoteAddress.address ?? 'local network',
    );
    pending = pendingRequest;
    notifyListeners();

    final approved = await pendingRequest.decision.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () => false,
    );
    if (identical(pending, pendingRequest)) {
      pending = null;
      notifyListeners();
    }
    if (!approved) {
      await _respond(request.response, HttpStatus.forbidden, {
        'error': 'Pairing was declined or timed out',
      });
      return;
    }

    final secret = secureToken(48);
    _secret = secret;
    _codeExpiry?.cancel();
    _codeExpiry = null;
    pairingCode = '';
    await onPaired(deviceId, deviceName.trim(), secret);
    await _respond(request.response, HttpStatus.ok, {
      'familyId': familyId,
      'deviceId': deviceId,
      'sharedSecret': secret,
      'port': localPairingPort,
    });
  }

  Future<void> _handleLocation(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final remoteAddress = request.connectionInfo?.remoteAddress.address;
    if (remoteAddress == null || !isPrivateIpv4(remoteAddress)) {
      await _respond(request.response, HttpStatus.forbidden, {
        'error': 'Location sharing is available only on private Wi-Fi',
      });
      return;
    }
    final supplied = request.headers.value(HttpHeaders.authorizationHeader);
    if (_secret == null || supplied != 'Bearer $_secret') {
      await _respond(request.response, HttpStatus.unauthorized, {
        'error': 'This device is not paired',
      });
      return;
    }
    final latitude = body['latitude'];
    final longitude = body['longitude'];
    final accuracy = body['accuracy'];
    if (latitude is! num ||
        longitude is! num ||
        accuracy is! num ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180 ||
        accuracy < 0 ||
        accuracy > 100000) {
      await _respond(request.response, HttpStatus.badRequest, {
        'error': 'Location coordinates are invalid',
      });
      return;
    }
    final location = <String, dynamic>{
      'latitude': latitude.toDouble(),
      'longitude': longitude.toDouble(),
      'accuracy': accuracy.toDouble(),
      'sharedAt': DateTime.now().toIso8601String(),
      'deviceId': body['deviceId'] is String ? body['deviceId'] : '',
    };
    await onLocation(location);
    await _respond(request.response, HttpStatus.ok, {'received': true});
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      if (bytes.length + chunk.length > 8192) {
        throw const FormatException('Request is too large');
      }
      bytes.addAll(chunk);
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) throw const FormatException('JSON object required');
    return Map<String, dynamic>.from(decoded);
  }

  Future<void> _respond(
    HttpResponse response,
    int status,
    Map<String, dynamic> data,
  ) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.write(jsonEncode(data));
    await response.close();
  }
}

class PairedSession {
  const PairedSession({
    required this.familyId,
    required this.deviceId,
    required this.sharedSecret,
  });

  final String familyId;
  final String deviceId;
  final String sharedSecret;
}

class PairingClient {
  static Future<PairedSession> pair({
    required String host,
    required String code,
    required String deviceId,
    required String deviceName,
  }) async {
    if (!isPrivateIpv4(host)) {
      throw const FormatException(
        'Enter the parent phone’s private Wi-Fi address (for example, 192.168.1.20).',
      );
    }
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      throw const FormatException('Enter the six-digit pairing code.');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client
          .postUrl(
            Uri(
              scheme: 'http',
              host: host,
              port: localPairingPort,
              path: '/pair',
            ),
          )
          .timeout(const Duration(seconds: 7));
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'code': code,
          'deviceId': deviceId,
          'deviceName': deviceName,
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 70),
      );
      final responseText = await utf8.decoder.bind(response).join();
      final data = jsonDecode(responseText);
      if (response.statusCode != HttpStatus.ok || data is! Map) {
        final message = data is Map && data['error'] is String
            ? data['error'] as String
            : 'The parent phone did not approve pairing.';
        throw FormatException(message);
      }
      return PairedSession(
        familyId: data['familyId'] as String,
        deviceId: data['deviceId'] as String,
        sharedSecret: data['sharedSecret'] as String,
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> shareLocation({
    required String host,
    required String secret,
    required String deviceId,
    required double latitude,
    required double longitude,
    required double accuracy,
  }) async {
    if (!isPrivateIpv4(host)) {
      throw const FormatException(
        'The saved parent address is not a private Wi-Fi address.',
      );
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client
          .postUrl(
            Uri(
              scheme: 'http',
              host: host,
              port: localPairingPort,
              path: '/location',
            ),
          )
          .timeout(const Duration(seconds: 7));
      request.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.authorizationHeader, 'Bearer $secret');
      request.write(
        jsonEncode({
          'deviceId': deviceId,
          'latitude': latitude,
          'longitude': longitude,
          'accuracy': accuracy,
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final text = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.ok) {
        final data = jsonDecode(text);
        final message = data is Map && data['error'] is String
            ? data['error'] as String
            : 'The parent phone could not receive this location.';
        throw FormatException(message);
      }
    } finally {
      client.close(force: true);
    }
  }
}

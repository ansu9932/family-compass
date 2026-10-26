import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'device_store.dart';
import 'internet_signal.dart';
import 'local_pairing.dart' show secureToken;

String invitationSecret(String code) => 'FamilyCompass-invite-v2:$code';

class AddDevicePage extends StatefulWidget {
  const AddDevicePage({
    super.key,
    required this.relayUrl,
    required this.familyId,
    required this.saveDevice,
  });
  final String relayUrl, familyId;
  final Future<void> Function(FamilyDevice) saveDevice;
  @override
  State<AddDevicePage> createState() => _AddDevicePageState();
}

class _AddDevicePageState extends State<AddDevicePage> {
  final code = secureToken(20);
  late final expires = DateTime.now().add(const Duration(minutes: 10));
  late final signal = InternetSignalClient(
    baseUrl: widget.relayUrl,
    sharedSecret: invitationSecret(code),
    role: 'parent',
  );
  Timer? timer;
  bool busy = false, ended = false;
  String? error;
  int remaining = 600;
  final seen = <String>{};
  Map<String, dynamic>? delivery;
  FamilyDevice? deliveryDevice;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) => poll());
  }

  Future<void> poll() async {
    if (!mounted || ended) return;
    setState(
      () => remaining = expires
          .difference(DateTime.now())
          .inSeconds
          .clamp(0, 600),
    );
    if (remaining == 0 || busy) return;
    busy = true;
    try {
      if (delivery != null) {
        await deliver();
        return;
      }
      final m = await signal.receive();
      if (!mounted ||
          m == null ||
          m['kind'] != 'join' ||
          m['deviceId'] is! String ||
          m['name'] is! String ||
          m['requestId'] is! String)
        return;
      final time = DateTime.tryParse(m['sentAt'] as String? ?? '');
      if (time == null ||
          DateTime.now().difference(time).abs() > const Duration(minutes: 2) ||
          !seen.add(m['requestId'] as String))
        return;
      final name = (m['name'] as String).trim();
      if (name.isEmpty ||
          name.length > 60 ||
          (m['deviceId'] as String).length > 100)
        return;
      final allow = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (c) => AlertDialog(
          title: Text('Add $name?'),
          content: const Text(
            'Confirm this is the Android phone you are setting up. It will appear in your device list.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Decline'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Add device'),
            ),
          ],
        ),
      );
      if (!mounted || DateTime.now().isAfter(expires)) return;
      if (allow != true) {
        await signal.send({'kind': 'denied', 'requestId': m['requestId']});
        return;
      }
      final device = FamilyDevice(
        m['deviceId'] as String,
        name,
        secureToken(48),
      );
      // Persist before delivering the secret; a failed network write cannot lose the parent's key.
      await widget.saveDevice(device);
      deliveryDevice = device;
      delivery = {
        'kind': 'paired',
        'requestId': m['requestId'],
        'secret': device.secret,
        'familyId': widget.familyId,
        'expires': expires.toUtc().toIso8601String(),
      };
      await deliver();
    } catch (_) {
      if (mounted)
        setState(
          () => error =
              'Could not reach pairing service. Check internet; retrying…',
        );
    } finally {
      busy = false;
    }
  }

  Future<void> deliver() async {
    await signal.send(delivery!);
    ended = true;
    timer?.cancel();
    if (mounted) Navigator.pop(context, deliveryDevice);
  }

  @override
  void dispose() {
    timer?.cancel();
    signal.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pretty = List.generate(
      5,
      (i) => code.substring(i * 4, i * 4 + 4),
    ).join('-');
    return Scaffold(
      appBar: AppBar(title: const Text('Add child device')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Icon(
            Icons.phonelink_setup_rounded,
            size: 64,
            color: Color(0xFF2563EB),
          ),
          const SizedBox(height: 24),
          const Text(
            'Connect in three steps',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 20),
          const ListTile(
            leading: CircleAvatar(child: Text('1')),
            title: Text('Install Family Compass Child'),
            subtitle: Text(
              'Use the child APK on the Android phone. No account needed.',
            ),
          ),
          const ListTile(
            leading: CircleAvatar(child: Text('2')),
            title: Text('Enter this binding code'),
            subtitle: Text(
              'Open the child app and enter the code below. Both phones need internet.',
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  SelectableText(
                    pretty,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    remaining > 0
                        ? 'Expires in ${remaining ~/ 60}:${(remaining % 60).toString().padLeft(2, '0')}'
                        : 'Code expired. Go back and add again.',
                  ),
                  TextButton.icon(
                    onPressed: remaining == 0
                        ? null
                        : () async {
                            await Clipboard.setData(
                              ClipboardData(text: pretty),
                            );
                          },
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy code'),
                  ),
                ],
              ),
            ),
          ),
          const ListTile(
            leading: CircleAvatar(child: Text('3')),
            title: Text('Approve and finish setup'),
            subtitle: Text(
              'Confirm the phone here, then finish camera and microphone permissions on Android.',
            ),
          ),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 20),
          const Text(
            'Keep this page open. Share this private code only with the phone you want to pair.',
          ),
        ],
      ),
    );
  }
}

Future<Map<String, dynamic>> joinOverInternet({
  required String relayUrl,
  required String code,
  required String name,
  required String id,
}) async {
  final clean = code.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
  if (!RegExp(r'^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{20}$').hasMatch(clean))
    throw const FormatException(
      'Enter all 20 characters from the parent’s binding code.',
    );
  final signal = InternetSignalClient(
    baseUrl: relayUrl,
    sharedSecret: invitationSecret(clean),
    role: 'child',
  );
  final request = secureToken(24);
  try {
    await signal.send({
      'kind': 'join',
      'deviceId': id,
      'name': name,
      'requestId': request,
      'sentAt': DateTime.now().toUtc().toIso8601String(),
    });
    final deadline = DateTime.now().add(const Duration(seconds: 100));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final reply = await signal.receive();
      if (reply == null || reply['requestId'] != request) continue;
      if (reply['kind'] == 'denied')
        throw const FormatException(
          'Parent declined. Start again with a new code.',
        );
      if (reply['kind'] == 'paired' &&
          reply['secret'] is String &&
          (reply['secret'] as String).length >= 32 &&
          reply['familyId'] is String) {
        final expires = DateTime.tryParse(reply['expires'] as String? ?? '');
        if (expires == null || DateTime.now().isAfter(expires))
          throw const FormatException(
            'Code expired. Generate a new code on the parent phone.',
          );
        return reply;
      }
    }
    throw const FormatException(
      'No approval received. Keep Add child device open on the iPhone and check the code.',
    );
  } finally {
    signal.close();
  }
}

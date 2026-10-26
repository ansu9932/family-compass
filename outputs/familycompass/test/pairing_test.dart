import 'package:flutter_test/flutter_test.dart';
import 'package:familycompass/local_pairing.dart';

PairingServer server() => PairingServer(
  familyId: 'test',
  pairingCode: '123456',
  existingSecret: null,
  onPaired: (_, _, _) async {},
  onLocation: (_) async {},
);

void main() {
  test('stopping after an approval does not complete decision twice', () async {
    final s = server();
    s.pending = PendingPairRequest(
      requestId: 'test',
      deviceId: 'child',
      deviceName: 'Child',
      remoteAddress: '192.168.1.2',
    );
    s.approvePending();
    await s.stop();
    await s.stop();
    s.dispose();
  });
  test(
    'invalid pairing code is rejected before a network connection',
    () async {
      await expectLater(
        PairingClient.pair(
          host: '192.168.1.2',
          code: '',
          deviceId: 'child',
          deviceName: 'Child',
        ),
        throwsFormatException,
      );
    },
  );
  test('server can stop and bind its port again', () async {
    final s = server();
    await s.start();
    expect(s.isRunning, isTrue);
    await s.stop();
    await s.start();
    expect(s.isRunning, isTrue);
    await s.stop();
    s.dispose();
  });
}

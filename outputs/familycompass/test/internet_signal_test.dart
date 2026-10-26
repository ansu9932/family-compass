import 'package:flutter_test/flutter_test.dart';
import 'package:familycompass/internet_signal.dart';

void main() {
  const secret = 'ABCDEFGHIJKLMNOPQRSTUVWXY23456789ABCDEFGHIJKLMNOP';
  InternetSignalClient make(String role, [String key = secret]) =>
      InternetSignalClient(
        baseUrl: 'https://relay.example',
        sharedSecret: key,
        role: role,
      );
  test(
    'paired devices decrypt signaling with independent encryption and auth keys',
    () async {
      final parent = make('parent'), child = make('child');
      final envelope = await parent.seal({
        'kind': 'request',
        'mode': 'camera',
      }, 'parent');
      expect(await child.open(envelope, 'parent'), {
        'kind': 'request',
        'mode': 'camera',
      });
      expect(envelope.toString(), isNot(contains('camera')));
      expect(await parent.room, await child.room);
      parent.close();
      child.close();
    },
  );
  test('wrong key and swapped mailbox are rejected', () async {
    final parent = make('parent'),
        other = make('child', 'ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ');
    final envelope = await parent.seal({'kind': 'stop'}, 'parent');
    await expectLater(other.open(envelope, 'parent'), throwsA(anything));
    await expectLater(parent.open(envelope, 'child'), throwsA(anything));
    parent.close();
    other.close();
  });
  test('fresh nonce on each message and HTTPS required', () async {
    final c = make('parent');
    expect(
      (await c.seal({}, 'parent'))['nonce'],
      isNot((await c.seal({}, 'parent'))['nonce']),
    );
    expect(
      () => InternetSignalClient(
        baseUrl: 'http://relay.example',
        sharedSecret: secret,
        role: 'parent',
      ),
      throwsFormatException,
    );
    c.close();
  });
}

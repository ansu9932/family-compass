import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'device_store.dart';
import 'internet_pairing.dart';
import 'local_pairing.dart' show secureToken;
import 'remote_media.dart';
import 'notification_activity.dart';
import 'phone_status.dart';
import 'internet_signal.dart';
import 'child_pin.dart';

const relayUrl = String.fromEnvironment('FC_RELAY_URL');
const blue = Color(0xFF2563EB);
const native = MethodChannel('app.familycompass/media_capture');

void main() => runApp(const FamilyCompassApp());

class FamilyCompassApp extends StatelessWidget {
  const FamilyCompassApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: Platform.isIOS ? 'Family Compass Parent' : 'Family Compass Child',
    debugShowCheckedModeBanner: false,
    builder: (_, child) =>
        Platform.isAndroid ? ChildPinGate(child: child!) : child!,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: blue),
      scaffoldBackgroundColor: const Color(0xFFF5F7FC),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFF5F7FC),
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    home: const FamilyCompassHome(),
  );
}

class FamilyCompassHome extends StatefulWidget {
  const FamilyCompassHome({super.key});
  @override
  State<FamilyCompassHome> createState() => _FamilyCompassHomeState();
}

class _FamilyCompassHomeState extends State<FamilyCompassHome>
    with WidgetsBindingObserver {
  final prefs = SharedPreferencesAsync();
  final code = TextEditingController(),
      name = TextEditingController(text: 'Child phone');
  List<FamilyDevice> devices = [];
  String family = '', id = '', childName = '', secret = '';
  bool loading = true, busy = false, ready = false;
  String? error;
  final Map<String, Map<String, dynamic>> phoneStatuses = {};
  Timer? statusTimer;
  bool statusBusy = false, foreground = true;
  bool get parent => Platform.isIOS;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    statusTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => updatePhoneStatuses(),
    );
    unawaited(load());
  }

  Future<void> load() async {
    try {
      family = await prefs.getString('fc.familyId') ?? 'FC-${secureToken(8)}';
      id = await prefs.getString('fc.deviceId') ?? 'device-${secureToken(16)}';
      await prefs.setString('fc.familyId', family);
      await prefs.setString('fc.deviceId', id);
      if (parent) {
        devices = await DeviceStore.load();
      } else {
        secret = await DeviceStore.storage.read(key: 'fc.sharedSecret') ?? '';
        childName = await prefs.getString('fc.deviceName') ?? 'Child phone';
        name.text = childName;
        ready = await prefs.getBool('fc.childSetup.v2') ?? false;
        final pin = await childPinNative.invokeMapMethod<String, dynamic>(
          'status',
        );
        if (pin?['configured'] != true) ready = false;
      }
    } catch (e) {
      error = 'Could not load saved devices: $e';
    }
    if (mounted) setState(() => loading = false);
    unawaited(updatePhoneStatuses());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) unawaited(updatePhoneStatuses());
  }

  Future<void> updatePhoneStatuses() async {
    if (statusBusy ||
        loading ||
        !mounted ||
        relayUrl.isEmpty ||
        (parent && !foreground))
      return;
    statusBusy = true;
    try {
      if (parent) {
        await Future.wait(
          devices.map((d) async {
            final client = InternetSignalClient(
              baseUrl: relayUrl,
              sharedSecret: d.secret,
              role: 'parent',
            );
            try {
              final status = await client.receiveDeviceStatus();
              if (status != null &&
                  status['v'] == 1 &&
                  status['at'] is int &&
                  mounted)
                phoneStatuses[d.id] = status;
            } catch (_) {
              /* Keep last observation, marked stale by its timestamp. */
            } finally {
              client.close();
            }
          }),
        );
        if (mounted) setState(() {});
      } else if (secret.isNotEmpty) {
        final client = InternetSignalClient(
          baseUrl: relayUrl,
          sharedSecret: secret,
          role: 'child',
        );
        try {
          final status = await native.invokeMapMethod<String, dynamic>(
            'deviceStatus',
          );
          if (status != null) await client.sendDeviceStatus(status);
        } finally {
          client.close();
        }
      }
    } catch (_) {
      /* Retry on the next heartbeat; never interrupt a media session. */
    } finally {
      statusBusy = false;
    }
  }

  Future<void> saveDevice(FamilyDevice d) async {
    final next = [...devices.where((e) => e.id != d.id), d];
    await DeviceStore.save(next);
    if (mounted) setState(() => devices = next);
    unawaited(updatePhoneStatuses());
  }

  Future<void> add() async {
    await Navigator.push(
      context,
      MaterialPageRoute<FamilyDevice>(
        builder: (_) => AddDevicePage(
          relayUrl: relayUrl,
          familyId: family,
          saveDevice: saveDevice,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> join() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final label = name.text.trim();
      if (label.isEmpty || label.length > 60)
        throw const FormatException('Enter a phone name (1–60 characters).');
      final result = await joinOverInternet(
        relayUrl: relayUrl,
        code: code.text,
        name: label,
        id: id,
      );
      if (!mounted) return;
      await DeviceStore.storage.write(
        key: 'fc.sharedSecret',
        value: result['secret'] as String,
      );
      await prefs.setString('fc.familyId', result['familyId'] as String);
      await prefs.setString('fc.deviceName', label);
      await prefs.setString('fc.role', 'managed');
      await prefs.setBool('fc.childSetup.v2', false);
      if (mounted)
        setState(() {
          secret = result['secret'] as String;
          family = result['familyId'] as String;
          childName = label;
          ready = false;
        });
    } catch (e) {
      if (mounted)
        setState(
          () => error = e is FormatException
              ? e.message
              : 'Pairing failed. Check internet and try again.',
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> rename(FamilyDevice d) async {
    final input = TextEditingController(text: d.name);
    final value = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Device name'),
        content: TextField(controller: input, maxLength: 60, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, input.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    // Dialog exit animations may still be using the controller.
    if (value != null && value.isNotEmpty)
      await saveDevice(FamilyDevice(d.id, value, d.secret));
  }

  Future<void> remove(FamilyDevice d) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove ${d.name}?'),
        content: const Text(
          'This iPhone will forget its access key. Pair the Android phone again to reconnect it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (yes == true) {
      final next = devices.where((e) => e.id != d.id).toList();
      await DeviceStore.save(next);
      phoneStatuses.remove(d.id);
      if (mounted) setState(() => devices = next);
    }
  }

  void open(FamilyDevice d, String mode) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => RemoteMediaPage(
          parent: true,
          secret: d.secret,
          relayUrl: relayUrl,
          deviceName: d.name,
          initialMode: mode,
        ),
      ),
    );
  }

  @override
  void dispose() {
    statusTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    code.dispose();
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (loading)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (relayUrl.isEmpty || family.isEmpty)
      return Scaffold(
        body: Center(
          child: Text(error ?? 'Relay address is missing from this build.'),
        ),
      );
    if (parent) return parentHome();
    if (secret.isNotEmpty && ready)
      return RemoteMediaPage(
        key: ValueKey(secret),
        parent: false,
        secret: secret,
        relayUrl: relayUrl,
        deviceName: childName,
        onSetup: () async {
          await prefs.setBool('fc.childSetup.v2', false);
          if (mounted) setState(() => ready = false);
        },
      );
    if (secret.isNotEmpty)
      return ChildSetup(
        name: childName,
        secret: secret,
        onComplete: () async {
          final pin = await childPinNative.invokeMapMethod<String, dynamic>(
            'status',
          );
          if (!mounted) return;
          if (pin?['configured'] != true) {
            final created = await Navigator.push<bool>(
              context,
              MaterialPageRoute(builder: (_) => const ChildPinSetup()),
            );
            if (created != true) return;
          }
          await prefs.setBool('fc.childSetup.v2', true);
          if (mounted) setState(() => ready = true);
        },
        onRePair: () async {
          final yes = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text('Pair with another parent?'),
              content: const Text(
                'The current parent will lose access when pairing is replaced.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('Continue'),
                ),
              ],
            ),
          );
          if (yes == true) {
            await activityNative.invokeMethod<void>('reset');
            await DeviceStore.storage.delete(key: 'fc.sharedSecret');
            if (mounted) setState(() => secret = '');
          }
        },
      );
    return Scaffold(
      appBar: AppBar(title: const Text('Family Compass Child')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Icon(Icons.family_restroom_rounded, size: 74, color: blue),
          const SizedBox(height: 24),
          const Text(
            'Join your family',
            style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          const Text(
            'On the iPhone, open Family Compass Parent → Add device. Enter that private binding code below. No account or sign-in needed.',
          ),
          const SizedBox(height: 28),
          TextField(
            controller: name,
            maxLength: 60,
            decoration: const InputDecoration(
              labelText: 'Phone name',
              hintText: 'For example, Samsung A34',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: code,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Binding code',
              hintText: 'XXXX-XXXX-XXXX-XXXX-XXXX',
            ),
          ),
          const SizedBox(height: 20),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(error!, style: const TextStyle(color: Colors.red)),
            ),
          FilledButton.icon(
            onPressed: busy ? null : join,
            icon: const Icon(Icons.link),
            label: Text(
              busy ? 'Waiting for parent approval…' : 'Connect to parent',
            ),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.all(20),
              child: LinearProgressIndicator(),
            ),
          const SizedBox(height: 20),
          const Text(
            'Only pair a device you are authorized to supervise. Camera and microphone use remain visible, and sharing can be stopped from this phone.',
          ),
        ],
      ),
    );
  }

  Widget parentHome() => Scaffold(
    appBar: AppBar(
      title: const Text('Family Compass'),
      actions: [
        IconButton(
          onPressed: add,
          icon: const Icon(Icons.add_circle_outline),
          tooltip: 'Add device',
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: blue,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Your family devices',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${devices.length} paired • No account needed',
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 20),
              FilledButton.tonalIcon(
                onPressed: add,
                icon: const Icon(Icons.add),
                label: const Text('Add device'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'Camera · Screen · Audio · Activity',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        const Text(
          'Choose a phone, then a feature. Add three or more Android phones; view one session at a time.',
        ),
        const SizedBox(height: 16),
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
        if (devices.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(28),
              child: Column(
                children: [
                  Icon(Icons.devices_rounded, size: 48, color: blue),
                  SizedBox(height: 16),
                  Text(
                    'Add your first Android phone',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Install the child APK, enter a binding code, and finish permissions on Android.',
                  ),
                ],
              ),
            ),
          ),
        for (final d in devices)
          Card(
            margin: const EdgeInsets.only(bottom: 16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const CircleAvatar(child: Icon(Icons.phone_android)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              d.name,
                              style: const TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Text(
                              'Paired securely',
                              style: TextStyle(color: Color(0xFF63718A)),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuButton<String>(
                        onSelected: (s) {
                          if (s == 'rename') {
                            unawaited(rename(d));
                          } else {
                            unawaited(remove(d));
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'rename', child: Text('Rename')),
                          PopupMenuItem(
                            value: 'remove',
                            child: Text('Remove device'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  PhoneStatusCard(status: phoneStatuses[d.id]),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      feature(d, 'camera', 'Camera', Icons.camera_alt_outlined),
                      feature(
                        d,
                        'screen',
                        'Screen',
                        Icons.screen_share_outlined,
                      ),
                      feature(d, 'audio', 'Audio', Icons.headphones_outlined),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              ActivityInbox(device: d, relayUrl: relayUrl),
                        ),
                      ),
                      icon: const Icon(Icons.notifications_none),
                      label: const Text('Notification activity & daily report'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        Text(
          'Family ID: $family',
          style: const TextStyle(color: Color(0xFF63718A)),
        ),
      ],
    ),
  );
  Widget feature(FamilyDevice d, String mode, String label, IconData icon) =>
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: OutlinedButton(
            onPressed: () => open(d, mode),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
            ),
            child: Column(
              children: [Icon(icon), const SizedBox(height: 6), Text(label)],
            ),
          ),
        ),
      );
}

class ChildSetup extends StatefulWidget {
  const ChildSetup({
    super.key,
    required this.name,
    required this.secret,
    required this.onComplete,
    required this.onRePair,
  });
  final String name, secret;
  final Future<void> Function() onComplete, onRePair;
  @override
  State<ChildSetup> createState() => _ChildSetupState();
}

class _ChildSetupState extends State<ChildSetup> with WidgetsBindingObserver {
  Map<String, dynamic> permissions = {};
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  Future<void> refresh() async {
    try {
      final p = await native.invokeMapMethod<String, dynamic>(
        'permissionStatus',
      );
      if (mounted) setState(() => permissions = p ?? {});
    } catch (e) {
      if (mounted) setState(() => error = 'Could not read permissions. $e');
    }
  }

  Future<void> grant(String permission) async {
    setState(() => busy = true);
    try {
      await native.invokeMethod<void>('requestMediaPermission', {
        'permission': permission,
      });
      await refresh();
    } catch (e) {
      if (mounted)
        setState(
          () => error =
              'Permission request failed. Use App settings to allow access.',
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget row(String key, String title, String subtitle, IconData icon) => Card(
    child: ListTile(
      leading: Icon(icon, color: blue),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: permissions[key] == true
          ? const Icon(Icons.check_circle, color: Colors.green)
          : TextButton(
              onPressed: busy ? null : () => grant(key),
              child: const Text('Allow'),
            ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Child setup')),
    body: ListView(
      padding: const EdgeInsets.all(22),
      children: [
        const Icon(Icons.verified_user_outlined, size: 64, color: blue),
        const SizedBox(height: 20),
        Text(
          '${widget.name} is paired',
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'Your paired parent can see this phone’s battery, charging and connection status while the app is available. Each media feature uses only the permission it needs.',
        ),
        const SizedBox(height: 24),
        row(
          'camera',
          'Remote camera',
          'Lets your paired parent view this phone’s camera.',
          Icons.camera_alt_outlined,
        ),
        row(
          'microphone',
          'One-way audio',
          'Lets your paired parent hear live audio from this phone.',
          Icons.mic_none,
        ),
        row(
          'notifications',
          'Sharing notifications',
          'Shows when a sharing session is active.',
          Icons.notifications_none,
        ),
        const Card(
          child: ListTile(
            leading: Icon(Icons.screen_share_outlined, color: blue),
            title: Text('Screen mirroring'),
            subtitle: Text(
              'Android asks which screen to share when a session starts. Confirm it on this phone each time.',
            ),
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => ChildActivitySettings(
                secret: widget.secret,
                relayUrl: relayUrl,
              ),
            ),
          ),
          icon: const Icon(Icons.notifications_none),
          label: const Text('Optional notification activity sharing'),
        ),
        OutlinedButton.icon(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<bool>(builder: (_) => const ChildPinSetup()),
          ),
          icon: const Icon(Icons.lock_outline),
          label: const Text('Set or change app PIN'),
        ),
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
        FilledButton(
          onPressed: busy ? null : widget.onComplete,
          child: const Text('Finish setup'),
        ),
        TextButton(
          onPressed: () => native.invokeMethod<void>('openAppSettings'),
          child: const Text('Open app permissions'),
        ),
        TextButton(
          onPressed: widget.onRePair,
          child: const Text('Pair with another parent'),
        ),
        const SizedBox(height: 12),
        const Text(
          'Next, choose whether to allow this paired parent to start camera/audio sessions without another app prompt. You can revoke this on the child screen. Keep the child app open and online to receive requests.',
        ),
      ],
    ),
  );
}

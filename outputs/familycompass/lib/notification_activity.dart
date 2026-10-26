import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'device_store.dart';
import 'internet_signal.dart';

const activityNative = MethodChannel('app.familycompass/activity');
const _mediaNative = MethodChannel('app.familycompass/media_capture');
const _day = Duration(hours: 24);

class ActivityEvent {
  const ActivityEvent(this.id, this.app, this.package, this.created);
  final String id, app, package;
  final DateTime created;
}

class ActivityClient {
  ActivityClient(String baseUrl, String secret)
    : signal = InternetSignalClient(
        baseUrl: baseUrl,
        sharedSecret: secret,
        role: 'parent',
      );
  final InternetSignalClient signal;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  Future<List<int>> get key async => (await Hmac.sha256().calculateMac(
    utf8.encode('familycompass-activity-key-v1'),
    secretKey: SecretKey(utf8.encode(signal.sharedSecret)),
  )).bytes;
  Future<Map<String, dynamic>> configuration() async => {
    'baseUrl': signal.base.toString(),
    'token': await signal.token,
    'room': await signal.room,
    'key': base64Encode(await key),
    'deploymentKey': const String.fromEnvironment('FC_RELAY_KEY'),
  };
  Future<({List<ActivityEvent> events, int cursor, bool more})> fetch(
    int cursor,
  ) async {
    final room = await signal.room;
    final url = signal.base
        .resolve('/v1/rooms/$room/activity')
        .replace(queryParameters: {'after': '$cursor'});
    final request = await _http
        .getUrl(url)
        .timeout(const Duration(seconds: 10));
    request.followRedirects = false;
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${await signal.token}',
    );
    request.headers.set(
      'X-Family-Compass-Client',
      const String.fromEnvironment('FC_RELAY_KEY'),
    );
    final response = await request.close().timeout(const Duration(seconds: 10));
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 10))) {
      if (bytes.length + chunk.length > 500000)
        throw const FormatException('Activity response is too large.');
      bytes.addAll(chunk);
    }
    if (response.statusCode != 200)
      throw const HttpException('Activity sync unavailable.');
    final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final rows = data['events'] as List<dynamic>;
    if (rows.length > 50) throw const FormatException('Invalid activity page.');
    final result = <ActivityEvent>[];
    final cipher = AesGcm.with256bits();
    final secretKey = SecretKey(await key);
    for (final raw in rows) {
      final row = raw as Map<String, dynamic>;
      final seq = row['seq'] as int, created = row['createdAt'] as int;
      final id = row['id'] as String;
      if (seq <= cursor || !RegExp(r'^[a-f0-9]{64}$').hasMatch(id))
        throw const FormatException('Invalid activity record.');
      final e = row['envelope'] as Map<String, dynamic>;
      final box = SecretBox(
        base64Decode(e['ciphertext'] as String),
        nonce: base64Decode(e['nonce'] as String),
        mac: Mac(base64Decode(e['mac'] as String)),
      );
      if (e['v'] != 1 ||
          box.nonce.length != 12 ||
          box.mac.bytes.length != 16 ||
          box.cipherText.length > 4096)
        throw const FormatException('Invalid activity envelope.');
      final clear = await cipher.decrypt(
        box,
        secretKey: secretKey,
        aad: utf8.encode('$room:activity:$id:$created'),
      );
      final summary = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      if (summary['v'] != 1 ||
          summary['createdAt'] != created ||
          summary['app'] is! String ||
          summary['package'] is! String)
        throw const FormatException('Invalid activity summary.');
      final app = summary['app'] as String,
          package = summary['package'] as String;
      if (app.length > 120 || package.length > 255)
        throw const FormatException('Invalid app label.');
      final time = DateTime.fromMillisecondsSinceEpoch(created);
      final now = DateTime.now();
      if (time.isAfter(now.subtract(_day)) &&
          !time.isAfter(now.add(const Duration(minutes: 1)))) {
        result.add(ActivityEvent(id, app, package, time));
      }
      cursor = seq;
    }
    return (events: result, cursor: cursor, more: data['hasMore'] == true);
  }

  void close() {
    _http.close(force: true);
    signal.close();
  }
}

class ActivityInbox extends StatefulWidget {
  const ActivityInbox({
    super.key,
    required this.device,
    required this.relayUrl,
  });
  final FamilyDevice device;
  final String relayUrl;
  @override
  State<ActivityInbox> createState() => _ActivityInboxState();
}

class _ActivityInboxState extends State<ActivityInbox>
    with WidgetsBindingObserver {
  late final ActivityClient client;
  final Map<String, ActivityEvent> events = {};
  Timer? poll, expiry;
  int cursor = 0;
  bool syncing = false,
      initial = true,
      exporting = false,
      todayOnly = false,
      foreground = true;
  String selected = '', query = '';
  String? error;
  DateTime? lastSync;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    client = ActivityClient(widget.relayUrl, widget.device.secret);
    unawaited(sync());
    poll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (foreground) unawaited(sync());
    });
    expiry = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(prune);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) {
      setState(prune);
      unawaited(sync());
    }
  }

  void prune() {
    final cutoff = DateTime.now().subtract(_day);
    events.removeWhere((_, event) => !event.created.isAfter(cutoff));
    if (selected.isNotEmpty &&
        !events.values.any((event) => event.package == selected))
      selected = '';
  }

  Future<void> sync() async {
    if (syncing || !mounted) return;
    syncing = true;
    try {
      bool more = true;
      int pages = 0;
      while (more && mounted && foreground && pages++ < 20) {
        final page = await client.fetch(cursor);
        if (!mounted) return;
        setState(() {
          for (final event in page.events) {
            events[event.id] = event;
          }
          cursor = page.cursor;
          prune();
        });
        more = page.more;
      }
      if (mounted)
        setState(() {
          lastSync = DateTime.now();
          error = more ? 'Loading older activity…' : null;
        });
    } catch (_) {
      if (mounted)
        setState(
          () => error =
              'Cannot sync right now. Check internet; this inbox will retry.',
        );
    } finally {
      syncing = false;
      if (mounted) setState(() => initial = false);
    }
  }

  List<ActivityEvent> get filtered {
    final now = DateTime.now();
    final midnight = DateTime(now.year, now.month, now.day);
    return events.values
        .where(
          (e) =>
              e.created.isAfter(now.subtract(_day)) &&
              (!todayOnly || !e.created.isBefore(midnight)) &&
              (selected.isEmpty || e.package == selected) &&
              ('${e.app} ${e.package}'.toLowerCase().contains(
                query.toLowerCase(),
              )),
        )
        .toList()
      ..sort((a, b) => b.created.compareTo(a.created));
  }

  String stamp(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';
  String clean(String text) => text.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');
  Future<void> export() async {
    setState(() => exporting = true);
    try {
      final records = filtered;
      final now = DateTime.now();
      final counts = <String, int>{};
      final labels = <String, String>{};
      for (final event in records) {
        counts.update(event.package, (v) => v + 1, ifAbsent: () => 1);
        labels[event.package] = event.app;
      }
      final report = StringBuffer('Family Compass — notification activity summary\n')
        ..writeln('Device: ${clean(widget.device.name)}')
        ..writeln(
          'Exported: ${stamp(now)} (${now.timeZoneName}, UTC offset ${now.timeZoneOffset})',
        )
        ..writeln(
          'Window: ${todayOnly ? 'Today within the last 24 hours' : 'Last 24 hours'}',
        )
        ..writeln(
          'App filter: ${clean(selected.isEmpty ? 'All apps' : selected)}; search: ${clean(query)}',
        )
        ..writeln(
          'Last relay sync: ${lastSync == null ? 'Not yet synced' : stamp(lastSync!)}',
        )
        ..writeln(
          'This is a snapshot of received activity. Offline or restricted notifications may be missing.',
        )
        ..writeln(
          'Message contents, senders and security codes are not collected. App updates and ongoing/group summaries are excluded.',
        )
        ..writeln(
          'App records expire after 24 hours. This exported copy remains until you delete it.\n',
        )
        ..writeln(
          'TOTAL: ${records.length} arrivals across ${counts.length} apps\n',
        )
        ..writeln('COUNTS BY APP');
      final packages = counts.keys.toList()
        ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
      for (final p in packages) {
        report.writeln('${counts[p]}  ${clean(labels[p]!)} ($p)');
      }
      report.writeln('\nARRIVAL TIMES (newest first)');
      for (final e in records) {
        report.writeln(
          '${stamp(e.created)} | ${clean(e.app)} | ${clean(e.package)}',
        );
      }
      await activityNative.invokeMethod<void>('exportText', {
        'name': 'Family-Compass-Activity-${stamp(now).substring(0, 10)}.txt',
        'text': report.toString(),
      });
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open the export sheet. Please try again.'),
          ),
        );
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  @override
  void dispose() {
    poll?.cancel();
    expiry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    client.close();
    events.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final records = filtered;
    final apps = <String, String>{
      for (final e in events.values) e.package: e.app,
    };
    final counts = <String, int>{};
    for (final e in records) {
      counts.update(e.package, (v) => v + 1, ifAbsent: () => 1);
    }
    final packages = apps.keys.toList()
      ..sort(
        (a, b) => apps[a]!.toLowerCase().compareTo(apps[b]!.toLowerCase()),
      );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notification activity'),
        actions: [
          IconButton(
            onPressed: syncing ? null : sync,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.device.name,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    error ??
                        (lastSync == null
                            ? 'Connecting…'
                            : 'Synced ${stamp(lastSync!)} • Updates while this inbox is open'),
                    style: TextStyle(
                      color: error != null ? Colors.deepOrange : Colors.black54,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          key: ValueKey(selected),
                          initialValue: selected,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'App'),
                          items: [
                            const DropdownMenuItem(
                              value: '',
                              child: Text('All apps'),
                            ),
                            for (final p in packages)
                              DropdownMenuItem(
                                value: p,
                                child: Text(
                                  apps[p]!,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (v) => setState(() => selected = v ?? ''),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<bool>(
                          isExpanded: true,
                          initialValue: false,
                          decoration: const InputDecoration(
                            labelText: 'Period',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: false,
                              child: Text('Last 24 hours'),
                            ),
                            DropdownMenuItem(value: true, child: Text('Today')),
                          ],
                          onChanged: (v) =>
                              setState(() => todayOnly = v ?? false),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search app name',
                    ),
                    onChanged: (v) => setState(() => query = v),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${records.length} arrivals · ${counts.length} apps',
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (counts.isNotEmpty)
                    SizedBox(
                      height: 38,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final p in counts.keys)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Chip(
                                label: Text('${apps[p]} · ${counts[p]}'),
                              ),
                            ),
                        ],
                      ),
                    ),
                  OutlinedButton.icon(
                    onPressed: initial || exporting ? null : export,
                    icon: const Icon(Icons.file_download_outlined),
                    label: Text(
                      exporting
                          ? 'Opening export…'
                          : 'Download daily report (.txt)',
                    ),
                  ),
                  const Text(
                    'App names and times only. Records expire after 24 hours. Saved exports remain until you delete them.',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
              ),
            ),
          ),
          if (initial)
            const SliverToBoxAdapter(child: LinearProgressIndicator()),
          if (records.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No activity in this filter yet.\n\nOn Android, open Notification activity, grant Notification access, then enable sharing. Only new arrivals are counted.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            )
          else
            SliverList.builder(
              itemCount: records.length,
              itemBuilder: (_, i) {
                final e = records[i];
                return ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.notifications_none),
                  ),
                  title: Text(e.app),
                  subtitle: Text('${e.package}\n${stamp(e.created)}'),
                  isThreeLine: true,
                );
              },
            ),
        ],
      ),
    );
  }
}

class ChildActivitySettings extends StatefulWidget {
  const ChildActivitySettings({
    super.key,
    required this.secret,
    required this.relayUrl,
  });
  final String secret, relayUrl;
  @override
  State<ChildActivitySettings> createState() => _ChildActivitySettingsState();
}

class _ChildActivitySettingsState extends State<ChildActivitySettings>
    with WidgetsBindingObserver {
  Map<String, dynamic> status = {};
  bool busy = false;
  String? error;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(refresh());
    timer = Timer.periodic(const Duration(seconds: 4), (_) => refresh());
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  Future<void> refresh() async {
    try {
      final value = await activityNative.invokeMapMethod<String, dynamic>(
        'status',
      );
      if (mounted)
        setState(() {
          status = value ?? {};
          error = null;
        });
    } catch (_) {
      if (mounted)
        setState(
          () => error = 'Could not read activity settings. Reopen this page.',
        );
    }
  }

  Future<void> action(Future<void> Function() work) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await work();
      await refresh();
    } on PlatformException catch (e) {
      if (mounted)
        setState(() => error = e.message ?? 'Could not update sharing.');
    } catch (_) {
      if (mounted)
        setState(() => error = 'Could not update sharing. Try again.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> explain() async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Share notification activity?'),
          content: const Text(
            'Your paired parent will receive app names and arrival times for new notifications. Android grants broad Notification access, but Family Compass does not read or send message contents, sender names or security codes.\n\nSummaries are encrypted and expire after 24 hours. Parent exports are separate saved copies. A visible sharing notification has a Stop button. You can also stop here or revoke Notification access in Settings.',
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
      ) ??
      false;
  Future<void> access() async {
    if (await explain())
      await action(
        () => activityNative.invokeMethod<void>('openAccessSettings'),
      );
  }

  Future<void> toggle(bool enable) async {
    if (enable && !await explain()) return;
    await action(() async {
      if (!enable) {
        await activityNative.invokeMethod<void>('stop');
        return;
      }
      final client = ActivityClient(widget.relayUrl, widget.secret);
      try {
        await activityNative.invokeMethod<void>(
          'enable',
          await client.configuration(),
        );
      } finally {
        client.close();
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Notification activity')),
    body: ListView(
      padding: const EdgeInsets.all(22),
      children: [
        const Icon(
          Icons.notifications_active_outlined,
          size: 58,
          color: Color(0xFF2563EB),
        ),
        const SizedBox(height: 18),
        const Text(
          'Share an activity summary',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        const Text(
          'Optional. Share which apps receive notifications and when, so your paired parent can view counts and download a daily report. Message text, sender names and security codes are not collected.',
        ),
        const SizedBox(height: 18),
        Card(
          child: ListTile(
            title: const Text('1. Allow visible sharing notifications'),
            subtitle: const Text(
              'The status notification includes a Stop sharing button.',
            ),
            trailing: status['notifications'] == true
                ? const Icon(Icons.check_circle, color: Colors.green)
                : TextButton(
                    onPressed: busy
                        ? null
                        : () => action(
                            () => _mediaNative.invokeMethod<void>(
                              'requestMediaPermission',
                              {'permission': 'notifications'},
                            ),
                          ),
                    child: const Text('Allow'),
                  ),
          ),
        ),
        Card(
          child: ListTile(
            title: const Text('2. Grant Android Notification access'),
            subtitle: const Text(
              'Choose Family Compass activity summaries in Android settings.',
            ),
            trailing: TextButton(
              onPressed: busy ? null : access,
              child: Text(status['access'] == true ? 'Granted' : 'Open'),
            ),
          ),
        ),
        Card(
          child: SwitchListTile(
            title: const Text('3. Share activity with paired parent'),
            value: status['enabled'] == true,
            onChanged:
                busy ||
                    (status['enabled'] != true &&
                        (status['access'] != true ||
                            status['notifications'] != true))
                ? null
                : toggle,
            subtitle: Text(
              status['enabled'] == true
                  ? (status['connected'] == true
                        ? 'Sharing is on • ${status['pending'] ?? 0} waiting to sync'
                        : 'Waiting for Android to connect notification access')
                  : 'Sharing is off',
            ),
          ),
        ),
        if (busy) const LinearProgressIndicator(),
        if (error != null || (status['error'] as String? ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              error ?? status['error'] as String,
              style: const TextStyle(color: Colors.deepOrange),
            ),
          ),
        const SizedBox(height: 16),
        const Text(
          'The parent inbox updates while open and catches up when reopened. Network and battery restrictions can delay delivery. Ongoing notifications, grouped summaries and updates to an existing notification are excluded. App records expire after 24 hours; saved reports must be deleted by whoever exports them.',
        ),
        TextButton(
          onPressed: () => _mediaNative.invokeMethod<void>('openAppSettings'),
          child: const Text('Open app notification settings'),
        ),
      ],
    ),
  );
}

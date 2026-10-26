import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const childPinNative = MethodChannel('app.familycompass/child_pin');
const _media = MethodChannel('app.familycompass/media_capture');

/// Sits above the Navigator so every app route is covered while locked.
/// The underlying runtime remains mounted for explicitly enabled background sharing.
class ChildPinGate extends StatefulWidget {
  const ChildPinGate({super.key, required this.child});
  final Widget child;
  @override
  State<ChildPinGate> createState() => _ChildPinGateState();
}

class _ChildPinGateState extends State<ChildPinGate>
    with WidgetsBindingObserver {
  bool loading = true,
      configured = false,
      locked = true,
      busy = false,
      stopping = false;
  int remaining = 0, revision = 0;
  String? error, notice;
  final pin = TextEditingController();
  Timer? timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    childPinNative.setMethodCallHandler((call) async {
      if (call.method == 'changed') await refresh();
    });
    unawaited(refresh());
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && remaining > 0) setState(() => remaining--);
    });
  }

  Future<void> refresh() async {
    final request = ++revision;
    try {
      final value =
          await childPinNative.invokeMapMethod<String, dynamic>('status') ?? {};
      if (!mounted || request != revision) return;
      setState(() {
        configured = value['configured'] == true;
        locked = value['unlocked'] != true;
        remaining = value['remaining'] as int? ?? 0;
        loading = false;
      });
    } catch (_) {
      if (mounted && request == revision)
        setState(() {
          loading = false;
          locked = true;
          error = 'Could not read PIN protection. Close and reopen the app.';
        });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      revision++;
      pin.clear();
      if (configured && mounted)
        setState(() {
          locked = true;
          error = null;
        });
    }
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  Future<void> unlock() async {
    if (busy || remaining > 0) return;
    if (!RegExp(r'^\d{6}$').hasMatch(pin.text)) {
      setState(() => error = 'Enter the six-digit app PIN.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await childPinNative.invokeMapMethod<String, dynamic>(
        'verify',
        {'pin': pin.text},
      );
      pin.clear();
      if (mounted)
        setState(
          () => error = result?['accepted'] == true
              ? null
              : 'PIN incorrect, or the app was closed. Try again.',
        );
    } on PlatformException catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      pin.clear();
      await refresh();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> stop() async {
    if (stopping) return;
    setState(() => stopping = true);
    try {
      await _media.invokeMethod<void>('stopAllSharing');
      if (mounted)
        setState(
          () => notice =
              'Sharing stopped. Unlock and enable Keep available or activity sharing to resume.',
        );
    } catch (_) {
      if (mounted)
        setState(
          () => notice =
              'Use the sharing notification’s Stop button or Android app settings to stop the app.',
        );
    } finally {
      if (mounted) setState(() => stopping = false);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    pin.dispose();
    childPinNative.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      IgnorePointer(
        ignoring: loading || locked,
        child: ExcludeSemantics(
          excluding: loading || locked,
          child: FocusScope(
            canRequestFocus: !loading && !locked,
            child: widget.child,
          ),
        ),
      ),
      if (loading || locked)
        Positioned.fill(
          child: Scaffold(
            body: SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(28),
                children: [
                  const SizedBox(height: 40),
                  const Icon(
                    Icons.lock_outline,
                    size: 68,
                    color: Color(0xFF2563EB),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Family Compass Child',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Enter the app PIN to open controls. Any sharing already enabled remains visible in the notification panel.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  if (loading)
                    const Center(child: CircularProgressIndicator())
                  else ...[
                    TextField(
                      controller: pin,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Six-digit app PIN',
                      ),
                      onSubmitted: (_) => unlock(),
                      enabled: !busy && remaining == 0,
                    ),
                    const SizedBox(height: 16),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          error!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    FilledButton(
                      onPressed: busy || remaining > 0 ? null : unlock,
                      child: Text(
                        busy
                            ? 'Checking…'
                            : remaining > 0
                            ? 'Try again in $remaining seconds'
                            : 'Unlock',
                      ),
                    ),
                    if (busy)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: LinearProgressIndicator(),
                      ),
                    const SizedBox(height: 24),
                    OutlinedButton.icon(
                      onPressed: stopping ? null : stop,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: Text(
                        stopping
                            ? 'Stopping…'
                            : 'Stop all sharing — no PIN needed',
                      ),
                    ),
                    if (notice != null)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(notice!),
                      ),
                    const SizedBox(height: 20),
                    const Text(
                      'Forgot the PIN? Reset this app’s data through Android Settings and pair it again. This removes saved pairing and app settings. The app PIN does not control Android uninstall or system settings.',
                      style: TextStyle(color: Colors.black54),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
    ],
  );
}

class ChildPinSetup extends StatefulWidget {
  const ChildPinSetup({super.key});
  @override
  State<ChildPinSetup> createState() => _ChildPinSetupState();
}

class _ChildPinSetupState extends State<ChildPinSetup> {
  final current = TextEditingController(),
      pin = TextEditingController(),
      repeat = TextEditingController();
  bool configured = false, loading = true, busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    try {
      final state = await childPinNative.invokeMapMethod<String, dynamic>(
        'status',
      );
      if (mounted)
        setState(() {
          configured = state?['configured'] == true;
          loading = false;
        });
    } catch (_) {
      if (mounted)
        setState(() {
          error = 'Could not read PIN settings.';
          loading = false;
        });
    }
  }

  Future<void> save() async {
    if (busy) return;
    if (!RegExp(r'^\d{6}$').hasMatch(pin.text)) {
      setState(() => error = 'Choose a six-digit PIN.');
      return;
    }
    if (pin.text != repeat.text) {
      setState(() => error = 'The two new PIN entries do not match.');
      return;
    }
    if (configured && !RegExp(r'^\d{6}$').hasMatch(current.text)) {
      setState(() => error = 'Enter the current six-digit PIN.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await childPinNative.invokeMethod<void>('setPin', {
        'pin': pin.text,
        if (configured) 'oldPin': current.text,
      });
      current.clear();
      pin.clear();
      repeat.clear();
      if (mounted) Navigator.of(context).pop(true);
    } on PlatformException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = 'Could not save the PIN. Try again.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget field(TextEditingController controller, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      controller: controller,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(6),
      ],
      decoration: InputDecoration(labelText: label),
      enabled: !busy,
    ),
  );
  @override
  void dispose() {
    current.dispose();
    pin.dispose();
    repeat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(configured ? 'Change app PIN' : 'Create app PIN'),
    ),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Icon(Icons.password, size: 56, color: Color(0xFF2563EB)),
        const SizedBox(height: 20),
        const Text(
          'Set a six-digit PIN on this phone. It is required when opening the child app again. Enter it here only; do not send it in chat.',
        ),
        const SizedBox(height: 20),
        if (loading)
          const LinearProgressIndicator()
        else ...[
          if (configured) field(current, 'Current PIN'),
          field(pin, 'New six-digit PIN'),
          field(repeat, 'Confirm new PIN'),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(error!, style: const TextStyle(color: Colors.red)),
            ),
          FilledButton(
            onPressed: busy ? null : save,
            child: Text(busy ? 'Saving securely…' : 'Save PIN'),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: LinearProgressIndicator(),
            ),
        ],
        const SizedBox(height: 20),
        const Text(
          'Keep the PIN somewhere safe. Resetting forgotten PIN protection through Android app settings also clears pairing. Stop sharing remains available without a PIN; Android uninstall and system controls remain accessible.',
          style: TextStyle(color: Colors.black54),
        ),
      ],
    ),
  );
}

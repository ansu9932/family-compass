import 'package:flutter/material.dart';

class PhoneStatusCard extends StatelessWidget {
  const PhoneStatusCard({super.key, required this.status});
  final Map<String, dynamic>? status;
  @override
  Widget build(BuildContext context) {
    final s = status;
    final at = s?['at'] is int
        ? DateTime.fromMillisecondsSinceEpoch(s!['at'] as int)
        : null;
    final age = at == null ? null : DateTime.now().difference(at);
    final fresh = age != null && age.inSeconds <= 45 && age.inSeconds >= -60;
    final battery = s?['battery'];
    final charging = s?['charging'] == true;
    final plugged = s?['plugged'] == true;
    final network = s?['network'];
    final icon = switch (network) {
      'wifi' => Icons.wifi,
      'mobile' => Icons.signal_cellular_alt,
      'ethernet' => Icons.settings_ethernet,
      'vpn' => Icons.vpn_lock,
      _ => Icons.wifi_off,
    };
    final connection = switch (network) {
      'wifi' => 'Wi-Fi',
      'mobile' => 'Mobile data',
      'ethernet' => 'Ethernet',
      'vpn' => 'VPN',
      'other' => 'Other network',
      'offline' => 'No network',
      _ => 'Waiting',
    };
    final power = charging
        ? 'Charging'
        : plugged
        ? (s?['full'] == true ? 'Plugged in · Full' : 'Plugged in')
        : 'On battery';
    String seen = 'Waiting for child phone';
    if (at != null) {
      final time =
          '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}:${at.second.toString().padLeft(2, '0')}';
      seen = fresh
          ? 'Live · updated $time'
          : 'Last updated ${at.day}/${at.month} $time · phone not reporting';
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: fresh ? const Color(0xFFF0F7FF) : const Color(0xFFF2F3F5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    charging ? Icons.battery_charging_full : Icons.battery_std,
                    size: 21,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    battery is int && battery >= 0 && battery <= 100
                        ? '$battery% · $power'
                        : 'Battery unavailable',
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 21),
                  const SizedBox(width: 5),
                  Text(connection),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            seen,
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ],
      ),
    );
  }
}

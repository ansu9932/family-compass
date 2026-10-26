import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FamilyDevice {
  const FamilyDevice(this.id, this.name, this.secret);
  final String id, name, secret;
  Map<String, String> toJson() => {'id': id, 'name': name, 'secret': secret};
  factory FamilyDevice.fromJson(Map<String, dynamic> j) => FamilyDevice(
    j['id'] as String,
    j['name'] as String,
    j['secret'] as String,
  );
}

class DeviceStore {
  static const storage = FlutterSecureStorage();
  static const key = 'fc.devices.v2';
  static Future<List<FamilyDevice>> load() async {
    final saved = await storage.read(key: key);
    if (saved != null) {
      return (jsonDecode(saved) as List)
          .map(
            (e) => FamilyDevice.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList();
    }
    // Preserve the existing working pair when upgrading from the single-device app.
    final prefs = SharedPreferencesAsync();
    final secret = await storage.read(key: 'fc.sharedSecret');
    final name = await prefs.getString('fc.pairedDevice');
    final devices = <FamilyDevice>[];
    if (secret != null && name != null)
      devices.add(FamilyDevice('legacy', name, secret));
    await save(devices);
    return devices;
  }

  static Future<void> save(List<FamilyDevice> devices) => storage.write(
    key: key,
    value: jsonEncode(devices.map((d) => d.toJson()).toList()),
  );
}

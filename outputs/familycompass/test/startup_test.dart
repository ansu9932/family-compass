import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:familycompass/main.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

final class FailingPreferences extends InMemorySharedPreferencesAsync {
  FailingPreferences() : super.empty();
  bool failing = true;
  @override
  Future<String?> getString(
    String key,
    SharedPreferencesOptions options,
  ) async {
    if (failing) throw StateError('Storage unavailable');
    return super.getString(key, options);
  }
}

void main() {
  testWidgets('fresh install opens setup and creates parent family', (
    tester,
  ) async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await tester.pumpWidget(const FamilyCompassApp());
    await tester.pumpAndSettle();
    expect(find.text('Set up this phone for a parent'), findsOneWidget);
    await tester.tap(find.text('Set up this phone for a parent'));
    await tester.pumpAndSettle();
    expect(find.text('Your family, at a glance'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('storage failure offers retry and recovers', (tester) async {
    final prefs = FailingPreferences();
    SharedPreferencesAsyncPlatform.instance = prefs;
    await tester.pumpWidget(const FamilyCompassApp());
    await tester.pumpAndSettle();
    expect(find.text('Try again'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    prefs.failing = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Set up this phone for a parent'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid saved location does not crash parent dashboard', (
    tester,
  ) async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({
          'fc.role': 'parent',
          'fc.familyId': 'FC-TEST',
          'fc.lastLocation': '{"latitude":"invalid","longitude":1}',
        });
    await tester.pumpWidget(const FamilyCompassApp());
    await tester.pumpAndSettle();
    expect(find.text('Your family, at a glance'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

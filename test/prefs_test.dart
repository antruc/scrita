import 'package:flutter_test/flutter_test.dart';
import 'package:scrita/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'exportPrefs and importPrefs round trip every type, skip unknown keys '
    'and wrong types',
    () async {
      SharedPreferences.setMockInitialValues({});
      await initPrefs();

      // What a backup's JSON decodes to.
      await importPrefs({
        'audioSource': 'mic',
        'lastSpeakers': 4,
        'rtf_x': 0.5,
        'materialYou': true,
        'list': ['a', 1],
        'nested': {'x': 1},
        'unknown': 'x',
        // Wrong types: reading them back would throw at launch.
        'seedColor': 'red',
        'themeMode': 1,
      });

      expect(audioSource.name, 'mic');
      expect(lastSpeakers, 4);
      expect(materialYou, isTrue);
      expect(seedColor, isNotNull);
      expect(themeMode, isNotNull);
      expect(exportPrefs(), {
        'audioSource': 'mic',
        'lastSpeakers': 4,
        'rtf_x': 0.5,
        'materialYou': true,
      });
    },
  );
}

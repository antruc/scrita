import 'package:flutter_test/flutter_test.dart';
import 'package:scrita/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'exportPrefs and importPrefs round trip every type, skip unknown',
    () async {
      SharedPreferences.setMockInitialValues({});
      await initPrefs();

      // What a backup's JSON decodes to.
      await importPrefs({
        'audioSource': 'mic',
        'lastSpeakers': 4,
        'ratio': 0.5,
        'materialYou': true,
        'list': ['a', 1],
        'nested': {'x': 1},
      });

      expect(audioSource.name, 'mic');
      expect(lastSpeakers, 4);
      expect(materialYou, isTrue);
      expect(exportPrefs(), {
        'audioSource': 'mic',
        'lastSpeakers': 4,
        'ratio': 0.5,
        'materialYou': true,
      });
    },
  );
}

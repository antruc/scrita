import 'dart:math' as math;

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'background.dart';
import 'l10n.dart';
import 'prefs.dart';
import 'screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before anything that can fail, so the error screen is in the same
  // language. ponytail: read once at launch, a device language change shows
  // on next start. Live switching would rebuild back at Home, cutting a
  // recording.
  uiSpanish =
      WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'es';
  try {
    await _setup();
  } catch (e, s) {
    // A throw before runApp leaves the launch screen blank forever: show it.
    // Only a broken install or update gets here. Never suggest clearing data
    // or reinstalling: the recordings live in the app's private storage.
    debugPrint('Startup failed: $e\n$s');
    // Fixed default palette: the saved theme may be what failed to load.
    runApp(
      MaterialApp(
        theme: _theme(Colors.indigo, Brightness.light),
        darkTheme: _theme(Colors.indigo, Brightness.dark),
        home: Scaffold(
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  tr(
                    'Scrita no pudo abrirse. Ciérrala y vuelve a abrirla. Si '
                        'sigue pasando, actualiza la app',
                    "Scrita couldn't open. Close it and open it again. If it "
                        'keeps happening, update the app',
                  ),
                  style: const TextStyle(fontSize: 18),
                ),
                const SizedBox(height: 24),
                // The error stays hidden; the user pastes it into a bug report.
                Builder(
                  builder: (context) => OutlinedButton.icon(
                    icon: const Icon(Icons.copy),
                    label: Text(tr('Copiar detalles', 'Copy details')),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: '$e\n\n$s'));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            tr('Detalles copiados', 'Details copied'),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return;
  }
  runApp(const ScritaApp());
}

Future<void> _setup() async {
  await initPrefs();
  // Same on every version: Android 15+ forces it, older ones opt in, so the
  // footer-colored strip in ScritaApp has a navigation bar to paint behind.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // The scheme is regrown from the wallpaper's primary tone so it has every
  // Material 3 role, same as the fixed palettes.
  // Cosmetic only: a plugin failure must not stop the app from opening.
  try {
    final core = await DynamicColorPlugin.getCorePalette();
    if (core != null) wallpaperSeed = Color(core.primary.get(40));
  } catch (e) {
    debugPrint('Wallpaper colors unavailable: $e');
  }
  appTheme.value = (themeMode, _seed);
  BackgroundService.init();
  // CC-BY-4.0 (Parakeet) and Apache-2.0 (TitaNet) attributions live in
  // NOTICE; it and the other model licenses appear under "View licenses" in
  // Settings > About.
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Parakeet TDT 0.6B v3',
      'TitaNet small',
    ], await rootBundle.loadString('NOTICE'));
    // MIT models: the license text must ship with them.
    for (final (name, file) in [
      ('Silero VAD', 'silero-vad-LICENSE.txt'),
      ('pyannote segmentation 3.0', 'pyannote-LICENSE.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks([
        name,
      ], await rootBundle.loadString('assets/models/$file'));
    }
  });
}

/// Wallpaper seed color, null where Material You is missing (Android < 12).
/// ponytail: read once at launch, a wallpaper change shows on next start.
Color? wallpaperSeed;

/// Current theme mode and seed color. Changing it repaints in place, no
/// rebuild back at Home.
final appTheme = ValueNotifier((themeMode, seedColor));

Color get _seed => materialYou ? wallpaperSeed ?? seedColor : seedColor;

/// Saves the theme and repaints the app with it. [seed] picks a palette and
/// turns Material You off; [wallpaper] turns it on.
void setTheme({ThemeMode? mode, Color? seed, bool wallpaper = false}) {
  if (mode != null) themeMode = mode;
  if (seed != null) {
    seedColor = seed;
    materialYou = false;
  }
  if (wallpaper) materialYou = true;
  appTheme.value = (themeMode, _seed);
}

class ScritaApp extends StatelessWidget {
  const ScritaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: appTheme,
      builder: (_, t, _) => _app(t.$1, t.$2),
    );
  }

  Widget _app(ThemeMode mode, Color seed) {
    return MaterialApp(
      title: 'Scrita',
      debugShowCheckedModeBanner: false,
      // Material's own texts (tooltips, accessibility) follow the same
      // language.
      locale: Locale(uiSpanish ? 'es' : 'en'),
      supportedLocales: const [Locale('en'), Locale('es')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      themeMode: mode,
      theme: _theme(seed, Brightness.light),
      darkTheme: _theme(seed, Brightness.dark),
      // Paints the system navigation bar in the footer color, on every
      // screen. Edge-to-edge ignores systemNavigationBarColor, so the app
      // draws it. Taps pass through. Contrast off: otherwise Android lays a
      // translucent scrim over it with 3-button navigation.
      builder: (context, child) {
        final theme = Theme.of(context);
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarContrastEnforced: false,
            systemNavigationBarIconBrightness:
                theme.brightness == Brightness.dark
                ? Brightness.light
                : Brightness.dark,
          ),
          child: Stack(
            children: [
              child!,
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: MediaQuery.viewPaddingOf(context).bottom,
                child: ColoredBox(color: footerColor(theme)),
              ),
            ],
          ),
        );
      },
      home: const HomeScreen(),
    );
  }
}

/// Material 3 theme from [seed]. The AppBar, and the status bar behind it,
/// take the footer color and a shadow, and keep both when a list scrolls
/// under it. Snackbars float, as in the Material 3 spec.
ThemeData _theme(Color seed, Brightness brightness) {
  final t = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: seedVariant(seed),
    ),
  );
  return t.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: footerColor(t),
      // Same elevation scrolled or not; M3 leaves the shadow transparent and
      // tints the color with elevation, so both are set by hand.
      elevation: 2,
      scrolledUnderElevation: 2,
      shadowColor: t.colorScheme.shadow,
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

/// Monochrome for a gray seed, tonal spot otherwise. A monochrome system
/// style hands over a pure gray wallpaper primary, and tonal spot would force
/// chroma onto its arbitrary hue (teal). Fixed palettes are never gray.
DynamicSchemeVariant seedVariant(Color seed) {
  final c = [seed.r, seed.g, seed.b];
  final spread = c.reduce(math.max) - c.reduce(math.min);
  return spread < 0.03
      ? DynamicSchemeVariant.monochrome
      : DynamicSchemeVariant.tonalSpot;
}

/// App bar, status bar, Home's footer and the system navigation bar.
Color footerColor(ThemeData theme) => theme.colorScheme.surfaceContainerHigh;

/// One row of a list screen (Home, Settings). Clipped so the ripple keeps
/// the corners.
Widget rowCard(Widget tile) => Card(
  margin: const EdgeInsets.only(bottom: 8),
  clipBehavior: Clip.antiAlias,
  child: tile,
);

/// Footer with the screen's controls: footer color, the AppBar's elevation 2
/// flipped upward (Material shadows fall downward and would hide under it),
/// and room for the system navigation bar. Calibration: kElevationToShadow[1]
/// for a lighter shadow.
Widget appFooter(ThemeData theme, Widget child) => DecoratedBox(
  decoration: BoxDecoration(
    boxShadow: [
      for (final s in kElevationToShadow[2]!) s.copyWith(offset: -s.offset),
    ],
  ),
  child: Material(
    color: footerColor(theme),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: child,
      ),
    ),
  ),
);

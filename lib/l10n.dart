// App language. The ASR model (Parakeet v3) covers both languages.
// Spanish when the device is in Spanish, English otherwise.
// Each string is written where it is used, as tr('español', 'English').
// ponytail: inline pairs are fine for two languages; move to gen-l10n ARB
// files if a third one is added.

/// Set in main() at launch. Plain Dart, so pure-logic
/// files and the pipeline isolate (which gets it in its request) can use it.
bool uiSpanish = false;

String tr(String es, String en) => uiSpanish ? es : en;

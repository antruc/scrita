import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrita/main.dart';

void main() {
  test('seedVariant is monochrome only for gray seeds', () {
    // Primary tone 40 of a monochrome system style: pure gray.
    expect(
      seedVariant(const Color(0xff5e5e5e)),
      DynamicSchemeVariant.monochrome,
    );
    // Neutral style, the least colorful non-gray seed (RGB spread 17).
    expect(
      seedVariant(const Color(0xff4f5a60)),
      DynamicSchemeVariant.tonalSpot,
    );
    // Fixed palettes, blueGrey being the grayest.
    expect(seedVariant(Colors.blueGrey), DynamicSchemeVariant.tonalSpot);
    expect(seedVariant(Colors.indigo), DynamicSchemeVariant.tonalSpot);
  });
}

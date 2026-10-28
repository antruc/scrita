import 'package:scrita/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('threadsFor counts big cores, capped at 4', () {
    // 2 big + 6 little (Helio G99, Snapdragon 695).
    expect(threadsFor([2000, 2000, 2000, 2000, 2000, 2000, 2200, 2200]), 2);
    // 1 prime + 5 big + 2 little (Snapdragon 8 Gen 3).
    expect(threadsFor([2300, 2300, 3150, 3150, 3150, 2960, 2960, 3300]), 4);
    // All cores equal.
    expect(threadsFor([1800, 1800]), 2);
    expect(threadsFor([1800, 1800, 1800, 1800, 1800, 1800]), 4);
  });
}

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mango_offline/fruit_line_counter.dart';

FruitLineObservation observed(
  int id,
  double coordinate, {
  bool vertical = false,
  double tangent = .3,
  String? grade,
}) => FruitLineObservation(
  trackId: id,
  box: Rect.fromCenter(
    center: vertical
        ? Offset(coordinate, tangent)
        : Offset(tangent, coordinate),
    width: .08,
    height: .08,
  ),
  grade: grade,
);

void main() {
  test('a forward crossing requires two observations beyond each margin', () {
    final counter = FruitLineCounter();
    counter.update(0, [observed(1, .4)]);
    counter.update(10, [observed(1, .42)]);
    expect(counter.update(20, [observed(1, .6)]).confirmedCount, 0);
    final result = counter.update(30, [observed(1, .61)]);
    expect(result.confirmedCount, 1);
    expect(result.ungradedCount, 1);
    expect(result.gradeCounts, isEmpty);
  });

  test('one source-side observation cannot establish a crossing', () {
    final counter = FruitLineCounter();
    counter.update(0, [observed(1, .4)]);
    counter.update(10, [observed(1, .6)]);
    expect(counter.update(20, [observed(1, .62)]).confirmedCount, 0);
  });

  test('the same ID counts once after reverse and repeated crossings', () {
    final counter = FruitLineCounter();
    for (var i = 0; i < 8; i++) {
      counter.update(i * 10, [
        observed(1, [.4, .4, .6, .6][i % 4]),
      ]);
    }
    expect(counter.summary.confirmedCount, 1);
  });

  test(
    'wrong-direction crossing and an arrival past the line do not count',
    () {
      final counter = FruitLineCounter();
      counter.update(0, [observed(1, .6), observed(2, .7)]);
      counter.update(10, [observed(1, .62), observed(2, .71)]);
      counter.update(20, [observed(1, .4), observed(2, .72)]);
      expect(
        counter.update(30, [observed(1, .38), observed(2, .73)]).confirmedCount,
        0,
      );
    },
  );

  test('dead-band jitter and tangential center-line motion do not count', () {
    final counter = FruitLineCounter();
    final coordinates = [.4, .4, .49, .51, .475, .525, .5, .5];
    for (var i = 0; i < coordinates.length; i++) {
      counter.update(i * 10, [
        observed(1, coordinates[i]),
        observed(2, .5, tangent: .1 + i * .1),
      ]);
    }
    expect(counter.summary.confirmedCount, 0);
  });

  test('returning into the dead band breaks destination confirmation', () {
    final counter = FruitLineCounter();
    final coordinates = [.4, .4, .6, .5, .6];
    for (var i = 0; i < coordinates.length; i++) {
      counter.update(i * 10, [observed(1, coordinates[i])]);
    }
    expect(counter.summary.confirmedCount, 0);
    expect(counter.update(50, [observed(1, .6)]).confirmedCount, 1);
  });

  test('vertical decreasing configuration ignores motion along the line', () {
    final counter = FruitLineCounter(
      axis: FruitLineAxis.vertical,
      position: .3,
      direction: FruitLineDirection.decreasing,
      hysteresis: .02,
    );
    final coordinates = [.4, .4, .2, .2];
    for (var i = 0; i < coordinates.length; i++) {
      counter.update(i * 10, [
        observed(1, coordinates[i], vertical: true),
        observed(2, .3, vertical: true, tangent: .2 + i * .1),
      ]);
    }
    expect(counter.summary.confirmedCount, 1);
  });

  test('multiple IDs count by crossing and unknown grade remains ungraded', () {
    final counter = FruitLineCounter();
    for (var i = 0; i < 4; i++) {
      counter.update(i * 10, [
        observed(1, i < 2 ? .4 : .6, grade: 'mango:L2'),
        observed(2, i < 2 ? .4 : .6),
        observed(3, .6, grade: 'banana:L1'),
      ]);
    }
    expect(counter.summary.confirmedCount, 2);
    expect(counter.summary.ungradedCount, 1);
    expect(counter.summary.gradeCounts, {'mango:L2': 1});
    expect(
      () => counter.summary.gradeCounts['mango:L2'] = 8,
      throwsUnsupportedError,
    );
  });

  test('counted grade is the supplied grade at crossing and remains fixed', () {
    final counter = FruitLineCounter();
    counter.update(0, [observed(1, .4, grade: 'mango:L1')]);
    counter.update(10, [observed(1, .4, grade: 'mango:L1')]);
    counter.update(20, [observed(1, .6, grade: 'mango:L2')]);
    counter.update(30, [observed(1, .6, grade: 'mango:L2')]);
    counter.update(40, [observed(1, .7, grade: 'mango:L3')]);
    expect(counter.summary.gradeCounts, {'mango:L2': 1});
    expect(counter.summary.ungradedCount, 0);
  });

  test(
    'invalid or non-increasing timestamps reject without consuming a frame',
    () {
      final counter = FruitLineCounter();
      expect(() => counter.update(-1, []), throwsArgumentError);
      counter.update(10, [observed(1, .4)]);
      expect(() => counter.update(10, [observed(1, .4)]), throwsArgumentError);
      expect(() => counter.update(9, []), throwsArgumentError);
      counter.update(20, [observed(1, .4)]);
      counter.update(30, [observed(1, .6)]);
      expect(counter.update(40, [observed(1, .6)]).confirmedCount, 1);
    },
  );

  test('invalid boxes and repeated IDs cannot confirm a crossing', () {
    final counter = FruitLineCounter();
    final invalid = [
      const Rect.fromLTRB(-.1, .1, .2, .2),
      const Rect.fromLTRB(.1, .1, 1.1, .2),
      const Rect.fromLTRB(.1, .1, .1, .2),
      const Rect.fromLTRB(double.nan, .1, .2, .2),
    ];
    for (final box in invalid) {
      expect(
        () => counter.update(0, [FruitLineObservation(trackId: 1, box: box)]),
        throwsArgumentError,
      );
    }
    expect(() => counter.update(0, [observed(0, .4)]), throwsArgumentError);
    expect(
      () => counter.update(0, [observed(1, .4), observed(1, .4)]),
      throwsArgumentError,
    );
    counter.update(0, [observed(1, .4)]);
    counter.update(10, [observed(1, .4)]);
    counter.update(20, [observed(1, .6)]);
    expect(counter.update(30, [observed(1, .6)]).confirmedCount, 1);
  });

  test('bounded history fails closed and reset permits a new session', () {
    final counter = FruitLineCounter(maxTrackHistory: 1);
    counter.update(0, [observed(1, .4)]);
    counter.update(10, [observed(1, .4)]);
    counter.update(20, [observed(1, .6)]);
    counter.update(30, [observed(1, .6)]);
    expect(() => counter.update(40, [observed(2, .4)]), throwsStateError);
    expect(counter.update(40, [observed(1, .7)]).confirmedCount, 1);
    counter.reset();
    expect(counter.summary.confirmedCount, 0);
    expect(counter.summary.ungradedCount, 0);
    expect(counter.summary.gradeCounts, isEmpty);
    counter.update(0, [observed(1, .4)]);
    counter.update(10, [observed(1, .4)]);
    counter.update(20, [observed(1, .6)]);
    expect(counter.update(30, [observed(1, .6)]).confirmedCount, 1);
  });

  test('history overflow rejects the entire frame before any crossing', () {
    final counter = FruitLineCounter(maxTrackHistory: 1);
    counter.update(0, [observed(1, .4)]);
    counter.update(10, [observed(1, .4)]);
    counter.update(20, [observed(1, .6)]);
    expect(
      () => counter.update(30, [observed(1, .6), observed(2, .4)]),
      throwsStateError,
    );
    expect(counter.summary.confirmedCount, 0);
    expect(counter.update(30, [observed(1, .6)]).confirmedCount, 1);
  });

  test('invalid line configuration fails before accepting observations', () {
    for (final position in [double.nan, -.1, 0.0, 1.0, 1.1]) {
      expect(() => FruitLineCounter(position: position), throwsArgumentError);
    }
    for (final hysteresis in [double.nan, -.01, .5, .6]) {
      expect(
        () => FruitLineCounter(hysteresis: hysteresis),
        throwsArgumentError,
      );
    }
    expect(() => FruitLineCounter(maxTrackHistory: 0), throwsArgumentError);
    expect(
      () => FruitLineCounter(position: .05, hysteresis: .1),
      throwsArgumentError,
    );
  });
}

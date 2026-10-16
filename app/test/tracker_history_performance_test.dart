import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mango_offline/fruit_tracking.dart';

List<FruitObservation> _grid(int length, {int grade = 0}) => [
  for (var index = 0; index < length; index++)
    FruitObservation(
      box: Rect.fromLTWH(.01 + index % 8 * .12, .01 + index ~/ 8 * .12, .1, .1),
      species: 'mango',
      classId: grade,
      confidence: .9,
    ),
];

// Every group is confirmed twice, then expires before the next group. This
// exercises the real 10,000-ID production limit, not fabricated tracker state.
int _fillConfirmedHistory(FruitTracker tracker) {
  var timestamp = 0;
  for (var group = 0; group < 157; group++) {
    final observations = _grid(group == 156 ? 16 : 64);
    tracker.update(timestamp, observations);
    tracker.update(timestamp + 1, observations);
    timestamp += 3000;
  }
  return timestamp;
}

int _emptyFrameMicros(FruitTracker tracker, int start) {
  final watch = Stopwatch()..start();
  for (var frame = 0; frame < 4000; frame++) {
    tracker.update(start + frame, const []);
  }
  return watch.elapsedMicroseconds;
}

int _median(List<int> values) => (values..sort())[values.length ~/ 2];

void main() {
  // Reintroducing a scan of all expired identities makes late empty frames
  // scale with the entire session rather than the current active scene.
  test('expired 10000-ID history does not dominate empty-frame processing', () {
    final full = FruitTracker();
    var timestamp = _fillConfirmedHistory(full);
    expect(full.summary.confirmedCount, 10000);
    expect(full.summary.gradeCounts, {'mango:L0': 10000});
    final fresh = FruitTracker();
    final fullTimes = <int>[];
    final freshTimes = <int>[];
    // Warm both code paths; use paired, median batches to reduce timer noise.
    _emptyFrameMicros(full, timestamp);
    _emptyFrameMicros(fresh, timestamp);
    timestamp += 4000;
    for (var sample = 0; sample < 5; sample++) {
      freshTimes.add(_emptyFrameMicros(fresh, timestamp));
      fullTimes.add(_emptyFrameMicros(full, timestamp));
      timestamp += 4000;
    }
    final fullMicros = _median(fullTimes);
    final freshMicros = _median(freshTimes).clamp(1, 1 << 53);
    debugPrint(
      'Tracker 4000 empty-frame median: historical=$fullMicros us, '
      'fresh=$freshMicros us, ratio=${fullMicros / freshMicros}',
    );
    // This is a relative algorithmic-growth check, not a phone FPS target.
    expect(
      fullMicros / freshMicros,
      lessThan(6),
      reason:
          '4000 empty frames: historical=$fullMicros us, '
          'fresh=$freshMicros us; expired IDs must not be visited every frame.',
    );
    // Optimizing current matching must not erase historical production counts.
    expect(full.summary.confirmedCount, 10000);
    expect(full.summary.gradeCounts, {'mango:L0': 10000});
  });

  test(
    'expiry retains grade votes and does not revive an expired identity',
    () {
      final tracker = FruitTracker();
      final first = tracker.update(0, _grid(1)).single;
      tracker.update(1, _grid(1));
      tracker.update(3000, const []);
      expect(tracker.summary.confirmedCount, 1);
      expect(tracker.summary.gradeCounts, {'mango:L0': 1});
      final second = tracker.update(3001, _grid(1, grade: 1)).single;
      expect(second.id, isNot(first.id));
      tracker.update(3002, _grid(1, grade: 1));
      expect(tracker.summary.confirmedCount, 2);
      expect(tracker.summary.gradeCounts, {'mango:L0': 1, 'mango:L1': 1});
      tracker.reset();
      expect(tracker.summary.confirmedCount, 0);
      expect(tracker.update(0, _grid(1)).single.id, 1);
    },
  );
}

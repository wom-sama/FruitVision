import 'dart:ui';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mango_offline/fruit_tracking.dart';

FruitObservation fruit(double x, {int? grade = 2}) => FruitObservation(
  box: Rect.fromLTWH(x, .2, .15, .2),
  classId: grade,
  confidence: grade == null ? null : .9,
  species: 'mango',
);

void main() {
  test(
    '32 fruit identities survive reordered dense frames and grade changes',
    () {
      FruitObservation grid(int i, int frame) => FruitObservation(
        box: Rect.fromLTWH(
          .02 + (i % 8) * .12 + frame * .0001,
          .02 + (i ~/ 8) * .23,
          .1,
          .18,
        ),
        classId: frame % 2,
        confidence: .9,
        species: frame % 2 == 0 ? 'mango' : 'banana',
      );
      final tracker = FruitTracker();
      final ids = tracker
          .update(0, [for (var i = 0; i < 32; i++) grid(i, 0)])
          .map((t) => t.id)
          .toList();
      for (var frame = 1; frame <= 30; frame++) {
        final order = [for (var i = 0; i < 32; i++) (i + frame) % 32];
        final tracks = tracker.update(frame * 34, [
          for (final i in order) grid(i, frame),
        ]);
        expect(tracks.map((t) => t.id), [for (final i in order) ids[i]]);
        expect(tracks.map((t) => t.id).toSet().length, 32);
        expect(tracker.summary.confirmedCount, 32);
      }
    },
  );

  test('unmatched arrivals do not steal expired or distant identities', () {
    final tracker = FruitTracker();
    final original = tracker.update(0, [fruit(.1), fruit(.6)]);
    tracker.update(100, [fruit(.1), fruit(.6)]);
    expect(
      tracker.update(200, [fruit(.35)]).single.id,
      isNot(isIn(original.map((t) => t.id))),
    );
    tracker.update(300, [fruit(.35)]);
    expect(tracker.summary.confirmedCount, 3);
    final fresh = tracker.update(3000, [fruit(.1)]).single;
    expect(fresh.id, 4);
    expect(tracker.summary.confirmedCount, 3);
  });

  test('adjacent overlapping choices do not create a third identity when two matches exist', () {
    FruitObservation box(double x) =>
        FruitObservation(box: Rect.fromLTWH(x, .2, .2, .2));
    final tracker = FruitTracker();
    final firstIds = tracker
        .update(0, [box(.2), box(.35)])
        .map((t) => t.id)
        .toList();
    // Best individual overlap A->C blocks B entirely. The feasible assignment
    // A->D and B->C retains both identities; no new physical fruit arrived.
    final moved = tracker.update(100, [box(.25), box(.1)]);
    expect(moved.map((t) => t.id), [firstIds[1], firstIds[0]]);
    tracker.update(200, [box(.25), box(.1)]);
    expect(tracker.summary.confirmedCount, 2);
  });

  for (final name in ['full_video_trace.json', 'full_video_int8_trace.json']) {
    test(
      '$name: original 28-frame Android trace counts the two fruit encounters',
      () {
        final trace = jsonDecode(
          File('test/fixtures/$name').readAsStringSync(),
        ) as Map<String, dynamic>;
        final tracker = FruitTracker();
        for (final frame in trace['records'] as List) {
          tracker.update(frame['timestampMs'] as int, [
            for (final object in frame['objects'] as List)
              FruitObservation(
                box: Rect.fromLTRB(
                  (object['box'][0] as num).toDouble(),
                  (object['box'][1] as num).toDouble(),
                  (object['box'][2] as num).toDouble(),
                  (object['box'][3] as num).toDouble(),
                ),
                classId: object['status'] == 'OK'
                    ? object['classId'] as int
                    : null,
                confidence: object['status'] == 'OK'
                    ? (object['probabilities'][object['classId']] as num)
                          .toDouble()
                    : null,
                species: object['species'] as String,
              ),
          ]);
        }
        expect((trace['records'] as List).length, 28);
        expect(tracker.summary.confirmedCount, 2);
        // Species labels remain a known model error; never relabel these as mango.
        if (name == 'full_video_trace.json') {
          expect(tracker.summary.gradeCounts, {'banana:L1': 2});
        }
        expect(
          tracker.summary.gradeCounts.values.fold<int>(0, (a, b) => a + b),
          2,
        );
      },
    );
  }
  test('one stationary fruit in many frames counts once, not per frame', () {
    final tracker = FruitTracker();
    for (var i = 0; i < 10; i++) {
      tracker.update(i * 500, [fruit(.1)]);
    }
    expect(tracker.summary.confirmedCount, 1);
    expect(tracker.summary.gradeCounts, {'mango:L2': 1});
  });
  test('reordered detections retain identities and count two fruits', () {
    final tracker = FruitTracker();
    final first = tracker.update(0, [fruit(.1), fruit(.6)]);
    final next = tracker.update(500, [fruit(.6), fruit(.1)]);
    expect(next.map((v) => v.id), [first[1].id, first[0].id]);
    expect(tracker.summary.confirmedCount, 2);
  });
  test('brief missed detection recovers the same identity', () {
    final tracker = FruitTracker();
    final first = tracker.update(0, [fruit(.1)]).single;
    tracker.update(500, []);
    final next = tracker.update(1000, [fruit(.11)]).single;
    expect(next.id, first.id);
    expect(tracker.summary.confirmedCount, 1);
  });
  test('one-frame false detection is not confirmed production', () {
    final tracker = FruitTracker();
    tracker.update(0, [fruit(.1)]);
    tracker.update(3000, []);
    expect(tracker.summary.confirmedCount, 0);
  });
  test('stopped fruit after a missed frame retains its identity', () {
    final tracker = FruitTracker();
    final first = tracker.update(0, [fruit(.10)]).single;
    tracker.update(500, [fruit(.16)]);
    tracker.update(1000, []);
    final recovered = tracker.update(2000, [fruit(.16)]).single;
    expect(recovered.id, first.id);
    tracker.update(2500, [fruit(.16)]);
    expect(tracker.summary.confirmedCount, 1);
  });
  test('ungraded fruit is counted separately and never gets a fake class', () {
    final tracker = FruitTracker();
    tracker.update(0, [fruit(.1, grade: null)]);
    tracker.update(500, [fruit(.1, grade: null)]);
    expect(tracker.summary.confirmedCount, 1);
    expect(tracker.summary.ungradedCount, 1);
    expect(tracker.summary.gradeCounts, isEmpty);
  });
  test('repeated timestamp cannot confirm a duplicated callback', () {
    final tracker = FruitTracker();
    tracker.update(0, [fruit(.1)]);
    expect(() => tracker.update(0, [fruit(.1)]), throwsArgumentError);
  });
  test('reset starts a new video with zero production', () {
    final tracker = FruitTracker();
    tracker.update(0, [fruit(.1)]);
    tracker.update(500, [fruit(.1)]);
    tracker.reset();
    expect(tracker.summary.confirmedCount, 0);
    expect(tracker.update(0, [fruit(.6)]).single.id, 1);
  });
}

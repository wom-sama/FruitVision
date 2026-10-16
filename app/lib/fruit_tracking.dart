import 'dart:math' as math;
import 'dart:ui';

/// A model observation; class numbers retain their species-specific meaning.
class FruitObservation {
  const FruitObservation({
    required this.box,
    this.classId,
    this.confidence,
    this.species,
  });
  final Rect box;
  final int? classId;
  final double? confidence;
  final String? species;
}

class FruitTrack {
  FruitTrack(this.id, this.box, this.lastSeenMs);
  final int id;
  Rect box;
  int lastSeenMs;
  int observations = 1;
  double vx = 0, vy = 0;
  final Map<String, double> _votes = {};
  String? get grade => _votes.isEmpty
      ? null
      : _votes.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
}

class FruitCountSummary {
  const FruitCountSummary(
    this.confirmedCount,
    this.ungradedCount,
    this.gradeCounts,
  );
  final int confirmedCount;
  final int ungradedCount;
  final Map<String, int> gradeCounts;
}

/// Lightweight geometry tracking, not physical-object re-identification.
/// Long occlusion, re-entry and moving-camera videos can still over/undercount.
class FruitTracker {
  FruitTracker({this.maxGapMs = 2000, this.minimumObservations = 2});
  final int maxGapMs;
  final int minimumObservations;
  // History owns production counts/votes. Only recent identities participate
  // in matching, so an expired 10k-ID session does not cost 10k scans/frame.
  final Map<int, FruitTrack> _tracks = {};
  final Map<int, FruitTrack> _activeTracks = {};
  int _nextId = 1;
  int? _lastTimestamp;

  void reset() {
    _tracks.clear();
    _activeTracks.clear();
    _nextId = 1;
    _lastTimestamp = null;
  }

  FruitCountSummary get summary {
    final confirmed = _tracks.values.where(
      (t) => t.observations >= minimumObservations,
    );
    final counts = <String, int>{};
    var total = 0, ungraded = 0;
    for (final track in confirmed) {
      total++;
      final grade = track.grade;
      if (grade == null) {
        ungraded++;
      } else {
        counts.update(grade, (v) => v + 1, ifAbsent: () => 1);
      }
    }
    return FruitCountSummary(total, ungraded, Map.unmodifiable(counts));
  }

  List<FruitTrack> update(
    int timestampMs,
    List<FruitObservation> observations,
  ) {
    if (timestampMs < 0 ||
        (_lastTimestamp != null && timestampMs <= _lastTimestamp!)) {
      throw ArgumentError('Frame timestamps must increase');
    }
    for (final value in observations) {
      final b = value.box;
      if (![
            b.left,
            b.top,
            b.right,
            b.bottom,
          ].every((v) => v.isFinite && v >= 0 && v <= 1) ||
          b.isEmpty ||
          (value.classId != null &&
              (value.classId! < 0 || value.confidence == null)) ||
          (value.confidence != null &&
              (!value.confidence!.isFinite ||
                  value.confidence! < 0 ||
                  value.confidence! > 1))) {
        throw ArgumentError('Invalid fruit observation');
      }
    }
    _lastTimestamp = timestampMs;
    _activeTracks.removeWhere(
      (_, track) => timestampMs - track.lastSeenMs > maxGapMs,
    );
    final active = _activeTracks.values.toList();
    final scores = [
      for (final observation in observations)
        [
          for (final track in active)
            math.max(
              _iou(
                track.box.translate(
                  track.vx * (timestampMs - track.lastSeenMs),
                  track.vy * (timestampMs - track.lastSeenMs),
                ),
                observation.box,
              ),
              _iou(track.box, observation.box),
            ),
        ],
    ];
    // Keep the previous motion/stopped-fruit gate, but choose matches jointly.
    // Greedy IoU can steal another track's only match and invent a third fruit.
    final matches = _jointAssignment(scores, active.length);
    final assigned = <int, FruitTrack>{};
    for (var i = 0; i < matches.length; i++) {
      final index = matches[i];
      if (index == null) continue;
      final track = active[index];
      final observation = observations[i];
      final elapsed = timestampMs - track.lastSeenMs;
      track.vx = (observation.box.center.dx - track.box.center.dx) / elapsed;
      track.vy = (observation.box.center.dy - track.box.center.dy) / elapsed;
      track.box = observation.box;
      track.lastSeenMs = timestampMs;
      track.observations++;
      assigned[i] = track;
    }
    for (var i = 0; i < observations.length; i++) {
      final observation = observations[i];
      final track =
          assigned[i] ?? FruitTrack(_nextId++, observation.box, timestampMs);
      if (_tracks.length >= 10000 && !_tracks.containsKey(track.id)) {
        throw StateError('Track history limit reached; split the video');
      }
      _tracks[track.id] = track;
      _activeTracks[track.id] = track;
      assigned[i] = track;
      if (observation.classId != null && observation.confidence! >= .6) {
        final key = '${observation.species ?? 'fruit'}:L${observation.classId}';
        track._votes.update(
          key,
          (v) => v + observation.confidence!,
          ifAbsent: () => observation.confidence!,
        );
      }
    }
    return List.unmodifiable([
      for (var i = 0; i < observations.length; i++) assigned[i]!,
    ]);
  }

  static double _iou(Rect a, Rect b) {
    final overlap = a.intersect(b);
    final intersection =
        math.max(0.0, overlap.width) * math.max(0.0, overlap.height);
    final union = a.width * a.height + b.width * b.height - intersection;
    return union <= 0 ? 0 : intersection / union;
  }

  /// Rectangular minimum-cost assignment with unmatched dummy columns.
  /// Maximize valid match count first, then total IoU. No species/grade gating:
  /// a changing classification must not manufacture a new fruit identity.
  static List<int?> _jointAssignment(List<List<double>> scores, int tracks) {
    final count = scores.length;
    final result = List<int?>.filled(count, null);
    if (count == 0 || tracks == 0) return result;
    final columns = [
      for (var j = 0; j < tracks; j++)
        if (scores.any((row) => row[j] >= .2)) j,
    ];
    if (columns.isEmpty) return result;
    final m = columns.length + count;
    final u = List<double>.filled(count + 1, 0);
    final v = List<double>.filled(m + 1, 0);
    final p = List<int>.filled(m + 1, 0);
    final way = List<int>.filled(m + 1, 0);
    double cost(int i, int j) {
      if (j >= columns.length) return 0;
      final score = scores[i][columns[j]];
      return score >= .2 ? -(count + 1 + score) : 1e6;
    }

    for (var i = 1; i <= count; i++) {
      p[0] = i;
      var j0 = 0;
      final minimum = List<double>.filled(m + 1, double.infinity);
      final used = List<bool>.filled(m + 1, false);
      do {
        used[j0] = true;
        final i0 = p[j0];
        var delta = double.infinity, j1 = 0;
        for (var j = 1; j <= m; j++) {
          if (used[j]) continue;
          final current = cost(i0 - 1, j - 1) - u[i0] - v[j];
          if (current < minimum[j]) {
            minimum[j] = current;
            way[j] = j0;
          }
          if (minimum[j] < delta) {
            delta = minimum[j];
            j1 = j;
          }
        }
        for (var j = 0; j <= m; j++) {
          if (used[j]) {
            u[p[j]] += delta;
            v[j] -= delta;
          } else {
            minimum[j] -= delta;
          }
        }
        j0 = j1;
      } while (p[j0] != 0);
      do {
        final next = way[j0];
        p[j0] = p[next];
        j0 = next;
      } while (j0 != 0);
    }
    for (var j = 1; j <= columns.length; j++) {
      if (p[j] != 0 && scores[p[j] - 1][columns[j - 1]] >= .2) {
        result[p[j] - 1] = columns[j - 1];
      }
    }
    return result;
  }
}

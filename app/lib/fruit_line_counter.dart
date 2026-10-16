import 'dart:ui';

import 'fruit_tracking.dart' show FruitCountSummary;

enum FruitLineAxis { horizontal, vertical }

/// Increasing means top-to-bottom or left-to-right in image coordinates.
enum FruitLineDirection { increasing, decreasing }

/// A current observation of an already confirmed tracker identity.
class FruitLineObservation {
  const FruitLineObservation({
    required this.trackId,
    required this.box,
    this.grade,
  });

  final int trackId;
  final Rect box;

  /// A qualified known stage, for example `mango:L2`; unknown must be null.
  /// The counter does not infer maturity, species or grade from geometry.
  final String? grade;
}

/// Counts confirmed IDs crossing a fixed image line in one direction.
///
/// Two consecutive observations beyond the hysteresis margin establish each
/// side. Observations within the band break confirmation, without erasing the
/// last established side. A track first observed past the line is not counted.
/// Each ID counts at most once until [reset], including after it disappears.
///
/// This is not physical-object re-identification: replacement IDs after long
/// occlusion or re-entry can still double-count. The camera and line must remain
/// fixed relative to the conveyor; a moving camera invalidates line crossings.
class FruitLineCounter {
  FruitLineCounter({
    this.axis = FruitLineAxis.horizontal,
    this.position = .5,
    this.direction = FruitLineDirection.increasing,
    this.hysteresis = .025,
    this.maxTrackHistory = 10000,
  }) {
    if (!position.isFinite ||
        position <= 0 ||
        position >= 1 ||
        !hysteresis.isFinite ||
        hysteresis < 0 ||
        position - hysteresis <= 0 ||
        position + hysteresis >= 1 ||
        maxTrackHistory <= 0) {
      throw ArgumentError('Invalid line counter configuration');
    }
  }

  final FruitLineAxis axis;
  final double position;
  final FruitLineDirection direction;
  final double hysteresis;

  /// History is retained to prevent recounting IDs; overflow requires reset.
  /// Entries are never silently evicted, which would permit double counting.
  final int maxTrackHistory;

  final Map<int, _LineTrack> _history = {};
  final Map<String, int> _gradeCounts = {};
  int? _lastTimestamp;
  int _count = 0;
  int _ungraded = 0;

  FruitCountSummary get summary =>
      FruitCountSummary(_count, _ungraded, Map.unmodifiable(_gradeCounts));

  /// Accepts only confirmed identities and normalized, nonempty rectangles.
  /// Invalid input or history overflow rejects the entire frame atomically.
  FruitCountSummary update(
    int timestampMs,
    List<FruitLineObservation> observations,
  ) {
    if (timestampMs < 0 ||
        (_lastTimestamp != null && timestampMs <= _lastTimestamp!)) {
      throw ArgumentError('Frame timestamps must increase');
    }
    final ids = <int>{};
    var arrivals = 0;
    for (final observation in observations) {
      final box = observation.box;
      if (observation.trackId <= 0 ||
          !ids.add(observation.trackId) ||
          box.isEmpty ||
          ![
            box.left,
            box.top,
            box.right,
            box.bottom,
          ].every((value) => value.isFinite && value >= 0 && value <= 1)) {
        throw ArgumentError('Invalid confirmed fruit observation');
      }
      if (!_history.containsKey(observation.trackId)) arrivals++;
    }
    if (_history.length + arrivals > maxTrackHistory) {
      throw StateError('Line counter history limit reached; reset the session');
    }

    _lastTimestamp = timestampMs;
    for (final observation in observations) {
      final track = _history.putIfAbsent(observation.trackId, _LineTrack.new);
      if (track.counted) continue;
      final coordinate = axis == FruitLineAxis.horizontal
          ? observation.box.center.dy
          : observation.box.center.dx;
      final side = coordinate < position - hysteresis
          ? -1
          : coordinate > position + hysteresis
          ? 1
          : 0;
      if (side == 0) {
        track.candidateSide = 0;
        track.observationsOnSide = 0;
        continue;
      }
      if (track.candidateSide != side) {
        track.candidateSide = side;
        track.observationsOnSide = 1;
        continue;
      }
      if (track.observationsOnSide < 2) track.observationsOnSide++;
      if (track.observationsOnSide < 2 || track.stableSide == side) continue;
      final sourceSide = direction == FruitLineDirection.increasing ? -1 : 1;
      if (track.stableSide == sourceSide && side == -sourceSide) {
        track.counted = true;
        _count++;
        final grade = observation.grade;
        if (grade == null) {
          _ungraded++;
        } else {
          _gradeCounts.update(grade, (value) => value + 1, ifAbsent: () => 1);
        }
      }
      track.stableSide = side;
    }
    return summary;
  }

  /// Starts a new counting session, allowing the tracker to restart its IDs.
  void reset() {
    _history.clear();
    _gradeCounts.clear();
    _lastTimestamp = null;
    _count = 0;
    _ungraded = 0;
  }
}

class _LineTrack {
  int stableSide = 0;
  int candidateSide = 0;
  int observationsOnSide = 0;
  bool counted = false;
}

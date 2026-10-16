import 'package:flutter_test/flutter_test.dart';
import 'package:mango_offline/inference.dart';

void main() {
  test('a complete 64-fruit direct scene is retained rather than rejected or truncated', () {
    final rows = List.generate(
      64,
      (i) => <String, Object?>{
        'box': [(i % 8) / 8, (i ~/ 8) / 8, (i % 8) / 8 + .1, (i ~/ 8) / 8 + .1],
        'detectionScore': .9,
        'classId': 0,
        'probabilities': [.5, .5],
        'gradeScheme': 'source_two_stage',
        'species': 'mango',
        'graded': true,
        'status': 'UNCERTAIN',
      },
    );
    expect(
      SceneObject.listFromMap({
        'gradeScheme': 'source_two_stage',
        'objects': rows,
      })!.length,
      64,
    );
    expect(
      () => SceneObject.listFromMap({
        'gradeScheme': 'source_two_stage',
        'objects': [...rows, rows[0]],
      }),
      throwsFormatException,
    );
  });
}

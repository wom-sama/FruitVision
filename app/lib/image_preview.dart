import 'dart:io';

import 'package:flutter/material.dart';

import 'inference.dart';
import 'fruit_line_counter.dart';
import 'counting_line_controls.dart';

Rect mapNormalizedBox(Rect normalized, Size imageSize, Size canvasSize) {
  final fit = applyBoxFit(BoxFit.contain, imageSize, canvasSize);
  final photo = Alignment.center.inscribe(
    fit.destination,
    Offset.zero & canvasSize,
  );
  return Rect.fromLTRB(
    photo.left + normalized.left * photo.width,
    photo.top + normalized.top * photo.height,
    photo.left + normalized.right * photo.width,
    photo.top + normalized.bottom * photo.height,
  );
}

/// Resolves a bounded preview and maps original-image coordinates into BoxFit.contain.
class MangoImagePreview extends StatefulWidget {
  const MangoImagePreview({
    super.key,
    required this.path,
    required this.version,
    this.box,
    this.label,
    this.objects,
    this.countingLine,
  });
  final String path;
  final int version;
  final Rect? box;
  final String? label;
  final List<SceneObject>? objects;
  final FruitLineCounter? countingLine;

  @override
  State<MangoImagePreview> createState() => _MangoImagePreviewState();
}

class _MangoImagePreviewState extends State<MangoImagePreview> {
  ImageProvider? _provider;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  Size? _imageSize;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MangoImagePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path || oldWidget.version != widget.version) {
      _release();
      _load();
    }
  }

  void _load() {
    _imageSize = null;
    _provider = ResizeImage(
      _VersionedFileImage(File(widget.path), widget.version),
      width: 1080,
      height: 1080,
      policy: ResizeImagePolicy.fit,
    );
    final stream = _provider!.resolve(ImageConfiguration.empty);
    _listener = ImageStreamListener(
      (info, synchronous) {
        final size = Size(
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        );
        info.dispose();
        if (!mounted) return;
        if (synchronous) {
          _imageSize = size;
        } else {
          setState(() => _imageSize = size);
        }
      },
      onError: (Object error, StackTrace? stack) {
        // The Image widget below renders the visible decoding error.
      },
    );
    _stream = stream;
    stream.addListener(_listener!);
  }

  void _release() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _provider?.evict();
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Image(
        image: _provider!,
        fit: BoxFit.contain,
        gaplessPlayback: false,
        errorBuilder: (context, error, stackTrace) => const Center(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              'Không mở được ảnh xem trước.\nHãy chọn lại ảnh hoặc video.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, height: 1.5),
            ),
          ),
        ),
      ),
      if (_imageSize != null && widget.objects != null)
        IgnorePointer(
          child: CustomPaint(
            painter: MangoObjectsPainter(
              objects: widget.objects!,
              imageSize: _imageSize!,
            ),
          ),
        )
      else if (_imageSize != null && widget.box != null)
        IgnorePointer(
          child: CustomPaint(
            painter: MangoBoxPainter(
              normalizedBox: widget.box!,
              imageSize: _imageSize!,
              label: widget.label ?? 'Vùng quả',
            ),
          ),
        ),
      if (_imageSize != null && widget.countingLine != null)
        IgnorePointer(
          child: CustomPaint(
            painter: CountingLinePainter(
              line: widget.countingLine!,
              imageSize: _imageSize!,
            ),
          ),
        ),
    ],
  );
}

// Native previews reuse a file path. Version participates in the cache key so
// the current frame cannot resolve to a previous frame's decoded image.
class _VersionedFileImage extends FileImage {
  const _VersionedFileImage(super.file, this.version);
  final int version;

  @override
  bool operator ==(Object other) =>
      other is _VersionedFileImage &&
      file.path == other.file.path &&
      scale == other.scale &&
      version == other.version;

  @override
  int get hashCode => Object.hash(file.path, scale, version);
}

class MangoBoxPainter extends CustomPainter {
  const MangoBoxPainter({
    required this.normalizedBox,
    required this.imageSize,
    required this.label,
    this.color = const Color(0xFFFFD267),
  });
  final Rect normalizedBox;
  final Size imageSize;
  final String label;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final box = mapNormalizedBox(normalizedBox, imageSize, size);
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, const Radius.circular(8)),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    final text = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: Color(0xFF132C47),
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: (size.width - 16).clamp(0, double.infinity));
    final x = box.left
        .clamp(4.0, (size.width - text.width - 16).clamp(4, double.infinity))
        .toDouble();
    final y = (box.top - text.height - 12)
        .clamp(4.0, (size.height - text.height - 12).clamp(4, double.infinity))
        .toDouble();
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, text.width + 12, text.height + 8),
        const Radius.circular(6),
      ),
      Paint()..color = color,
    );
    text.paint(canvas, Offset(x + 6, y + 4));
    text.dispose();
  }

  @override
  bool shouldRepaint(MangoBoxPainter oldDelegate) =>
      oldDelegate.normalizedBox != normalizedBox ||
      oldDelegate.imageSize != imageSize ||
      oldDelegate.label != label ||
      oldDelegate.color != color;
}

class MangoObjectsPainter extends CustomPainter {
  const MangoObjectsPainter({required this.objects, required this.imageSize});
  final List<SceneObject> objects;
  final Size imageSize;

  @override
  void paint(Canvas canvas, Size size) {
    for (var index = 0; index < objects.length; index++) {
      final object = objects[index];
      MangoBoxPainter(
        normalizedBox: object.box,
        imageSize: imageSize,
        label:
            '${index + 1}'
            '${object.probabilities.length == 2 || object.species == null ? '' : ' · ${speciesLabel(object.species!)}'}'
            '${object.graded ? ' · L${object.classId}${object.status == AnalysisStatus.uncertain ? ' ?' : ''}' : ' · Chưa hỗ trợ'}',
        color: object.graded
            ? const [
                Color(0xFFFFD267),
                Color(0xFF86E0D1),
                Color(0xFF95CCFF),
                Color(0xFFFFB483),
                Color(0xFFFF9FAF),
              ][object.classId!]
            : const Color(0xFFA8BAD3),
      ).paint(canvas, size);
    }
  }

  @override
  bool shouldRepaint(MangoObjectsPainter oldDelegate) =>
      oldDelegate.imageSize != imageSize || oldDelegate.objects != objects;
}

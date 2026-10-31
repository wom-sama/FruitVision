import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../secret_messaging.dart';
import 'secret_scope.dart';

class PhotoViewerPage extends StatefulWidget {
  const PhotoViewerPage({
    super.key,
    required this.bytes,
    this.title = 'Hình ảnh',
    this.secret = false,
  });
  final Uint8List bytes;
  final String title;
  final bool secret;
  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage>
    with WidgetsBindingObserver {
  late final ImageProvider _image = ResizeImage(
    MemoryImage(widget.bytes),
    width: 2048,
    height: 2048,
    policy: ResizeImagePolicy.fit,
  );
  SecretMessaging? _messaging;
  bool _locked = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final messaging = widget.secret ? SecretScope.maybeOf(context) : null;
    if (messaging != _messaging) {
      _messaging?.removeListener(_clear);
      _messaging = messaging;
      _messaging?.addListener(_clear);
    }
  }

  void _clear() {
    if (!widget.secret || _locked) return;
    widget.bytes.fillRange(0, widget.bytes.length, 0);
    unawaited(_image.evict());
    if (mounted) setState(() => _locked = true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _clear();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messaging?.removeListener(_clear);
    if (widget.secret) {
      unawaited(_image.evict());
      widget.bytes.fillRange(0, widget.bytes.length, 0);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: SafeArea(
      child: Center(
        child: _locked
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Ảnh mã hóa đã đóng. Quay lại hội thoại và xác minh khóa để mở lại.',
                ),
              )
            : InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Image(
                  image: _image,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Không mở được ảnh này.'),
                  ),
                ),
              ),
      ),
    ),
  );
}

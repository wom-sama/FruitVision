import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/material.dart';

import 'components.dart';
import 'photo_viewer.dart';
import '../secret_messaging.dart';
import 'secret_scope.dart';

class ApiPhoto extends StatefulWidget {
  const ApiPhoto({
    super.key,
    required this.load,
    this.title = 'Ảnh bài viết',
    this.viewportBound = false,
    this.secret = false,
  });
  final Future<Uint8List> Function() load;
  final String title;
  final bool viewportBound;
  final bool secret;
  @override
  State<ApiPhoto> createState() => _ApiPhotoState();
}

class _ApiPhotoState extends State<ApiPhoto> with WidgetsBindingObserver {
  Uint8List? _bytes;
  bool _loading = true;
  String? _error;
  ScrollPosition? _scroll;
  ImageProvider? _provider;
  int _generation = 0;
  bool _scheduled = false;
  bool _locked = false;
  SecretMessaging? _messaging;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!widget.viewportBound) {
      _load();
    } else {
      _loading = false;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final messaging = widget.secret ? SecretScope.maybeOf(context) : null;
    if (messaging != _messaging) {
      _messaging?.removeListener(_clearSecret);
      _messaging = messaging;
      _messaging?.addListener(_clearSecret);
    }
    if (!widget.viewportBound) return;
    final position = Scrollable.maybeOf(context)?.position;
    if (position != _scroll) {
      _scroll?.removeListener(_schedule);
      _scroll = position;
      _scroll?.addListener(_schedule);
    }
    _schedule();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || _locked) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final bounds = box.localToGlobal(Offset.zero) & box.size,
          viewport = Rect.fromLTWH(
            0,
            0,
            MediaQuery.sizeOf(context).width,
            MediaQuery.sizeOf(context).height,
          );
      if (bounds.overlaps(viewport)) {
        if (_bytes == null && !_loading && _error == null) unawaited(_load());
      } else if (_bytes != null || _loading) {
        _generation++;
        _dropBytes();
        setState(() {
          _bytes = null;
          _loading = false;
        });
      }
    });
  }

  void _dropBytes() {
    final bytes = _bytes, provider = _provider;
    _bytes = null;
    _provider = null;
    if (widget.secret && bytes != null) bytes.fillRange(0, bytes.length, 0);
    if (provider != null) unawaited(provider.evict());
  }

  void _clearSecret() {
    if (!widget.secret || _locked) return;
    _generation++;
    _locked = true;
    _dropBytes();
    if (mounted) {
      setState(() {
        _loading = false;
        _error = null;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _clearSecret();
  }

  Future<void> _openPhoto() async {
    final bytes = _bytes;
    if (bytes == null || _locked) return;
    final zoomBytes = widget.secret ? Uint8List.fromList(bytes) : bytes;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PhotoViewerPage(
            bytes: zoomBytes,
            title: widget.title,
            secret: widget.secret,
          ),
        ),
      );
    } finally {
      if (widget.secret) zoomBytes.fillRange(0, zoomBytes.length, 0);
    }
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _messaging?.removeListener(_clearSecret);
    _scroll?.removeListener(_schedule);
    _dropBytes();
    super.dispose();
  }

  Future<void> _load() async {
    if (_locked) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bytes = await widget.load();
      if (!mounted || generation != _generation || _locked) {
        if (widget.secret) bytes.fillRange(0, bytes.length, 0);
        return;
      }
      if (bytes.length > 5 * 1024 * 1024) {
        if (widget.secret) bytes.fillRange(0, bytes.length, 0);
        throw const FormatException('Ảnh vượt giới hạn.');
      }
      if (mounted && generation == _generation) {
        setState(() {
          _bytes = bytes;
          _provider = ResizeImage(
            MemoryImage(bytes),
            width: 512,
            height: 512,
            policy: ResizeImagePolicy.fit,
          );
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = errorText(error));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_locked)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Ảnh mã hóa đã đóng. Mở lại hội thoại để xác minh khóa.',
            ),
          ),
        if (_loading)
          const SizedBox(
            height: 180,
            child: Center(child: CircularProgressIndicator()),
          ),
        if (!_locked &&
            widget.viewportBound &&
            !_loading &&
            bytes == null &&
            _error == null)
          const SizedBox(
            height: 180,
            child: Center(child: Icon(Icons.image_outlined, size: 48)),
          ),
        if (bytes != null)
          Semantics(
            button: true,
            label: 'Mở và phóng to ${widget.title}',
            child: InkWell(
              onTap: _openPhoto,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image(
                  image: _provider!,
                  height: 180,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const SizedBox(
                    height: 100,
                    child: Center(child: Text('Không hiển thị được ảnh.')),
                  ),
                ),
              ),
            ),
          ),
        if (bytes != null)
          TextButton.icon(
            onPressed: _openPhoto,
            icon: const Icon(Icons.zoom_in),
            label: const Text('Phóng to ảnh'),
          ),
        if (_error != null)
          MessageBox(
            _error!,
            error: true,
            child: TextButton(
              onPressed: _load,
              child: const Text('Tải lại ảnh'),
            ),
          ),
      ],
    );
  }
}

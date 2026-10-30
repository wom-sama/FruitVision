import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'components.dart';
import 'photo_viewer.dart';

class ApiPhoto extends StatefulWidget {
  const ApiPhoto({super.key, required this.load, this.title = 'Ảnh bài viết'});
  final Future<Uint8List> Function() load;
  final String title;
  @override
  State<ApiPhoto> createState() => _ApiPhotoState();
}

class _ApiPhotoState extends State<ApiPhoto> {
  Uint8List? _bytes;
  bool _loading = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bytes = await widget.load();
      if (mounted) setState(() => _bytes = bytes);
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_loading)
          const SizedBox(
            height: 160,
            child: Center(child: CircularProgressIndicator()),
          ),
        if (bytes != null)
          Semantics(
            button: true,
            label: 'Mở và phóng to ${widget.title}',
            child: InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      PhotoViewerPage(bytes: bytes, title: widget.title),
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image(
                  image: ResizeImage(
                    MemoryImage(bytes),
                    width: 512,
                    height: 512,
                    policy: ResizeImagePolicy.fit,
                  ),
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
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    PhotoViewerPage(bytes: bytes, title: widget.title),
              ),
            ),
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

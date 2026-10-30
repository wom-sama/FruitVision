import 'package:flutter/material.dart';

import '../session.dart';
import 'components.dart';
import 'visuals.dart';

class AiUsagePage extends StatefulWidget {
  const AiUsagePage({super.key, required this.controller});
  final SessionController controller;
  @override
  State<AiUsagePage> createState() => _AiUsagePageState();
}

class _AiUsagePageState extends State<AiUsagePage> {
  int _days = 7, _generation = 0;
  Json? _stats, _guide;
  bool _loading = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    if (widget.controller.user!.canSell) {
      _load();
    } else {
      _loading = false;
    }
  }

  Future<void> _load() async {
    if (!widget.controller.user!.canSell) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await Future.wait([
        widget.controller.api.get('/ai/stats?days=$_days'),
        widget.controller.api.get('/ai/guide'),
      ]);
      if (mounted && generation == _generation) {
        setState(() {
          _stats = data[0];
          _guide = data[1];
        });
      }
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() => _error = errorText(e));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final counts = _stats?['counts'] is Map
        ? Map<String, dynamic>.from(_stats!['counts'])
        : <String, dynamic>{};
    final media = _stats?['media'] is Map
        ? Map<String, dynamic>.from(_stats!['media'])
        : <String, dynamic>{};
    return Scaffold(
      appBar: AppBar(title: const Text('Thống kê & hướng dẫn AI')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (!widget.controller.user!.canSell)
                const MessageBox(
                  'Phân tích AI dành cho Nhà sản xuất và Thương lái đã được duyệt.',
                )
              else ...[
                const SectionTitle(
                  'Hoạt động phân tích của tôi',
                  subtitle: 'Số liệu tác vụ riêng của tài khoản trong khoảng thời gian đã chọn, tính theo ngày UTC.',
                ),
                DropdownButtonFormField<int>(
                  initialValue: _days,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Khoảng thời gian',
                  ),
                  items: [7, 30, 90]
                      .map(
                        (days) => DropdownMenuItem(
                          value: days,
                          child: Text('$days ngày'),
                        ),
                      )
                      .toList(),
                  onChanged: (days) {
                    if (days != null) {
                      setState(() => _days = days);
                      _load();
                    }
                  },
                ),
                const SizedBox(height: 16),
                if (_loading) const LinearProgressIndicator(),
                if (_error != null) MessageBox(_error!, error: true),
                if (_stats != null) ...[
                  CountMetric(
                    label: 'Tổng tác vụ',
                    value: value(counts, 'total'),
                    icon: Icons.analytics_outlined,
                    primary: true,
                  ),
                  const SizedBox(height: 12),
                  CountMetric(
                    label: 'Hoàn tất',
                    value: value(counts, 'completed'),
                    icon: Icons.task_alt,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Thất bại ${value(counts, 'failed')} · Đã hủy ${value(counts, 'cancelled')} · Đang chờ ${value(counts, 'queued')} · Đang chạy ${value(counts, 'running')}',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Ảnh ${value(media, 'imageJobs')} · Video ${value(media, 'videoJobs')}',
                  ),
                  const SizedBox(height: 12),
                  CountMetric(
                    label: 'Khung hình đã xử lý',
                    value: value(media, 'framesProcessed'),
                    icon: Icons.movie_filter_outlined,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Đây là số khung hình đã giải mã/xử lý, không phải số quả, khối lượng hoặc độ chính xác mô hình.',
                  ),
                  const SizedBox(height: 8),
                  Text('Cập nhật ${displayTime(_stats!['asOf'])}'),
                  ExpansionTile(
                    title: const Text('Tác vụ theo ngày UTC'),
                    children: rows({'items': _stats!['jobsByDay']})
                        .map(
                          (day) => ListTile(
                            title: Text(value(day, 'date')),
                            subtitle: Text(
                              'Tổng ${value(day, 'total')} · Hoàn tất ${value(day, 'completed')} · Thất bại ${value(day, 'failed')}',
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ],
                if (_guide != null) ...[
                  const SizedBox(height: 20),
                  const SectionTitle('Dùng AI hiệu quả'),
                  ...(_guide!['steps'] as List? ?? []).whereType<String>().map(
                    (step) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text('• $step'),
                    ),
                  ),
                  MessageBox(
                    'Ảnh tối đa ${((_guide!['maxImageBytes'] as num? ?? 0) / (1024 * 1024)).round()} MiB; video tối đa ${((_guide!['maxVideoBytes'] as num? ?? 0) / (1024 * 1024)).round()} MiB, ${_guide!['maxVideoSeconds']} giây, ${_guide!['maxVideoWidth']} × ${_guide!['maxVideoHeight']}. Xử lý tại máy chủ.',
                  ),
                  const SizedBox(height: 12),
                  ...(_guide!['limitations'] as List? ?? [])
                      .whereType<String>()
                      .map(
                        (text) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text('• $text'),
                        ),
                      ),
                ],
                TextButton.icon(
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Cập nhật số liệu'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../session.dart';
import 'components.dart';
import 'event_refresh.dart';
import 'location_picker.dart';
import 'posts.dart';
import 'visuals.dart';

class ExplorePage extends StatelessWidget {
  const ExplorePage({super.key, required this.controller});
  final SessionController controller;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Khám phá nông sản')),
    body: SafeArea(
      child: LiveApiList(
        api: controller.api,
        path: '/posts?limit=20',
        targets: const {'PublishedPostChanged'},
        header: SectionTitle(
          'Tin đã công bố',
          subtitle: 'Nguồn cung và nhu cầu thu mua; số lượng vẫn là dự kiến.',
          action: OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => MarketPage(controller: controller),
              ),
            ),
            icon: const Icon(Icons.insights_outlined),
            label: const Text('Giá & nguồn cung'),
          ),
        ),
        empty: 'Chưa có tin được công bố.',
        itemBuilder: (post) => PostCard(row: post, controller: controller),
      ),
    ),
  );
}

class MarketPage extends StatefulWidget {
  const MarketPage({super.key, required this.controller});
  final SessionController controller;
  @override
  State<MarketPage> createState() => _MarketPageState();
}

class _MarketPageState extends State<MarketPage> {
  LocationSelection? _location;
  String _queryRegion = '';
  int _pickerGeneration = 0;
  String? _product, _queryProduct, _error;
  List<Json> _products = [];
  Json? _summary;
  bool _loading = true;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _catalog();
    _load();
  }

  Future<void> _catalog() async {
    try {
      final response = await widget.controller.api.get('/catalog/products');
      if (mounted) setState(() => _products = rows(response));
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  Future<void> _search() async {
    _queryRegion = _location?.region ?? '';
    _queryProduct = _product;
    await _load();
  }

  Future<void> _load() async {
    if (widget.controller.endingSession) return;
    final generation = ++_generation;
    final query = Uri(
      queryParameters: {
        if (_queryRegion.isNotEmpty) 'region': _queryRegion,
        'productCode': ?_queryProduct,
      },
    ).query;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await widget.controller.api.get(
        '/market/summary${query.isEmpty ? '' : '?$query'}',
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _summary = response;
        _loading = false;
      });
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = errorText(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => EventRefresh(
    targets: const {'PublishedPostChanged'},
    onRefresh: _load,
    child: Scaffold(
      appBar: AppBar(title: const Text('Giá & nguồn cung')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.all(16),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              const SectionTitle(
                'Tín hiệu từ tin đăng',
                subtitle: 'Xem khối lượng dự kiến và giá chào trong khu vực bạn quan tâm.',
              ),
              ...[
                const Text(
                  'Chọn cả quốc gia và tỉnh để lọc, hoặc xem tất cả khu vực.',
                ),
                const SizedBox(height: 8),
                CountryProvincePicker(
                  key: ValueKey(_pickerGeneration),
                  api: widget.controller.api,
                  onChanged: (location) => _location = location,
                ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _location = null;
                      _pickerGeneration++;
                    });
                    _search();
                  },
                  child: const Text('Tất cả khu vực'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _product ?? 'all',
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Nông sản'),
                  items: [
                    const DropdownMenuItem(
                      value: 'all',
                      child: Text('Tất cả nông sản'),
                    ),
                    ..._products.map(
                      (product) => DropdownMenuItem(
                        value: value(product, 'code'),
                        child: Text(value(product, 'name')),
                      ),
                    ),
                  ],
                  onChanged: (product) {
                    setState(
                      () => _product = product == 'all' ? null : product,
                    );
                    _search();
                  },
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _search,
                  icon: const Icon(Icons.search),
                  label: const Text('Xem dữ liệu'),
                ),
                const SizedBox(height: 16),
                const MessageBox(
                  'Chỉ phản ánh tin đã công bố, không phải giá thị trường chính thức hay dự báo AI. Khối lượng là dự kiến, chưa phải tồn kho.',
                ),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: LinearProgressIndicator(),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  MessageBox(
                    _error!,
                    error: true,
                    child: TextButton(
                      onPressed: _load,
                      child: const Text('Thử lại'),
                    ),
                  ),
                ],
                if (_summary != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Phạm vi: ${value(_summary!, 'region').isEmpty ? 'Tất cả khu vực' : _summary!['region']}',
                  ),
                  Text(
                    'Cập nhật: ${displayTime(_summary!['asOf'])}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (_summary!['source'] is String)
                    Text(
                      'Nguồn: ${_summary!['source'] == 'published-user-asking-prices' ? 'Giá chào trong tin nguồn cung đã công bố' : _summary!['source']}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  const SizedBox(height: 12),
                  if (rows(_summary!).isEmpty)
                    const MessageBox(
                      'Chưa có tin phù hợp bộ lọc. Thử khu vực hoặc nông sản khác.',
                    ),
                  ...rows(_summary!).map(
                    (item) => DataCard(
                      children: [
                        Row(
                          children: [
                            const IconBadge(Icons.eco_outlined),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    value(
                                      item,
                                      'productName',
                                      productLabel(value(item, 'productCode')),
                                    ),
                                    style: const TextStyle(
                                      fontSize: 19,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    value(item, 'region'),
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        if (item['referencePriceVndPerKg'] is num) ...[
                          Text(
                            '${money(item['referencePriceVndPerKg'])} đ/kg',
                            style: const TextStyle(
                              fontSize: 25,
                              fontWeight: FontWeight.w800,
                              color: ink,
                            ),
                          ),
                          const Text(
                            'Trung vị khoảng giá chào từ tin nguồn cung',
                            style: TextStyle(fontSize: 12),
                          ),
                          Text(
                            'Khoảng chào: ${money(item['priceMinVndPerKg'])}–${money(item['priceMaxVndPerKg'])} đ/kg',
                          ),
                        ] else
                          const Text(
                            'Chưa đủ dữ liệu giá',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: blue,
                            ),
                          ),
                        const SizedBox(height: 10),
                        Text(
                          'Mẫu giá chào: ${value(item, 'priceSampleCount', '—')} · Người đóng góp: ${value(item, 'contributorCount', '—')}',
                        ),
                        const Divider(height: 24),
                        Text(
                          'Nguồn cung dự kiến: ${value(item, 'supplyEstimatedKg', '—')} kg',
                        ),
                        Text(
                          'Nhu cầu dự kiến: ${value(item, 'demandEstimatedKg', '—')} kg',
                        ),
                        Text(
                          '${value(item, 'supplyPostCount', '—')} tin cung · ${value(item, 'demandPostCount', '—')} tin nhu cầu',
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Tin mới nhất: ${displayTime(item['lastUpdated'])}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if ((_summary!['limitations'] as List? ?? []).isNotEmpty)
                    ExpansionTile(
                      title: const Text('Giới hạn dữ liệu'),
                      children: [
                        for (final limitation
                            in (_summary!['limitations'] as List))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(limitation.toString()),
                          ),
                      ],
                    ),
                ],
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

import 'package:flutter/material.dart';

import '../api.dart';
import 'components.dart';

class LocationSelection {
  const LocationSelection(this.countryCode, this.provinceCode, this.region);
  final String countryCode, provinceCode, region;
}

/// Country and province codes always come from the application's API directory.
class CountryProvincePicker extends StatefulWidget {
  const CountryProvincePicker({
    super.key,
    required this.api,
    required this.onChanged,
    this.countryCode,
    this.provinceCode,
    this.enabled = true,
  });
  final ApiClient api;
  final ValueChanged<LocationSelection?> onChanged;
  final String? countryCode, provinceCode;
  final bool enabled;
  @override
  State<CountryProvincePicker> createState() => _CountryProvincePickerState();
}

class _CountryProvincePickerState extends State<CountryProvincePicker>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  List<Json> _countries = [], _provinces = [];
  String? _country, _province, _error;
  bool _loadingCountries = true, _loadingProvinces = false, _stale = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _loadCountries();
  }

  Future<void> _loadCountries() async {
    final generation = ++_generation;
    setState(() {
      _loadingCountries = true;
      _error = null;
    });
    try {
      final result = await widget.api.get('/locations/countries');
      if (!mounted || generation != _generation) return;
      final countries = rows(result)
          .where((row) => row['code'] is String && row['name'] is String)
          .toList();
      final initial = widget.countryCode;
      setState(() {
        _countries = countries;
        _loadingCountries = false;
        _stale = result['stale'] == true;
        _country = countries.any((row) => row['code'] == initial)
            ? initial
            : null;
      });
      if (_country != null) {
        await _loadProvinces(_country!, initial: widget.provinceCode);
      }
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = errorText(e);
          _loadingCountries = false;
        });
      }
    }
  }

  Future<void> _loadProvinces(String country, {String? initial}) async {
    final generation = ++_generation;
    widget.onChanged(null);
    setState(() {
      _country = country;
      _province = null;
      _provinces = [];
      _loadingProvinces = true;
      _error = null;
    });
    try {
      final result = await widget.api.get(
        '/locations/provinces?country=${Uri.encodeQueryComponent(country)}',
      );
      if (!mounted || generation != _generation || _country != country) return;
      setState(() {
        _provinces = rows(result)
            .where((row) => row['code'] is String && row['name'] is String)
            .toList();
        _province = _provinces.any((row) => row['code'] == initial)
            ? initial
            : null;
        _loadingProvinces = false;
        _stale = _stale || result['stale'] == true;
      });
      _emit();
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = errorText(e);
          _loadingProvinces = false;
        });
      }
    }
  }

  void _emit() {
    final country = _country, province = _province;
    final selected = _provinces
        .where((row) => row['code'] == province)
        .firstOrNull;
    final countryName = _countries
        .where((row) => row['code'] == country)
        .firstOrNull;
    widget.onChanged(
      country != null &&
              province != null &&
              selected != null &&
              countryName != null
          ? LocationSelection(
              country,
              province,
              '${value(selected, 'name')}, ${value(countryName, 'name')}',
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('country:$_country'),
          initialValue: _country,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Quốc gia'),
          items: _countries
              .map(
                (row) => DropdownMenuItem(
                  value: value(row, 'code'),
                  child: Text(
                    value(row, 'name'),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: !widget.enabled || _loadingCountries
              ? null
              : (code) {
                  if (code != null) _loadProvinces(code);
                },
          validator: (code) =>
              code == null ? 'Chọn quốc gia trong danh mục.' : null,
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey('province:$_country:$_province'),
          initialValue: _province,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Tỉnh / thành phố'),
          items: _provinces
              .map(
                (row) => DropdownMenuItem(
                  value: value(row, 'code'),
                  child: Text(
                    value(row, 'name'),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: !widget.enabled || _loadingProvinces || _country == null
              ? null
              : (code) {
                  setState(() => _province = code);
                  _emit();
                },
          validator: (code) =>
              code == null ? 'Chọn tỉnh / thành phố trong danh mục.' : null,
        ),
        if (_loadingCountries || _loadingProvinces)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(),
          ),
        if (_stale)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Đang dùng danh mục địa giới đã lưu từ máy chủ.'),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: MessageBox(
              _error!,
              error: true,
              child: TextButton(
                onPressed: _loadingCountries || _loadingProvinces
                    ? null
                    : () {
                        if (_country == null) {
                          _loadCountries();
                        } else {
                          _loadProvinces(_country!);
                        }
                      },
                child: const Text('Tải lại danh mục'),
              ),
            ),
          ),
      ],
    );
  }
}

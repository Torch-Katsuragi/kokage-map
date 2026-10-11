// Copyright (C) 2024-2026 Torch-Katsuragi
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
/// 利用者の背景地図（任意の XYZ / WMS の URL）を足すダイアログ。
///
/// 足す前に地図の中心のタイルを 1 枚取ってみる。取れなくても「それでも追加」で足せる
/// （県の CS 立体図のように範囲の狭いタイルは、中心が範囲外だと 404 になるので）
library;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../i18n/strings.g.dart';
import '../models/basemap_provider.dart';
import '../services/basemap_service.dart';

/// 足した地図（定義は [BaseMapService.addCustomProvider] 済み）を返す。やめたら null
Future<BaseMapProvider?> showCustomBaseMapDialog(
  BuildContext context, {
  required BaseMapService service,
  required LatLng center,
  required int zoom,
}) =>
    showDialog<BaseMapProvider>(
      context: context,
      builder: (_) => _CustomBaseMapDialog(service: service, center: center, zoom: zoom),
    );

class _CustomBaseMapDialog extends StatefulWidget {
  const _CustomBaseMapDialog({required this.service, required this.center, required this.zoom});

  final BaseMapService service;
  final LatLng center;
  final int zoom;

  @override
  State<_CustomBaseMapDialog> createState() => _CustomBaseMapDialogState();
}

class _CustomBaseMapDialogState extends State<_CustomBaseMapDialog> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _attribution = TextEditingController();
  var _tms = false;
  var _zoom = const RangeValues(0, 18);

  /// 確かめた結果（URL などを変えたら消す）
  TileProbeResult? _probe;
  var _probing = false;

  /// 入力が変わるたびに進める。確かめている途中で URL などを変えたら、戻ってきた古い結果は捨てる
  var _gen = 0;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _attribution.dispose();
    super.dispose();
  }

  BaseMapProvider _provider() => BaseMapProvider.custom(
        name: _name.text,
        urlTemplate: _url.text,
        minZoom: _zoom.start.round(),
        maxZoom: _zoom.end.round(),
        attribution: _attribution.text,
        tms: _tms,
      );

  /// URL そのものの問題（確かめる前に分かるもの）。無ければ null
  String? get _urlError {
    final url = _url.text.trim();
    if (url.isEmpty) return null;
    if (!BaseMapProvider.isValidTemplate(url)) return t.basemap.custom.invalidUrl;
    if (BaseMapProvider.isForbiddenTileHost(url)) return t.basemap.custom.forbidden;
    final dup = BaseMapProvider.findByTileUrl(url);
    if (dup != null) return t.basemap.custom.duplicate(name: dup.name);
    return null;
  }

  bool get _canSubmit => _url.text.trim().isNotEmpty && _urlError == null && !_probing;

  void _changed() => setState(() {
        _gen++;
        _probe = null;
        _probing = false;
      });

  Future<void> _check() async {
    final gen = ++_gen;
    setState(() => _probing = true);
    final p = _provider();
    final z = widget.zoom.clamp(p.minZoom, p.maxZoom);
    final n = 1 << z;
    final lat = widget.center.latitude.clamp(-85.0, 85.0) * math.pi / 180;
    final x = ((widget.center.longitude + 180) / 360 * n).floor().clamp(0, n - 1);
    final y = ((1 - math.log(math.tan(lat) + 1 / math.cos(lat)) / math.pi) / 2 * n).floor().clamp(0, n - 1);
    final r = await widget.service.probeTile(p, z, x, y);
    if (!mounted || gen != _gen) return;
    setState(() {
      _probing = false;
      _probe = r;
    });
  }

  Future<void> _submit() async {
    if (_probe == null) {
      await _check();
      if (!mounted || !(_probe?.ok ?? false)) return; // 失敗したら理由を見せて「それでも追加」を待つ
    }
    final added = await widget.service.addCustomProvider(_provider());
    if (mounted) Navigator.of(context).pop(added);
  }

  String _probeMessage(TileProbeResult r) {
    final tr = t.basemap.custom;
    return switch (r.status) {
      TileProbeStatus.ok => tr.probeOk,
      TileProbeStatus.httpError => tr.probeHttp(code: '${r.statusCode}'),
      TileProbeStatus.notImage => tr.probeNotImage(type: r.detail == null ? '' : '(${r.detail})'),
      TileProbeStatus.networkError => tr.probeNetwork,
      TileProbeStatus.blockedOnWeb => tr.probeCors,
    };
  }

  @override
  Widget build(BuildContext context) {
    final tr = t.basemap.custom;
    final probe = _probe;
    final urlError = _urlError;
    return AlertDialog(
      title: Text(tr.dialogTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              decoration: InputDecoration(labelText: tr.name),
            ),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              maxLines: 3,
              minLines: 1,
              decoration: InputDecoration(labelText: tr.url, hintText: tr.urlHint, errorText: urlError, errorMaxLines: 3),
              onChanged: (_) => _changed(),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(tr.tms),
              value: _tms,
              onChanged: (v) {
                _tms = v ?? false;
                _changed();
              },
            ),
            Text(
              tr.zoomRange(min: '${_zoom.start.round()}', max: '${_zoom.end.round()}'),
              style: const TextStyle(fontSize: 12),
            ),
            RangeSlider(
              values: _zoom,
              max: 22,
              divisions: 22,
              labels: RangeLabels('${_zoom.start.round()}', '${_zoom.end.round()}'),
              onChanged: (v) {
                _zoom = v;
                _changed();
              },
            ),
            TextField(
              controller: _attribution,
              decoration: InputDecoration(labelText: tr.attribution),
            ),
            const SizedBox(height: 12),
            Text(tr.terms, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            if (_probing) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(tr.checking, style: const TextStyle(fontSize: 12))),
                ],
              ),
            ] else if (probe != null) ...[
              const SizedBox(height: 8),
              Text(
                _probeMessage(probe),
                style: TextStyle(fontSize: 12, color: probe.ok ? Colors.green[700] : Colors.red[700]),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.common.cancel)),
        TextButton(onPressed: _canSubmit ? _check : null, child: Text(tr.check)),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: Text(probe != null && !probe.ok ? tr.addAnyway : tr.add),
        ),
      ],
    );
  }
}

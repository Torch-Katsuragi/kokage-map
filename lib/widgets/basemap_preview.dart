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
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../core/terrain/dem_tiles.dart' show RasterTileComposer, TextureLayer, TileRange;
import '../core/terrain/web_mercator.dart';
import '../services/basemap_service.dart';

/// 背景地図レイヤのプレビュー: いまのレイヤ設定で **タイル 1 枚** を 3D と同じ `composeLayers` で合成して見せる
/// （松本 2026-09-13「タイル 1 つだけ出して、こうなりますよ」）。
///
/// タイルは地図の中心（無ければ東京）の [zoom]。設定が変わるたびに少し待ってから作り直す（スライダーの連打を吸う）
class BaseMapPreview extends StatefulWidget {
  const BaseMapPreview({super.key, required this.service, required this.center, required this.zoom, this.size = 144});

  final BaseMapService service;
  final LatLng center;
  final int zoom;
  final double size;

  @override
  State<BaseMapPreview> createState() => _BaseMapPreviewState();
}

class _BaseMapPreviewState extends State<BaseMapPreview> {
  ui.Image? _image;
  Timer? _debounce;
  int _gen = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_schedule);
    _schedule(immediate: true);
  }

  @override
  void dispose() {
    widget.service.removeListener(_schedule);
    _debounce?.cancel();
    _gen++;
    _image?.dispose();
    super.dispose();
  }

  void _schedule({bool immediate = false}) {
    _debounce?.cancel();
    _debounce = Timer(immediate ? Duration.zero : const Duration(milliseconds: 300), _compose);
  }

  Future<void> _compose() async {
    final gen = ++_gen;
    if (mounted) setState(() => _busy = true);
    final svc = widget.service;
    final z = widget.zoom;
    final x = WebMercator.tileXFraction(widget.center.longitude, z).floor().clamp(0, (1 << z) - 1);
    final y = WebMercator.tileYFraction(widget.center.latitude, z).floor().clamp(0, (1 << z) - 1);
    final layers = <TextureLayer>[
      for (final (p, l) in svc.activeLayers) ((z, x, y) => svc.getTile(p, z, x, y), l.opacity / 100, l.blend.mode),
    ];
    ui.Image? image;
    try {
      image = await RasterTileComposer(fetcher: (_, _, _) async => null)
          .composeLayers(TileRange(z: z, x0: x, y0: y, x1: x, y1: y), layers);
    } catch (_) {
      image = null;
    }
    if (!mounted || gen != _gen) {
      image?.dispose();
      return;
    }
    setState(() {
      _image?.dispose();
      _image = image;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.black12),
          borderRadius: BorderRadius.circular(6),
          color: const Color(0xFFDDDDDD),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (img != null) RawImage(image: img, fit: BoxFit.cover, filterQuality: FilterQuality.medium),
              if (_busy)
                const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
            ],
          ),
        ),
      ),
    );
  }
}

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

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:maplibre/maplibre.dart' as ml;

import '../../core/r_map_controller.dart';

typedef RMapControllerCallback = void Function(RMapController controller);
typedef RMapStyleLoadedCallback =
    FutureOr<void> Function(RMapController controller, ml.StyleController style);

/// ネットワーク不要なローカルスタイル。背景色のみ定義し、ソースは動的に追加する。
const kEmptyMapStyle =
    '{"version":8,"glyphs":"https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf","sources":{},"layers":[{"id":"bg","type":"background","paint":{"background-color":"#e8e8e8"}}]}';

/// MapLibreMap の生成差分をここに閉じ込める薄いラッパー。
class RMapWidget extends StatefulWidget {
  const RMapWidget({
    super.key,
    this.options = const ml.MapOptions(),
    this.gestureRecognizers,
    this.onMapCreated,
    this.onStyleLoaded,
    this.onEvent,
    this.layers = const [],
    this.children = const [],
    this.onDispose,
  });

  final ml.MapOptions options;

  /// ウィジェットが外れたとき（3D に入ると地図は組み立てない）
  final VoidCallback? onDispose;
  final Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers;
  final RMapControllerCallback? onMapCreated;
  final RMapStyleLoadedCallback? onStyleLoaded;
  final ml.MapEventCallback? onEvent;
  final List<ml.Layer> layers;
  final List<Widget> children;

  @override
  State<RMapWidget> createState() => _RMapWidgetState();
}

class _RMapWidgetState extends State<RMapWidget> {
  final RMapController _controller = RMapController();

  @override
  void deactivate() {
    // ⚠ maplibre_android 0.3.5 はプラットフォームビューを捨ててもネイティブの地図を破棄しない
    // （create/dispose ごとに漏れる。0.3.6 で修正だが Flutter ≥ 3.44 が要る）。
    // 捨てる前に空のスタイルを読ませて、少なくともタイルとソースのぶんは手放す。
    // dispose では子（MapLibreMap）が先に外れているので deactivate で
    try {
      _controller.raw?.setStyle(kEmptyMapStyle);
    } on Object catch (_) {}
    super.deactivate();
  }

  @override
  void dispose() {
    widget.onDispose?.call();
    super.dispose();
  }

  /// onMapCreated が呼ばれる前に didUpdateWidget が発火すると
  /// コントローラ未初期化でエラーになるため、
  /// onMapCreated 完了まで全パラメータを初回値に固定する。
  bool _isMapCreated = false;
  late final ml.MapOptions _initialOptions = widget.options;

  @override
  Widget build(BuildContext context) {
    return ml.MapLibreMap(
      options: _isMapCreated ? widget.options : _initialOptions,
      gestureRecognizers: widget.gestureRecognizers,
      onMapCreated: (controller) {
        _controller.attach(controller);
        widget.onMapCreated?.call(_controller);
        if (!_isMapCreated) {
          setState(() => _isMapCreated = true);
        }
      },
      onStyleLoaded: (style) async {
        _controller.attachStyle(style);
        await widget.onStyleLoaded?.call(_controller, style);
      },
      onEvent: widget.onEvent,
      layers: _isMapCreated ? widget.layers : const [],
      children: _isMapCreated ? widget.children : const [],
    );
  }
}

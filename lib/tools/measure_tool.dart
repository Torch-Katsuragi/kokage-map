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
// lib/tools/measure_tool.dart
// 計測ツール: 地図をタップして点を置き、区間ごとの距離と合計、面にしたら周長と面積を出す。地物は作らない。
//
// 距離と面積の切り替えは左下のボタン（ペンの消しゴム・選択の複数選択と同じ置き場所）。
// 始点をタップしても面になる。切り替えの表示は ToolNameFlash がツールとボタンの組から出す。
// 地図の移動・拡縮・回転はいつもの指の操作のまま（1 本指を取らないので 3D でも傾けられる）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../interfaces/map_state_interface.dart';
import '../providers/tool_providers.dart';
import '../providers/ui_state_providers.dart';
import '../utils/geodesic.dart';
import 'map_tool.dart';
import 'pan_tool.dart';

/// 計測の中身（点の並びと、面にするか）。地図にも画面にも依らないのでテストできる
class MeasureSession extends ChangeNotifier {
  final List<LatLng> _points = [];
  bool _closed = false;

  List<LatLng> get points => List.unmodifiable(_points);

  bool get isEmpty => _points.isEmpty;

  /// 面にする指定（左下のボタン）。点が 3 つ未満のうちは指定だけ覚えて、面積は出さない
  bool get closeRequested => _closed;

  /// 面として測っているか（指定があり、点が 3 つ以上）
  bool get isArea => _closed && _points.length >= 3;

  set closeRequested(bool v) {
    if (_closed == v) return;
    _closed = v;
    notifyListeners();
  }

  void add(LatLng p) {
    _points.add(p);
    notifyListeners();
  }

  /// 最後の点を取り除く。点が無ければ false
  bool undo() {
    if (_points.isEmpty) return false;
    _points.removeLast();
    notifyListeners();
    return true;
  }

  void clear() {
    if (_points.isEmpty) return;
    _points.clear();
    notifyListeners();
  }

  /// 区間ごとの長さ [m]。面なら最後の点から始点へ戻る区間も入る
  List<double> get segments => [
    for (var i = 1; i < _points.length; i++) Geodesic.distance(_points[i - 1], _points[i]),
    if (isArea) Geodesic.distance(_points.last, _points.first),
  ];

  /// 区間の合計 [m]（面なら周長）
  double get total => segments.fold(0, (s, d) => s + d);

  /// 面積 [m²]（面でなければ null）
  double? get area => isArea ? Geodesic.ringArea(_points) : null;
}

/// 計測ツール
class MeasureTool extends MapTool with PanDelegation {
  MeasureTool(this._ref);
  final Ref _ref;

  final MeasureSession session = MeasureSession();

  /// 始点をタップして面にするときの当たり半径 [px]
  static const double closeHitPx = 24;

  @override
  PanTool get panTool => _ref.read(panToolProvider);

  @override
  String get name => 'Measure';

  @override
  IconData get icon => Icons.straighten;

  /// 地図を離れたら測った線は残さない（地物ではないので）
  @override
  void onDeactivate() => session.clear();

  @override
  void onTap(TapUpDetails details, IMapState mapState) {
    final pts = session.points;
    // 始点を叩いたら面にする（左下のボタンを点けるのと同じ。切り替えの表示もそちらから出る）
    if (pts.length >= 3 && !session.closeRequested) {
      try {
        if ((mapState.latLngToOffset(pts.first) - details.localPosition).distance <= closeHitPx) {
          _ref.read(isFabActiveProvider.notifier).set(true);
          return;
        }
      } catch (_) {
        // 投影できないときは点を足す側へ
      }
    }
    final p = mapState.tryOffsetToLatLng(details.localPosition);
    if (p == null) return; // 空や地図の外は測らない
    session.add(p);
  }

  @override
  void onScaleStart(ScaleStartDetails details, IMapState mapState) => panTool.onScaleStart(details, mapState);

  @override
  void onScaleUpdate(ScaleUpdateDetails details, IMapState mapState) => panTool.onScaleUpdate(details, mapState);

  @override
  void onScaleEnd(ScaleEndDetails details, IMapState mapState) => panTool.onScaleEnd(details, mapState);

  @override
  void dispose() {
    session.dispose();
    super.dispose();
  }
}

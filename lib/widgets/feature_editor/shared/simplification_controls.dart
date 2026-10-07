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
/// Douglas-Peucker簡略化のスライダー＋統計表示ウィジェット
///
/// 許容誤差スライダーと簡略化統計を表示する。
/// 状態は内部で管理し、結果は onChanged コールバックで通知。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../../i18n/strings.g.dart';
import '../../../utils/feature_calc_utils.dart';

/// Isolate で実行する簡略化関数（トップレベル）
List<double> _simplifyInIsolate(List<double> args) {
  final tolerance = args[0];
  final coordCount = ((args.length - 1) / 2).floor();
  final line = <LatLng>[];
  for (int i = 0; i < coordCount; i++) {
    line.add(LatLng(args[1 + i * 2], args[2 + i * 2]));
  }
  final result = LineSimplification.simplifyLineDouglasPeucker(line, tolerance);
  final out = <double>[];
  for (final p in result) {
    out.add(p.latitude);
    out.add(p.longitude);
  }
  return out;
}

class SimplificationControls extends StatefulWidget {
  /// 簡略化対象の元ライン
  final List<LatLng> originalLine;

  /// 簡略化結果の通知コールバック
  final ValueChanged<List<LatLng>> onChanged;

  /// 許容誤差の初期値（メートル）
  final double initialTolerance;

  const SimplificationControls({
    super.key,
    required this.originalLine,
    required this.onChanged,
    this.initialTolerance = 1.0,
  });

  @override
  State<SimplificationControls> createState() => SimplificationControlsState();
}

class SimplificationControlsState extends State<SimplificationControls> {
  late double _tolerance;
  List<LatLng> _simplified = [];
  Map<String, dynamic>? _stats;
  bool _isComputing = false;

  List<LatLng> get simplified => _simplified;

  /// Isolate で簡略化を実行する点数の閾値
  static const _isolateThreshold = 500;

  @override
  void initState() {
    super.initState();
    _tolerance = widget.initialTolerance;
    // 親のビルド中に onChanged を呼ばないよう、初回はフレーム後に実行
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSimplification();
    });
  }

  @override
  void didUpdateWidget(covariant SimplificationControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.originalLine != widget.originalLine) {
      // 親のビルド中に onChanged（親の setState）を呼ばないようフレーム後に回す
      WidgetsBinding.instance.addPostFrameCallback((_) => _runSimplification());
    }
  }

  Future<void> _runSimplification() async {
    if (!mounted) return;
    if (widget.originalLine.length < 2) {
      _simplified = List.of(widget.originalLine);
      _stats = null;
      if (mounted) {
        setState(() {});
        widget.onChanged(_simplified);
      }
      return;
    }

    if (widget.originalLine.length > _isolateThreshold) {
      await _runInIsolate();
    } else {
      _simplified = LineSimplification.simplifyLineDouglasPeucker(
        widget.originalLine,
        _tolerance,
      );
    }

    _stats = LineSimplification.getSimplificationStats(
      widget.originalLine,
      _simplified,
    );
    if (mounted) {
      setState(() {});
      widget.onChanged(_simplified);
    }
  }

  Future<void> _runInIsolate() async {
    setState(() => _isComputing = true);
    final args = <double>[_tolerance];
    for (final p in widget.originalLine) {
      args.add(p.latitude);
      args.add(p.longitude);
    }
    final result = await compute(_simplifyInIsolate, args);
    _simplified = <LatLng>[];
    for (int i = 0; i < result.length; i += 2) {
      _simplified.add(LatLng(result[i], result[i + 1]));
    }
    if (mounted) setState(() => _isComputing = false);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // スライダー
        Row(
          children: [
            Text(t.simplification.tolerance, style: const TextStyle(fontSize: 12)),
            Expanded(
              child: Slider(
                value: _tolerance,
                min: 0.1,
                max: 50.0,
                divisions: 499,
                onChanged: (v) => setState(() => _tolerance = v),
                onChangeEnd: (_) => _runSimplification(),
              ),
            ),
            SizedBox(
              width: 55,
              child: Text(
                '${_tolerance.toStringAsFixed(1)}m',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),

        // 計算中インジケーター
        if (_isComputing)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: LinearProgressIndicator(),
          ),

        // 統計情報
        if (_stats != null && !_isComputing)
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        t.simplification.pointCount(original: '${_stats!['originalPoints']}', simplified: '${_stats!['simplifiedPoints']}'),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        t.simplification.reduction(value: '${_stats!['pointReductionPercent']}'),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        t.simplification.error(value: '${_stats!['lengthErrorPercent']}'),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        t.simplification.errorDistance(value: (_stats!['lengthError'] as double).toStringAsFixed(1)),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}

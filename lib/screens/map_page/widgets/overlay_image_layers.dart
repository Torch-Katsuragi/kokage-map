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
// こかげマップ: 選択中オーバーレイ画像の枠線と、変形ツールのハンドル

import 'package:flutter/material.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:maplibre/maplibre.dart' as ml;

import '../../../models/nodes/layer_tree_node.dart';
import '../../../models/nodes/overlay_image_node.dart';
import '../../../tools/overlay_transform_tool.dart';
import '../../../utils/geo_converter.dart';

/// 選択中オーバーレイの枠線レイヤー
/// - 選択中: 青い矩形枠（常時表示）
/// - 変形ツール時: 回転ハンドルの接続線（上辺中点→回転ハンドル）も追加
List<ml.Layer> buildOverlaySelectionLayers(
  Set<LayerTreeNode> selected,
  Object? currentTool,
) {
  final layers = <ml.Layer>[
    for (final node in selected.whereType<OverlayImageNode>())
      ml.PolylineLayer(
        polylines: [
          geo.Feature(
            geometry: geo.LineString.from([
              ...node.cornerCoordinates.map((c) => c.toGeographic()),
              node.cornerCoordinates[0].toGeographic(), // リングを閉じる
            ]),
          ),
        ],
        color: Colors.blue,
        width: 2,
      ),
  ];

  if (currentTool is OverlayTransformTool && currentTool.target != null) {
    final corners = currentTool.target!.cornerCoordinates;
    final rotatePos = currentTool.rotationHandlePosition;
    if (rotatePos != null) {
      final topMid = LatLng(
        (corners[0].latitude + corners[1].latitude) / 2,
        (corners[0].longitude + corners[1].longitude) / 2,
      );
      layers.add(
        ml.PolylineLayer(
          polylines: [
            geo.Feature(
              geometry: geo.LineString.from([
                topMid.toGeographic(),
                rotatePos.toGeographic(),
              ]),
            ),
          ],
          color: Colors.blue.withValues(alpha: 0.5),
          width: 1,
        ),
      );
    }
  }
  return layers;
}

/// オーバーレイ変形ハンドル（Photoshop風: 四隅のリサイズ＋回転）
List<ml.Marker> buildTransformHandleMarkers(OverlayTransformTool tool) {
  final target = tool.target;
  if (target == null) return const [];
  final rotatePos = tool.rotationHandlePosition;
  return [
    // 四隅のリサイズハンドル（白丸+青ボーダー）
    for (final corner in target.cornerCoordinates)
      ml.Marker(
        point: corner.toGeographic(),
        size: const Size.square(24),
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.blue, width: 2.5),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
        ),
      ),
    // 回転ハンドル（緑丸+回転アイコン）
    if (rotatePos != null)
      ml.Marker(
        point: rotatePos.toGeographic(),
        size: const Size.square(28),
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: Colors.green.shade600,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
          ),
          child: const Icon(Icons.rotate_right, size: 16, color: Colors.white),
        ),
      ),
  ];
}

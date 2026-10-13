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
// こかげマップ: レイヤの並び（レイヤ一覧の並び = 描く順）
//
// QGIS と同じく、レイヤ一覧の上にあるものほど地図の手前に描く。並びの正はフォルダ設定の
// `layout.sortOrder`（QGIS で保存された `.qgs` のレイヤツリーから読み戻す）。無ければ種類順
// （フォルダ → gpkg → 外部形式 → 画像、それぞれ名前順）。[[docs/technical/qgis-interop#レイヤの並びと描く順（2026-10-13）]]

import 'layer_node.dart';
import 'layer_tree_node.dart';
import 'overlay_image_node.dart';

/// 既定の並び [defaults] のうち、[order] にキーがある子の席を [order] の順で埋め直す。
///
/// [order] にキーの無い子（`.qgs` に出ない写真・あとから足したファイル）は既定の席のまま動かない。
/// たとえば既定 `[a.gpkg, b.gpkg, ortho.tif]`・並び `[ortho.tif, a.gpkg]` なら、a.gpkg と ortho.tif の席
/// （0 と 2）を ortho.tif → a.gpkg の順で埋め、`[ortho.tif, b.gpkg, a.gpkg]` になる。
/// 新しく足した gpkg が不透明なオルソの下に回って見えなくなる、ということが起きにくい
List<T> applyLayerOrder<T>(List<T> defaults, List<String>? order, String Function(T node) keyOf) {
  if (order == null || order.isEmpty || defaults.length < 2) return defaults;
  final rank = <String, int>{};
  for (var i = 0; i < order.length; i++) {
    rank.putIfAbsent(order[i], () => i);
  }
  final slots = <int>[];
  final listed = <T>[];
  for (var i = 0; i < defaults.length; i++) {
    if (rank.containsKey(keyOf(defaults[i]))) {
      slots.add(i);
      listed.add(defaults[i]);
    }
  }
  if (listed.length < 2) return defaults;
  // 安定ソート（同じキーが並びに重なっていても元の順を保つ）
  final indexed = [for (var i = 0; i < listed.length; i++) (i, listed[i])]
    ..sort((a, b) {
      final c = rank[keyOf(a.$2)]!.compareTo(rank[keyOf(b.$2)]!);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
  final out = List<T>.of(defaults);
  for (var i = 0; i < slots.length; i++) {
    out[slots[i]] = indexed[i].$2;
  }
  return out;
}

/// [nodes] を [position] の小さい順（上から）に並べる。位置の無いものは外す。同じ位置なら元の順
List<T> sortByPosition<T>(Iterable<T> nodes, int? Function(T node) position) {
  final indexed = <(int, int, T)>[];
  var i = 0;
  for (final n in nodes) {
    final pos = position(n);
    if (pos != null) indexed.add((pos, i, n));
    i++;
  }
  indexed.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  return [for (final e in indexed) e.$3];
}

/// フォルダ設定の並び（`layout.sortOrder`）で子をキーにするときの名前。
/// フォルダの子は名前、gpkg の中のレイヤは `gpkg名/レイヤ名`（[LayerNode.layerKey]）
String layerOrderKey(LayerTreeNode node) => node is LayerNode ? node.layerKey : node.name;

/// 地図に描くもの（レイヤとオーバーレイ画像）を、レイヤ一覧の上から順に。
///
/// QGIS と同じく、先頭ほど手前に描く。消灯しているものも入れる（目を切り替えるたびに段がずれて、
/// 焼き込み済みのテクスチャを全部焼き直さないように）。レイヤの子（地物）には降りない
List<LayerTreeNode> drawOrderOf(LayerTreeNode root) {
  final out = <LayerTreeNode>[];
  void walk(LayerTreeNode n) {
    if (n is LayerNode || n is OverlayImageNode) {
      out.add(n);
      return;
    }
    for (final c in n.children) {
      walk(c);
    }
  }

  walk(root);
  return out;
}

/// 描く順の段（大きいほど手前）。[drawOrderOf] の先頭がいちばん大きい
Map<LayerTreeNode, int> drawRanksOf(List<LayerTreeNode> order) => {
      for (var i = 0; i < order.length; i++) order[i]: order.length - 1 - i,
    };

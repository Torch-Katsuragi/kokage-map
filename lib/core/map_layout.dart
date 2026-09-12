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
// こかげマップ: 地図画面の配置（スロットとプリセット）
//
// 内部は「ツールバーはどちらの縁か」「情報カードはどこに出すか」のスロットで持ち、
// ユーザーにはプリセット（自動／縦持ち／横長／左利き）だけを見せる（松本 2026-09-12:
// お絵かきアプリのように内部は自由に、見える範囲はこちらで用意した数個）。
//
// 情報カードと属性テーブルは下パネルで排他。属性テーブルが開いている間だけ、
// 情報カードは（表の行を選ぶ流れを切らないために）地図の上に浮かせる。

import 'package:flutter/widgets.dart';

enum MapLayoutPreset { auto, portrait, landscape, leftHanded }

enum ToolbarSide { left, right }

/// 情報カード（選択したフィーチャの情報）の置き場所
enum InfoPlacement {
  /// 下パネル（属性テーブルと排他）
  bottom,

  /// 右のサイドパネル（横長の画面。属性テーブルは下のまま）
  side,
}

@immutable
class MapLayout {
  const MapLayout({required this.toolbar, required this.info});

  final ToolbarSide toolbar;
  final InfoPlacement info;

  static const portrait = MapLayout(toolbar: ToolbarSide.left, info: InfoPlacement.bottom);
  static const landscape = MapLayout(toolbar: ToolbarSide.left, info: InfoPlacement.side);
  static const leftHanded = MapLayout(toolbar: ToolbarSide.right, info: InfoPlacement.bottom);

  /// 横長とみなす縦横比（これより横に長ければ横長）
  static const landscapeAspect = 1.2;

  static MapLayout resolve(MapLayoutPreset preset, Size size) => switch (preset) {
        MapLayoutPreset.portrait => portrait,
        MapLayoutPreset.landscape => landscape,
        MapLayoutPreset.leftHanded => leftHanded,
        MapLayoutPreset.auto =>
          size.height > 0 && size.width / size.height > landscapeAspect ? landscape : portrait,
      };

  bool get toolbarLeft => toolbar == ToolbarSide.left;

  @override
  bool operator ==(Object other) => other is MapLayout && other.toolbar == toolbar && other.info == info;

  @override
  int get hashCode => Object.hash(toolbar, info);
}

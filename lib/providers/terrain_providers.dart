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
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'terrain_providers.g.dart';

/// 3D 地形モード（地図面を純 Dart の地形描画系に切り替える）
///
/// 真上ロック = 3D を抜けて MapLibre に戻ること。手描き系のツール（ペン・GPS）を選ぶと
/// 自動で抜ける。閲覧・選択・位置ベースのデータ追加は 3D のままできる。
@Riverpod(keepAlive: true)
class Terrain3dMode extends _$Terrain3dMode {
  /// 3D が正（2026-09-11 松本決定）。Android / desktop は最初から 3D（真上から始まる）。
  /// web は純 Dart 経路の fps が未計測なので当面 MapLibre が既定で、ツールバーのボタンで 3D に入る
  @override
  bool build() => !kIsWeb;

  void set(bool enabled) => state = enabled;

  void toggle() => state = !state;
}

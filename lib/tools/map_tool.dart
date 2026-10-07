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
// lib/tools/map_tool.dart
// 地図操作ツールの抽象基底クラス
// 各ツール（てのひら・ペン・選択等）はこのクラスを継承
import 'package:flutter/material.dart';

import '../interfaces/map_state_interface.dart';

/// 地図操作ツールの抽象基底クラス
///
/// ツール自身の状態（外部機器の計測値、GPS 長押し測量の点数など）が変わったら [notifyListeners] する。
/// 画面側は今のツールを [ListenableBuilder] などで聞いて、その部分だけ描き直す。
/// ペン・GPS 測量の描きかけは [GlobalDrawingState] が持ち、そちらが通知する
abstract class MapTool extends ChangeNotifier {
  /// ツール名（UI表示用）
  String get name;

  /// ツールアイコン（UI用）
  IconData get icon;

  /// ツール有効化時の初期化処理
  void onActivate() {}

  /// ツール無効化時の終了処理
  void onDeactivate() {}

  /// タップイベント
  void onTap(TapUpDetails details, IMapState mapState) {}

  /// スケール開始イベント
  void onScaleStart(ScaleStartDetails details, IMapState mapState) {}

  /// スケール更新イベント
  void onScaleUpdate(ScaleUpdateDetails details, IMapState mapState) {}

  /// スケール終了イベント
  void onScaleEnd(ScaleEndDetails details, IMapState mapState) {}

  /// マウスホイールスクロールイベント
  void onPointerSignal(PointerEvent event, IMapState mapState) {}

  /// 中ボタンドラッグ開始イベント
  void onMiddleButtonDown(PointerDownEvent event, IMapState mapState) {}

  /// 中ボタンドラッグ移動イベント
  void onMiddleButtonMove(PointerMoveEvent event, IMapState mapState) {}

  /// 中ボタンドラッグ終了イベント
  void onMiddleButtonUp(PointerUpEvent event, IMapState mapState) {}

  /// 指を置いてからスケールのジェスチャと分かるまでの生の位置（指を置くたび・動くたびに呼ばれる）。
  /// 使うのは描き始めを取りこぼしたくないペンだけなので、既定では持たない
  void addPointerToBuffer(Offset offset) {}

  /// 指を離したら捨てる
  void clearPointerBuffer() {}
}

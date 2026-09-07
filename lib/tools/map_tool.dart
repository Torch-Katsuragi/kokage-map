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
import 'package:flutter/widgets.dart';

import '../interfaces/map_state_interface.dart';

/// 地図操作ツールの抽象基底クラス
abstract class MapTool {
  /// PointerEventバッファ（Listener等でonPointerMove時に記録）
  final List<Offset> pointerBuffer = [];

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

  /// バッファに座標を追加
  void addPointerToBuffer(Offset offset) {
    pointerBuffer.add(offset);
  }

  /// バッファをクリア
  void clearPointerBuffer() {
    pointerBuffer.clear();
  }

  /// バッファ内容を取得
  List<Offset> getPointerBuffer() {
    return List.unmodifiable(pointerBuffer);
  }
}

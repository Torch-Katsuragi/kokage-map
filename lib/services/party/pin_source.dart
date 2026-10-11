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
/// パーティ位置共有: 共有ピンの送受信の境界（RTDB 実装は [RtdbPinSource]）
library;

import '../../models/party/room_pin.dart';

/// サーバーがピンの書き込みを拒んだ（ルーム終了・失効・BAN・消されたピンの書き換えなど）。
/// 送り直しても通らないので、未送信キューから外す
class PinRejectedException implements Exception {
  const PinRejectedException(this.message);
  final String message;
  @override
  String toString() => 'PinRejectedException: $message';
}

/// 共有ピンのソース
abstract class PinSource {
  /// ルームのピン全部（id -> ピン。消されたものも含む）のスナップショット
  Stream<Map<String, RoomPin>> get pins;

  /// ピン全体を書く（作成・書き換え・消すのどれも同じ）。同じ中身の再送は冪等。
  ///
  /// サーバーが拒んだら [PinRejectedException]。繋がっていなければ返らないことがある
  Future<void> putPin(RoomPin pin);

  /// サーバー時刻の推定値（epoch ms）
  int serverNowMs();

  Future<void> dispose();
}

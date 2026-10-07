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
/// 外部計測機器サービスの抽象基底クラス
///
/// Bluetooth等で接続する外部機器（レーザー距離計、トータルステーション等）の
/// 共通インターフェースを定義。各機器実装はこのクラスを継承する。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';

abstract class ExternalDeviceService extends ChangeNotifier {
  /// 機器の表示名（例: "TruPulse 360R"）
  String get deviceTypeName;

  /// 接続済みかどうか
  bool get isConnected;

  /// 接続処理中かどうか
  bool get isConnecting;

  /// ペアリング済みの互換デバイスを列挙
  Future<List<BluetoothDevice>> scanDevices();

  /// 機器に接続
  Future<void> connectToDevice(BluetoothDevice device);

  /// 接続を切断
  Future<void> disconnect();
}

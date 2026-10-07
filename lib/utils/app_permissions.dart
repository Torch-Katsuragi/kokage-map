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
/// 初回の案内・設定・外部機器の画面が確かめる権限（ストレージ・位置情報・Bluetooth）
library;

import 'package:permission_handler/permission_handler.dart';

abstract final class AppPermissions {
  /// Bluetooth（スキャンと接続の両方）が許可されているか
  static Future<bool> bluetoothGranted() async =>
      await Permission.bluetoothScan.isGranted &&
      await Permission.bluetoothConnect.isGranted;

  /// Bluetooth のスキャンと接続を求め、両方許可されたかを返す
  static Future<bool> requestBluetooth() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    return (statuses[Permission.bluetoothScan]?.isGranted ?? false) &&
        (statuses[Permission.bluetoothConnect]?.isGranted ?? false);
  }

  /// 案内する 3 つの権限の今の状態
  static Future<({bool storage, bool location, bool bluetooth})>
      current() async => (
            storage: await Permission.manageExternalStorage.isGranted,
            location: await Permission.location.isGranted,
            bluetooth: await bluetoothGranted(),
          );
}

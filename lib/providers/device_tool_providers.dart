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
/// 接続済み外部機器ツールの集約プロバイダー
///
/// MapToolbar / map_page はこのプロバイダーのみを参照し、
/// 個別デバイスの知識を持たない。
/// 新しい機器を追加する場合、このファイルに1行追加するだけでよい。
library;

import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../devices/base/device_tool.dart';
import '../devices/trupulse/trupulse_providers.dart';

part 'device_tool_providers.g.dart';

/// DeviceTool のオーバーレイ再描画トリガー
///
/// featureRefreshTriggerProvider と同パターン。
/// DeviceTool 内部状態が変わった際に trigger() を呼び、
/// map_page 側の ref.listen で triggerSetState を発火する。
@Riverpod(keepAlive: true)
class DeviceToolOverlayRefresh extends _$DeviceToolOverlayRefresh {
  @override
  int build() => 0;

  void trigger() => state++;
}

/// 接続済みで利用可能なDeviceToolのリストを返す
///
/// 各サービスの ChangeNotifier を addListener で購読し、
/// isConnected 変更時にプロバイダを再評価する
/// （計測 1 回ごとの通知では組み直さない。道具の並びは変わらないので）。
@riverpod
List<DeviceTool> connectedDeviceTools(Ref ref) {
  final trupulseService = ref.watch(trupulseServiceProvider);
  final trupulseTool = ref.watch(trupulseToolProvider);
  final trupulseAvailable = trupulseTool.isAvailable;

  // Bridge: ChangeNotifier → Riverpod
  void onServiceChange() {
    if (trupulseTool.isAvailable != trupulseAvailable) ref.invalidateSelf();
  }
  trupulseService.addListener(onServiceChange);
  ref.onDispose(() => trupulseService.removeListener(onServiceChange));

  return [
    if (trupulseAvailable) trupulseTool,
    // 将来のデバイス: ここにサービス購読 + 条件行を追加するだけ
  ];
}

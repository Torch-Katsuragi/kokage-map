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
import 'package:flutter/foundation.dart' show immutable;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/r_map_controller.dart';
import '../models/nodes/layer_tree_node.dart';

part 'ui_state_providers.g.dart';

// ============================================================
// UIスケール
// ============================================================

/// UIスケールレベル（7段階: 0=XS, 1=S, 2=M-, 3=M, 4=M+, 5=L, 6=XL）
@Riverpod(keepAlive: true)
class UiScaleLevel extends _$UiScaleLevel {
  static const _key = 'ui_scale_level';
  static const defaultLevel = 3;
  static const _scaleFactors = [0.5, 0.65, 0.8, 1.0, 1.25, 1.55, 2.0];

  @override
  int build() => defaultLevel;

  /// SharedPreferencesから読み込み
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    state = (prefs.getInt(_key) ?? defaultLevel).clamp(0, 6);
  }

  /// レベルを設定して永続化
  Future<void> set(int level) async {
    state = level.clamp(0, 6);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, state);
  }

  /// 現在のレベルに対応するスケール係数
  double get scaleFactor => _scaleFactors[state];
}

/// GeoPackage タイル展開状態（不変値オブジェクト）
/// 地図面のフラッシュ表示（さっと出て消える短い文言）。
///
/// ツールの切替と同じ演出を、モードが切り替わる操作すべてに徹底する（松本 2026-09-11）:
/// 眺めモードの切替、北上・真上に戻す、3D/2D の切替（web）、ドライブの開始と終了など。
/// 表示側は `ToolNameFlash`。同じ文言を続けて出せるように連番を添える
@Riverpod(keepAlive: true)
class MapFlash extends _$MapFlash {
  @override
  (String, int) build() => ('', 0);

  void show(String label) => state = (label, state.$2 + 1);
}

@immutable
class GpkgExpansionState {
  final Set<String> expandedPaths;
  final Set<String> userClosedPaths;

  const GpkgExpansionState({
    this.expandedPaths = const {},
    this.userClosedPaths = const {},
  });

  bool isExpanded(String? path) => path != null && expandedPaths.contains(path);

  GpkgExpansionState copyWith({Set<String>? expandedPaths, Set<String>? userClosedPaths}) =>
      GpkgExpansionState(
        expandedPaths: expandedPaths ?? this.expandedPaths,
        userClosedPaths: userClosedPaths ?? this.userClosedPaths,
      );
}

@Riverpod(keepAlive: true)
class IsFabActive extends _$IsFabActive {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

@Riverpod(keepAlive: true)
class IsAttributeTableEditing extends _$IsAttributeTableEditing {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

@Riverpod(keepAlive: true)
class FeatureRefreshTrigger extends _$FeatureRefreshTrigger {
  @override
  int build() => 0;

  void trigger() => state++;
}

@Riverpod(keepAlive: true)
class MapControllerHolder extends _$MapControllerHolder {
  @override
  RMapController? build() => null;

  void set(RMapController controller) => state = controller;
}

@Riverpod(keepAlive: true)
class FolderTree extends _$FolderTree {
  @override
  LayerTreeNode? build() => null;

  void set(LayerTreeNode? tree) => state = tree;
}

@Riverpod(keepAlive: true)
class ExpandedGeoPackages extends _$ExpandedGeoPackages {
  @override
  GpkgExpansionState build() => const GpkgExpansionState();

  void toggle(String path) {
    final expanded = Set<String>.from(state.expandedPaths);
    final closed = Set<String>.from(state.userClosedPaths);
    if (expanded.contains(path)) {
      expanded.remove(path);
      closed.add(path);
    } else {
      expanded.add(path);
      closed.remove(path);
    }
    state = GpkgExpansionState(expandedPaths: expanded, userClosedPaths: closed);
  }

  void expandAll(Iterable<String> paths) {
    final expanded = Set<String>.from(state.expandedPaths)..addAll(paths);
    state = state.copyWith(expandedPaths: expanded);
  }

  /// 新規追加ノードのみ展開（ユーザーが閉じたものは除く）。変更がなければ state を更新しない
  void expandNewOnly(Iterable<String> paths) {
    final expanded = Set<String>.from(state.expandedPaths);
    var changed = false;
    for (final p in paths) {
      if (!expanded.contains(p) && !state.userClosedPaths.contains(p)) {
        expanded.add(p);
        changed = true;
      }
    }
    if (changed) state = state.copyWith(expandedPaths: expanded);
  }

  void resetAndExpandAll(Iterable<String> paths) {
    state = GpkgExpansionState(expandedPaths: Set.from(paths));
  }

  void addExpanded(String path) {
    state = state.copyWith(expandedPaths: {...state.expandedPaths, path});
  }

  void updatePath(String oldPath, String newPath) {
    final expanded = Set<String>.from(state.expandedPaths);
    if (expanded.remove(oldPath)) expanded.add(newPath);
    state = state.copyWith(expandedPaths: expanded);
  }
}

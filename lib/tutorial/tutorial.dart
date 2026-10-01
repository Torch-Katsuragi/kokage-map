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
// チュートリアル「はじめての 1 本」: 練習プロジェクトの上で、本物の画面に「ここを押す」を順に出す。
//
// 画面の側は操作が起きたら [Tutorial.report] に知らせるだけ。今の手順に合う知らせなら次へ進む。
// 案内先の部品には [TutorialTargets] の GlobalKey を付ける（練習プロジェクトの中だけ）。

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../models/nodes/layer_node.dart';
import 'practice_project.dart';

enum TutorialStep {
  move,
  openLayers,
  hideStands,
  showStands,
  pickPoints,
  closeLayers,
  pen,
  placePoint,
  done,
}

/// 画面の側から届く操作
sealed class TutorialEvent {
  const TutorialEvent();
}

class CameraMoved extends TutorialEvent {
  const CameraMoved();
}

class LayersPanelToggled extends TutorialEvent {
  const LayersPanelToggled(this.open);
  final bool open;
}

class LayerVisibilityToggled extends TutorialEvent {
  const LayerVisibilityToggled(this.layer);
  final LayerNode layer;
}

class LayerSelected extends TutorialEvent {
  const LayerSelected(this.layer);
  final LayerNode? layer;
}

class ToolChosen extends TutorialEvent {
  const ToolChosen(this.name);
  final String name;
}

class PointPlaced extends TutorialEvent {
  const PointPlaced(this.layer);
  final LayerNode layer;
}

/// 案内先の部品
class TutorialTargets {
  static final layersButton = GlobalKey(debugLabel: 'tutorial.layersButton');
  static final penButton = GlobalKey(debugLabel: 'tutorial.penButton');
  static final standsEye = GlobalKey(debugLabel: 'tutorial.standsEye');
  static final pointsTile = GlobalKey(debugLabel: 'tutorial.pointsTile');

  static GlobalKey? of(TutorialStep step) => switch (step) {
    TutorialStep.openLayers || TutorialStep.closeLayers => layersButton,
    TutorialStep.hideStands || TutorialStep.showStands => standsEye,
    TutorialStep.pickPoints => pointsTile,
    TutorialStep.pen => penButton,
    _ => null,
  };
}

/// 練習プロジェクトのレイヤか（別のプロジェクトの同名レイヤに GlobalKey を重ねないため）
bool isPracticeLayer(LayerNode layer, String name) {
  final dir = PracticeProject.knownDir;
  if (dir == null || layer.name != name) return false;
  final path = layer.geoPackageFile.getAbsolutePath();
  return path != null && p.isWithin(dir, path);
}

/// 設定などホームの外から「チュートリアルを始めて」と頼む口。ホームが聞いていて、地図を閉じてから始める
final tutorialRequests = TutorialRequests();

class TutorialRequests extends ChangeNotifier {
  void request() => notifyListeners();
}

/// 今の手順。null は案内していないとき
final tutorialProvider = NotifierProvider<Tutorial, TutorialStep?>(Tutorial.new);

class Tutorial extends Notifier<TutorialStep?> {
  @override
  TutorialStep? build() => null;

  /// 練習プロジェクトを開いたあとに呼ぶ
  void start() => state = TutorialStep.values.first;

  void stop() => state = null;

  void next() {
    final s = state;
    if (s == null) return;
    state = s == TutorialStep.done ? null : TutorialStep.values[s.index + 1];
  }

  void report(TutorialEvent e) {
    final s = state;
    if (s == null) return;
    final ok = switch ((s, e)) {
      (TutorialStep.move, CameraMoved()) => true,
      (TutorialStep.openLayers, LayersPanelToggled(open: true)) => true,
      (TutorialStep.hideStands, LayerVisibilityToggled(:final layer)) =>
        !layer.visible && isPracticeLayer(layer, PracticeProject.standsLayer),
      (TutorialStep.showStands, LayerVisibilityToggled(:final layer)) =>
        layer.visible && isPracticeLayer(layer, PracticeProject.standsLayer),
      (TutorialStep.pickPoints, LayerSelected(:final layer)) =>
        layer != null && isPracticeLayer(layer, PracticeProject.pointsLayer),
      (TutorialStep.closeLayers, LayersPanelToggled(open: false)) => true,
      (TutorialStep.pen, ToolChosen(:final name)) => name == 'Pen',
      (TutorialStep.placePoint, PointPlaced(:final layer)) =>
        isPracticeLayer(layer, PracticeProject.pointsLayer),
      _ => false,
    };
    if (ok) next();
  }
}

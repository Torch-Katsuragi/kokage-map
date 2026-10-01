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
// チュートリアル: 練習プロジェクトの上で、本物の画面に「ここを押す」と説明を順に出す。章に分ける。
//
// 画面の側は操作が起きたら [Tutorial.report] に知らせるだけ。今の手順に合う知らせなら次へ進む。
// 案内先の部品には [TutorialTargets] の GlobalKey を付ける（レイヤの行は練習プロジェクトの中だけ）。
// 手順の文は i18n の `tutorial.text` に `<章>_<手順>_t`（見出し）と `_b`（本文）で置く。

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../models/nodes/layer_node.dart';
import 'practice_project.dart';

// ── 画面の側から届く操作 ─────────────────────

sealed class TutorialEvent {
  const TutorialEvent();
}

/// 2D / 3D の切り替え
class MapModeToggled extends TutorialEvent {
  const MapModeToggled();
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

/// レイヤの行のダブルタップ（そのレイヤへ寄る）
class LayerZoomed extends TutorialEvent {
  const LayerZoomed(this.layer);
  final LayerNode layer;
}

class ToolChosen extends TutorialEvent {
  const ToolChosen(this.name);
  final String name;
}

/// 地図の上のものを選んだ（[layer] はその持ち主）
class FeatureSelected extends TutorialEvent {
  const FeatureSelected(this.layer);
  final LayerNode? layer;
}

class AttributeTableToggled extends TutorialEvent {
  const AttributeTableToggled(this.open);
  final bool open;
}

class AttributeSaved extends TutorialEvent {
  const AttributeSaved(this.layer);
  final LayerNode? layer;
}

class PointPlaced extends TutorialEvent {
  const PointPlaced(this.layer);
  final LayerNode layer;
}

/// ペンで描いた線・面を保存した
class ShapeSaved extends TutorialEvent {
  const ShapeSaved(this.layer);
  final LayerNode layer;
}

class PhotoPickerOpened extends TutorialEvent {
  const PhotoPickerOpened();
}

class PhotosImported extends TutorialEvent {
  const PhotosImported();
}

class GpsPointRecorded extends TutorialEvent {
  const GpsPointRecorded();
}

// ── 案内先 ─────────────────────

class TutorialTargets {
  static final layersButton = GlobalKey(debugLabel: 'tutorial.layersButton');
  static final tableButton = GlobalKey(debugLabel: 'tutorial.tableButton');
  static final menuButton = GlobalKey(debugLabel: 'tutorial.menuButton');
  static final penButton = GlobalKey(debugLabel: 'tutorial.penButton');
  static final selectButton = GlobalKey(debugLabel: 'tutorial.selectButton');
  static final gpsButton = GlobalKey(debugLabel: 'tutorial.gpsButton');
  static final compassButton = GlobalKey(debugLabel: 'tutorial.compassButton');
  static final confirmButton = GlobalKey(debugLabel: 'tutorial.confirmButton');
  static final addButton = GlobalKey(debugLabel: 'tutorial.addButton');
  static final gpsRecordButton = GlobalKey(debugLabel: 'tutorial.gpsRecordButton');
  static final unlocatedPhoto = GlobalKey(debugLabel: 'tutorial.unlocatedPhoto');
  // メニュー・設定・写真の選択の中（どれも地図の上に重なる別の画面。前に出ている画面の部品だけ囲む）
  static final settingsMenuItem = GlobalKey(debugLabel: 'tutorial.settingsMenuItem');
  static final basemapSetting = GlobalKey(debugLabel: 'tutorial.basemapSetting');
  static final syncSetting = GlobalKey(debugLabel: 'tutorial.syncSetting');
  static final photoMenuItem = GlobalKey(debugLabel: 'tutorial.photoMenuItem');
  static final locatedPhoto = GlobalKey(debugLabel: 'tutorial.locatedPhoto');
  static final importButton = GlobalKey(debugLabel: 'tutorial.importButton');
  // 練習プロジェクトの中だけに付ける
  static final gpkgTile = GlobalKey(debugLabel: 'tutorial.gpkgTile');
  static final areaEye = GlobalKey(debugLabel: 'tutorial.areaEye');
  static final areaTile = GlobalKey(debugLabel: 'tutorial.areaTile');
  static final routeTile = GlobalKey(debugLabel: 'tutorial.routeTile');
  static final pointsTile = GlobalKey(debugLabel: 'tutorial.pointsTile');
  static final nameCell = GlobalKey(debugLabel: 'tutorial.nameCell');

  /// 練習プロジェクトのレイヤの行に付ける鍵（無ければ null）
  static GlobalKey? tileOf(LayerNode layer) {
    if (isPracticeLayer(layer, PracticeProject.areaLayer)) return areaTile;
    if (isPracticeLayer(layer, PracticeProject.routeLayer)) return routeTile;
    if (isPracticeLayer(layer, PracticeProject.pointsLayer)) return pointsTile;
    return null;
  }
}

/// 練習プロジェクトのレイヤか（別のプロジェクトの同名レイヤに GlobalKey を重ねないため）
bool isPracticeLayer(LayerNode? layer, String name) {
  final dir = PracticeProject.knownDir;
  if (layer == null || dir == null || layer.name != name) return false;
  final path = layer.geoPackageFile.getAbsolutePath();
  return path != null && p.isWithin(dir, path);
}

/// 練習プロジェクトの GeoPackage か
bool isPracticeGpkg(String? absPath) {
  final dir = PracticeProject.knownDir;
  return dir != null && absPath != null && p.isWithin(dir, absPath);
}

// ── 章と手順 ─────────────────────

enum TutorialChapter { view, data, record, photo, gps, yours }

class TutorialStepDef {
  const TutorialStepDef(
    this.id, {
    this.targets = const [],
    this.done,
    this.cardTop = false,
    this.cardLift = 0,
    this.waitNext = false,
    this.pickTargets,
  });

  /// 枠で囲む部品を、今の道具とレイヤ一覧の開閉から選ぶ（[targets] より優先）。
  /// 何手かかかる手順で、次に押すところへ枠を動かすため
  final List<GlobalKey> Function(String tool, bool listOpen)? pickTargets;

  final String id;

  /// 枠で囲む部品。前から順に、画面にあるものを使う
  final List<GlobalKey> targets;

  /// 済んだとみなす操作。済むまでは「とばす」。済んだら自動で次へ（[waitNext] なら「次へ」を出して待つ）。
  /// null は説明・指で触ってみる手順（はじめから「次へ」）
  final bool Function(TutorialEvent e)? done;

  /// 札を上に出す（下にパネルが開く手順）
  final bool cardTop;

  /// 下に出す札を持ち上げる量（画面の下のボタンを隠さないため）
  final double cardLift;

  /// 済んでも自動で進まず「できました」と「次へ」を出す。結果を見てほしい手順
  /// （地図の上で選ぶ・点を打つ・名前を入れる・線を引く・写真・GPS）。ボタンを押すだけの手順は自動で進む（松本 2026-10-01）
  final bool waitNext;

  bool get isInfo => done == null;
}

bool _area(LayerNode? l) => isPracticeLayer(l, PracticeProject.areaLayer);
bool _route(LayerNode? l) => isPracticeLayer(l, PracticeProject.routeLayer);
bool _points(LayerNode? l) => isPracticeLayer(l, PracticeProject.pointsLayer);

List<TutorialStepDef> stepsOf(TutorialChapter c) {
  return switch (c) {
    TutorialChapter.view => [
      // 指で動かす・拡大するは、満足するまで触ってもらう（自動で先へ進めない。松本 2026-10-01）
      const TutorialStepDef('move'),
      const TutorialStepDef('zoom'),
      TutorialStepDef('mode', targets: [TutorialTargets.compassButton], done: (e) => e is MapModeToggled),
      TutorialStepDef('north', targets: [TutorialTargets.compassButton]),
      // ≡ → 設定 → 地図・タイル。開いていけば枠もついていく（前に出ている画面の部品が先に当たる）
      TutorialStepDef('basemap',
          targets: [TutorialTargets.basemapSetting, TutorialTargets.settingsMenuItem, TutorialTargets.menuButton]),
    ],
    TutorialChapter.data => [
      const TutorialStepDef('folder'),
      TutorialStepDef('open', targets: [TutorialTargets.layersButton], done: (e) => e is LayersPanelToggled && e.open),
      TutorialStepDef('gpkg', targets: [TutorialTargets.gpkgTile]),
      TutorialStepDef('layers', targets: [TutorialTargets.areaTile]),
      TutorialStepDef('hide', targets: [TutorialTargets.areaEye],
          done: (e) => e is LayerVisibilityToggled && _area(e.layer) && !e.layer.visible),
      // 地図は自分のいる場所から始まるので、行のダブルタップでエリアのある所へ飛んでから
      // 一覧を閉じ、消えているのを自分の目で見てもらう（松本 2026-10-01）
      TutorialStepDef('zoomTo', targets: [TutorialTargets.areaTile], done: (e) => e is LayerZoomed && _area(e.layer)),
      TutorialStepDef('hiddenClose', targets: [TutorialTargets.layersButton],
          done: (e) => e is LayersPanelToggled && !e.open),
      TutorialStepDef('hiddenOpen', targets: [TutorialTargets.layersButton],
          done: (e) => e is LayersPanelToggled && e.open),
      TutorialStepDef('show', targets: [TutorialTargets.areaEye],
          done: (e) => e is LayerVisibilityToggled && _area(e.layer) && e.layer.visible),
      TutorialStepDef('close', targets: [TutorialTargets.layersButton], done: (e) => e is LayersPanelToggled && !e.open),
      TutorialStepDef('select', targets: [TutorialTargets.selectButton], done: (e) => e is ToolChosen && e.name == 'Select'),
      TutorialStepDef('pick', waitNext: true, cardTop: true, done: (e) => e is FeatureSelected && _area(e.layer)),
      TutorialStepDef('table', cardTop: true, targets: [TutorialTargets.tableButton],
          done: (e) => e is AttributeTableToggled && e.open),
      TutorialStepDef('closeTable', cardTop: true, targets: [TutorialTargets.tableButton],
          done: (e) => e is AttributeTableToggled && !e.open),
    ],
    TutorialChapter.record => [
      TutorialStepDef('open', targets: [TutorialTargets.layersButton], done: (e) => e is LayersPanelToggled && e.open),
      TutorialStepDef('pick', targets: [TutorialTargets.pointsTile], done: (e) => e is LayerSelected && _points(e.layer)),
      TutorialStepDef('close', targets: [TutorialTargets.layersButton], done: (e) => e is LayersPanelToggled && !e.open),
      TutorialStepDef('pen', targets: [TutorialTargets.penButton], done: (e) => e is ToolChosen && e.name == 'Pen'),
      TutorialStepDef('place', waitNext: true, done: (e) => e is PointPlaced && _points(e.layer)),
      TutorialStepDef('select', waitNext: true, cardTop: true,
          pickTargets: (tool, _) => tool == 'Select' ? const [] : [TutorialTargets.selectButton],
          done: (e) => e is FeatureSelected && _points(e.layer)),
      TutorialStepDef('table', cardTop: true, targets: [TutorialTargets.tableButton],
          done: (e) => e is AttributeTableToggled && e.open),
      TutorialStepDef('name', waitNext: true, cardTop: true, targets: [TutorialTargets.nameCell], done: (e) => e is AttributeSaved && _points(e.layer)),
      TutorialStepDef('closeTable', cardTop: true, targets: [TutorialTargets.tableButton],
          done: (e) => e is AttributeTableToggled && !e.open),
      TutorialStepDef('route', targets: [TutorialTargets.routeTile, TutorialTargets.layersButton],
          done: (e) => e is LayerSelected && _route(e.layer)),
      // 一覧を閉じる → ペン → 地図を押す → ✓。枠は次に押すところへ動く
      TutorialStepDef('draw', waitNext: true,
          pickTargets: (tool, listOpen) => listOpen
              ? [TutorialTargets.layersButton]
              : tool != 'Pen'
                  ? [TutorialTargets.penButton]
                  : [TutorialTargets.confirmButton],
          done: (e) => e is ShapeSaved && _route(e.layer)),
      const TutorialStepDef('area'),
    ],
    TutorialChapter.photo => [
      TutorialStepDef('open', targets: [TutorialTargets.layersButton], done: (e) => e is LayersPanelToggled && e.open),
      TutorialStepDef('add', targets: [TutorialTargets.photoMenuItem, TutorialTargets.addButton],
          done: (e) => e is PhotoPickerOpened),
      TutorialStepDef('legend', targets: [TutorialTargets.unlocatedPhoto]),
      // 位置つきの写真 → 選んだら取り込むボタン（ボタンの鍵は選んでいるときだけ付く）
      TutorialStepDef('import', waitNext: true, cardLift: 72,
          targets: [TutorialTargets.importButton, TutorialTargets.locatedPhoto], done: (e) => e is PhotosImported),
      const TutorialStepDef('done'),
    ],
    TutorialChapter.gps => [
      TutorialStepDef('tool', targets: [TutorialTargets.gpsButton], done: (e) => e is ToolChosen && e.name == 'GPS'),
      TutorialStepDef('record', waitNext: true, targets: [TutorialTargets.gpsRecordButton], done: (e) => e is GpsPointRecorded),
    ],
    TutorialChapter.yours => [
      const TutorialStepDef('folder'),
      TutorialStepDef('drive',
          targets: [TutorialTargets.syncSetting, TutorialTargets.settingsMenuItem, TutorialTargets.menuButton]),
      const TutorialStepDef('qgis'),
    ],
  };
}

// ── 状態 ─────────────────────

/// 案内の状態。[menu] のあいだは章の一覧を出す
class TutorialState {
  const TutorialState({
    required this.chapter,
    this.index = 0,
    this.menu = false,
    this.finished = const {},
    this.satisfied = false,
  });

  final TutorialChapter chapter;
  final int index;
  final bool menu;
  final Set<TutorialChapter> finished;

  /// 今の手順の操作が済んだ（「とばす」が「次へ」に替わる）
  final bool satisfied;

  TutorialStepDef get step => stepsOf(chapter)[index];
  int get stepCount => stepsOf(chapter).length;

  /// 章を終えた直後か（一覧に「おわりました」を出す）
  bool get justFinished => menu && finished.contains(chapter);

  TutorialState copyWith({
    TutorialChapter? chapter,
    int? index,
    bool? menu,
    Set<TutorialChapter>? finished,
    bool? satisfied,
  }) =>
      TutorialState(
        chapter: chapter ?? this.chapter,
        index: index ?? this.index,
        menu: menu ?? this.menu,
        finished: finished ?? this.finished,
        satisfied: satisfied ?? false, // 手順が変わったら戻す
      );
}

/// 設定などホームの外から「チュートリアルを始めて」と頼む口。ホームが聞いていて、地図を閉じてから始める
final tutorialRequests = TutorialRequests();

class TutorialRequests extends ChangeNotifier {
  void request() => notifyListeners();
}

/// 今の案内。null は案内していないとき
final tutorialProvider = NotifierProvider<Tutorial, TutorialState?>(Tutorial.new);

class Tutorial extends Notifier<TutorialState?> {
  @override
  TutorialState? build() => null;

  /// 練習プロジェクトを開くときに呼ぶ。章の一覧から始める
  void start() => state = const TutorialState(chapter: TutorialChapter.view, menu: true);

  void stop() => state = null;

  void openChapter(TutorialChapter c) =>
      state = (state ?? TutorialState(chapter: c)).copyWith(chapter: c, index: 0, menu: false);

  void showMenu() {
    final s = state;
    if (s != null) state = s.copyWith(menu: true);
  }

  /// 次の手順へ。章の終わりなら一覧に戻る
  void next() {
    final s = state;
    if (s == null || s.menu) return;
    if (s.index + 1 < s.stepCount) {
      state = s.copyWith(index: s.index + 1);
    } else {
      state = s.copyWith(menu: true, finished: {...s.finished, s.chapter});
    }
  }

  /// 操作の知らせ。今の手順に合えば次へ（[TutorialStepDef.waitNext] の手順は「済んだ」にして「次へ」を待つ）
  void report(TutorialEvent e) {
    final s = state;
    if (s == null || s.menu || s.satisfied) return;
    if (!(s.step.done?.call(e) ?? false)) return;
    if (s.step.waitNext) {
      state = s.copyWith(index: s.index, satisfied: true);
    } else {
      next();
    }
  }
}

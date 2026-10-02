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
import '../models/nodes/view_node.dart';
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

/// レイヤか View の見え方の画面を開いた
class StyleScreenOpened extends TutorialEvent {
  const StyleScreenOpened({this.view});

  /// View の見え方として開いたとき（レイヤのスタイルなら null）
  final ViewNode? view;
}

/// レイヤに View を足した
class ViewAdded extends TutorialEvent {
  const ViewAdded(this.layer);
  final LayerNode layer;
}

/// View の目を押した
class ViewVisibilityToggled extends TutorialEvent {
  const ViewVisibilityToggled(this.view);
  final ViewNode view;
}

/// 設定の「地図・タイル」を開いた
class BasemapScreenOpened extends TutorialEvent {
  const BasemapScreenOpened();
}

/// 背景の地図に層を足した（もう入っていたときも開いた時点で知らせる）
class BasemapLayerAdded extends TutorialEvent {
  const BasemapLayerAdded(this.providerId);
  final String providerId;
}

class BasemapOpacityChanged extends TutorialEvent {
  const BasemapOpacityChanged(this.providerId);
  final String providerId;
}

/// 地図の画面が前に戻ってきた（設定などを閉じた）
class MapShown extends TutorialEvent {
  const MapShown();
}

/// 情報パネルの「編集」で編集を始めた
class EditStarted extends TutorialEvent {
  const EditStarted(this.layer);
  final LayerNode? layer;
}

/// 編集のパネルで「属性」を開いた
class AttrsTabOpened extends TutorialEvent {
  const AttrsTabOpened();
}

/// 編集のパネルで属性の欄を書き換えた
class AttrEdited extends TutorialEvent {
  const AttrEdited(this.column);
  final String column;
}

/// 編集で形を 1 手動かした（頂点・移動など）
class ShapeEdited extends TutorialEvent {
  const ShapeEdited();
}

class EditUndone extends TutorialEvent {
  const EditUndone();
}

/// 編集を保存せずにやめた（取消・← ）
class EditCancelled extends TutorialEvent {
  const EditCancelled();
}

/// 編集を保存した
class EditSaved extends TutorialEvent {
  const EditSaved(this.layer);
  final LayerNode? layer;
}

/// 情報パネルの「削除」で地物を消した
class FeatureDeleted extends TutorialEvent {
  const FeatureDeleted(this.layer);
  final LayerNode? layer;
}

/// レイヤか View の見え方（スタイル）を保存した
class StyleSaved extends TutorialEvent {
  const StyleSaved(this.layer, {this.view});
  final LayerNode? layer;

  /// View の見え方を保存したとき（レイヤのスタイルなら null）
  final ViewNode? view;
}

/// 写真を選んだ（一覧の行・地図の上）
class PhotoSelected extends TutorialEvent {
  const PhotoSelected();
}

/// 写真を大きく開いた
class PhotoViewed extends TutorialEvent {
  const PhotoViewed();
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
  static final basemapAddButton = GlobalKey(debugLabel: 'tutorial.basemapAddButton');
  static final reliefOption = GlobalKey(debugLabel: 'tutorial.reliefOption');
  static final reliefOpacity = GlobalKey(debugLabel: 'tutorial.reliefOpacity');

  /// 「戻る」（いちばん上の画面のアプリバーの左端）。部品に鍵は付けず、位置で囲む（重ね絵が測る）
  static final backButton = GlobalKey(debugLabel: 'tutorial.backButton');
  // 練習プロジェクトの中だけに付ける
  static final gpkgTile = GlobalKey(debugLabel: 'tutorial.gpkgTile');
  static final areaEye = GlobalKey(debugLabel: 'tutorial.areaEye');
  static final areaTile = GlobalKey(debugLabel: 'tutorial.areaTile');
  static final routeTile = GlobalKey(debugLabel: 'tutorial.routeTile');
  static final pointsTile = GlobalKey(debugLabel: 'tutorial.pointsTile');
  static final nameCell = GlobalKey(debugLabel: 'tutorial.nameCell');

  // 情報パネル・編集のパネル
  static final editButton = GlobalKey(debugLabel: 'tutorial.editButton');
  static final attrsSegment = GlobalKey(debugLabel: 'tutorial.attrsSegment');
  static final nameField = GlobalKey(debugLabel: 'tutorial.nameField');
  static final editSaveButton = GlobalKey(debugLabel: 'tutorial.editSaveButton');
  static final editUndoButton = GlobalKey(debugLabel: 'tutorial.editUndoButton');
  static final deleteButton = GlobalKey(debugLabel: 'tutorial.deleteButton');
  static final photoPreview = GlobalKey(debugLabel: 'tutorial.photoPreview');

  // レイヤ一覧の中（練習プロジェクトだけ）
  static final areaLayerMenu = GlobalKey(debugLabel: 'tutorial.areaLayerMenu');
  static final styleMenuItem = GlobalKey(debugLabel: 'tutorial.styleMenuItem');
  static final addViewMenuItem = GlobalKey(debugLabel: 'tutorial.addViewMenuItem');

  /// 練習のエリアに足した View（いちばん上の、既定でない View）の ⋮・その「スタイル」・目
  static final newViewMenu = GlobalKey(debugLabel: 'tutorial.newViewMenu');
  static final viewStyleMenuItem = GlobalKey(debugLabel: 'tutorial.viewStyleMenuItem');
  static final newViewEye = GlobalKey(debugLabel: 'tutorial.newViewEye');
  static final photoTile = GlobalKey(debugLabel: 'tutorial.photoTile');

  /// 見え方の画面の「塗りの色」
  static final fillColorTile = GlobalKey(debugLabel: 'tutorial.fillColorTile');

  /// 見え方の画面の「面」の節（閉じていればまずここを開いてもらう）
  static final polygonSection = GlobalKey(debugLabel: 'tutorial.polygonSection');
  static GlobalKey? settingSection(String? id) => id == 'polygon' ? polygonSection : null;

  /// 設定の項目の鍵（見え方の画面の色の欄に枠を出すため。設定の画面は汎用なので鍵の名前で引く）
  static GlobalKey? settingTile(String settingKey) =>
      settingKey == 'layer_style_polygon_fill_color' ? fillColorTile : null;

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

enum TutorialChapter { view, data, style, record, fix, photo, gps, yours }

/// 「背景の地図」で重ねる地図（国土地理院の赤色立体図）
const reliefProviderId = 'gsi_red_relief';

class TutorialStepDef {
  const TutorialStepDef(
    this.id, {
    this.targets = const [],
    this.done,
    this.cardTop = false,
    this.cardLift = 0,
    this.waitNext = false,
    this.pickTargets,
    this.inEdit = false,
    this.compact = false,
  });

  /// 札を見出しだけにする（編集のパネルが同じ説明を出しているとき。地図を広く残す）
  final bool compact;

  /// 編集の最中に行う手順。編集をやめたら、手前の「編集する」の手順へ戻す
  final bool inEdit;

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

/// 線・面を描く手順の枠: 一覧が開いていれば閉じる所、ペンでなければペン、描いていれば ✓
List<GlobalKey> _drawTargets(String tool, bool listOpen) => listOpen
    ? [TutorialTargets.layersButton]
    : tool != 'Pen'
        ? [TutorialTargets.penButton]
        : [TutorialTargets.confirmButton];
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
          targets: [TutorialTargets.basemapSetting, TutorialTargets.settingsMenuItem, TutorialTargets.menuButton],
          done: (e) => e is BasemapScreenOpened),
      // 赤色立体図を重ねて透け具合を変える（松本 2026-10-01「背景地図のチュートリアルが中途半端」）
      TutorialStepDef('relief', targets: [TutorialTargets.reliefOption, TutorialTargets.basemapAddButton],
          done: (e) => e is BasemapLayerAdded && e.providerId == reliefProviderId),
      TutorialStepDef('opacity', waitNext: true, targets: [TutorialTargets.reliefOpacity],
          done: (e) => e is BasemapOpacityChanged && e.providerId == reliefProviderId),
      TutorialStepDef('backToMap', targets: [TutorialTargets.backButton], done: (e) => e is MapShown),
    ],
    TutorialChapter.data => [
      const TutorialStepDef('folder'),
      TutorialStepDef('open', targets: [TutorialTargets.layersButton], done: (e) => e is LayersPanelToggled && e.open),
      TutorialStepDef('gpkg', targets: [TutorialTargets.gpkgTile, TutorialTargets.layersButton]),
      TutorialStepDef('layers', targets: [TutorialTargets.areaTile, TutorialTargets.layersButton]),
      TutorialStepDef('hide', targets: [TutorialTargets.areaEye, TutorialTargets.layersButton],
          done: (e) => e is LayerVisibilityToggled && _area(e.layer) && !e.layer.visible),
      // 地図は自分のいる場所から始まるので、行のダブルタップでエリアのある所へ飛んでから
      // 一覧を閉じ、消えているのを自分の目で見てもらう（松本 2026-10-01）
      TutorialStepDef('zoomTo', targets: [TutorialTargets.areaTile, TutorialTargets.layersButton], done: (e) => e is LayerZoomed && _area(e.layer)),
      TutorialStepDef('hiddenClose', targets: [TutorialTargets.layersButton],
          done: (e) => e is LayersPanelToggled && !e.open),
      TutorialStepDef('hiddenOpen', targets: [TutorialTargets.layersButton],
          done: (e) => e is LayersPanelToggled && e.open),
      TutorialStepDef('show', targets: [TutorialTargets.areaEye, TutorialTargets.layersButton],
          done: (e) => e is LayerVisibilityToggled && _area(e.layer) && e.layer.visible),
      TutorialStepDef('close', targets: [TutorialTargets.layersButton], done: (e) => e is LayersPanelToggled && !e.open),
      TutorialStepDef('select', targets: [TutorialTargets.selectButton], done: (e) => e is ToolChosen && e.name == 'Select'),
      TutorialStepDef('pick', waitNext: true, cardTop: true, done: (e) => e is FeatureSelected && _area(e.layer)),
      TutorialStepDef('table', cardTop: true, targets: [TutorialTargets.tableButton],
          done: (e) => e is AttributeTableToggled && e.open),
      TutorialStepDef('closeTable', cardTop: true, targets: [TutorialTargets.tableButton],
          done: (e) => e is AttributeTableToggled && !e.open),
    ],
    // 見え方: レイヤの ⋮ → スタイル → 塗りの色（既定 View しかないときは View の行を出さない。2026-10-02）。
    // 続けて View を足し、その見え方を変えて、目で切り替える（View＝見え方をいくつも持てる）。
    // スマホの縦では一覧が地図をほぼ覆うので、色を変えるたびに一覧を閉じて見てもらう（閉じたら止まる）
    TutorialChapter.style => [
      TutorialStepDef('open', targets: [TutorialTargets.layersButton], done: (e) => e is LayersPanelToggled && e.open),
      TutorialStepDef('menu', targets: [TutorialTargets.styleMenuItem, TutorialTargets.areaLayerMenu, TutorialTargets.layersButton],
          done: (e) => e is StyleScreenOpened && e.view == null),
      TutorialStepDef('color', waitNext: true, targets: [TutorialTargets.fillColorTile, TutorialTargets.polygonSection],
          done: (e) => e is StyleSaved && e.view == null && _area(e.layer)),
      TutorialStepDef('backToMap', targets: [TutorialTargets.backButton], done: (e) => e is MapShown),
      TutorialStepDef('look', waitNext: true, targets: [TutorialTargets.layersButton],
          done: (e) => e is LayersPanelToggled && !e.open),
      TutorialStepDef('addView', targets: [TutorialTargets.addViewMenuItem, TutorialTargets.areaLayerMenu, TutorialTargets.layersButton],
          done: (e) => e is ViewAdded && _area(e.layer)),
      TutorialStepDef('viewMenu', targets: [TutorialTargets.viewStyleMenuItem, TutorialTargets.newViewMenu, TutorialTargets.layersButton],
          done: (e) => e is StyleScreenOpened && e.view != null),
      TutorialStepDef('viewColor', waitNext: true, targets: [TutorialTargets.fillColorTile, TutorialTargets.polygonSection],
          done: (e) => e is StyleSaved && e.view != null && _area(e.layer)),
      TutorialStepDef('viewBack', targets: [TutorialTargets.backButton], done: (e) => e is MapShown),
      TutorialStepDef('viewLook', waitNext: true, targets: [TutorialTargets.layersButton],
          done: (e) => e is LayersPanelToggled && !e.open),
      TutorialStepDef('viewHide', waitNext: true, targets: [TutorialTargets.newViewEye, TutorialTargets.layersButton],
          done: (e) => e is ViewVisibilityToggled && _area(e.view.layerNode) && !e.view.visible),
      TutorialStepDef('close', waitNext: true, targets: [TutorialTargets.layersButton],
          done: (e) => e is LayersPanelToggled && !e.open),
    ],
    // 記録: 点を打つ → 情報パネルの「編集」→「属性」で名前 → 保存 → 線 → 面
    TutorialChapter.record => [
      TutorialStepDef('open', targets: [TutorialTargets.layersButton], done: (e) => e is LayersPanelToggled && e.open),
      TutorialStepDef('pick', targets: [TutorialTargets.pointsTile, TutorialTargets.layersButton], done: (e) => e is LayerSelected && _points(e.layer)),
      TutorialStepDef('close', targets: [TutorialTargets.layersButton], done: (e) => e is LayersPanelToggled && !e.open),
      TutorialStepDef('pen', targets: [TutorialTargets.penButton], done: (e) => e is ToolChosen && e.name == 'Pen'),
      TutorialStepDef('place', waitNext: true, done: (e) => e is PointPlaced && _points(e.layer)),
      TutorialStepDef('select', cardTop: true,
          pickTargets: (tool, _) => tool == 'Select' ? const [] : [TutorialTargets.selectButton],
          done: (e) => e is FeatureSelected && _points(e.layer)),
      TutorialStepDef('edit', cardTop: true, targets: [TutorialTargets.editButton],
          done: (e) => e is EditStarted && _points(e.layer)),
      TutorialStepDef('attrs', inEdit: true, cardTop: true, targets: [TutorialTargets.attrsSegment], done: (e) => e is AttrsTabOpened),
      // パネルが上まで広がっているので、札は下の「保存」のすぐ上に（上に出すとパネルの見出しを隠す）
      TutorialStepDef('name', inEdit: true, cardLift: 72, targets: [TutorialTargets.nameField],
          done: (e) => e is AttrEdited && e.column == 'name'),
      TutorialStepDef('save', inEdit: true, waitNext: true, cardLift: 72, targets: [TutorialTargets.editSaveButton],
          done: (e) => e is EditSaved && _points(e.layer)),
      TutorialStepDef('route', targets: [TutorialTargets.routeTile, TutorialTargets.layersButton],
          done: (e) => e is LayerSelected && _route(e.layer)),
      // 一覧を閉じる → ペン → 地図を押す → ✓。枠は次に押すところへ動く
      TutorialStepDef('draw', waitNext: true, pickTargets: _drawTargets, done: (e) => e is ShapeSaved && _route(e.layer)),
      TutorialStepDef('area', targets: [TutorialTargets.areaTile, TutorialTargets.layersButton],
          done: (e) => e is LayerSelected && _area(e.layer)),
      TutorialStepDef('drawArea', waitNext: true, pickTargets: _drawTargets,
          done: (e) => e is ShapeSaved && _area(e.layer)),
    ],
    // 直す・消す: エリアを選んで編集 → 頂点を動かす → 元に戻す → もう一度動かして保存 → エリアB を消す
    TutorialChapter.fix => [
      TutorialStepDef('select', targets: [TutorialTargets.selectButton], done: (e) => e is ToolChosen && e.name == 'Select'),
      TutorialStepDef('pick', cardTop: true, done: (e) => e is FeatureSelected && _area(e.layer)),
      TutorialStepDef('edit', cardTop: true, targets: [TutorialTargets.editButton],
          done: (e) => e is EditStarted && _area(e.layer)),
      TutorialStepDef('drag', inEdit: true, cardTop: true, compact: true, waitNext: true, done: (e) => e is ShapeEdited),
      TutorialStepDef('undo', inEdit: true, cardTop: true, compact: true, targets: [TutorialTargets.editUndoButton], done: (e) => e is EditUndone),
      TutorialStepDef('again', inEdit: true, cardTop: true, compact: true, waitNext: true, done: (e) => e is ShapeEdited),
      TutorialStepDef('save', inEdit: true, cardTop: true, compact: true, targets: [TutorialTargets.editSaveButton], done: (e) => e is EditSaved && _area(e.layer)),
      TutorialStepDef('pickB', cardTop: true, done: (e) => e is FeatureSelected && _area(e.layer)),
      TutorialStepDef('delete', waitNext: true, targets: [TutorialTargets.deleteButton],
          done: (e) => e is FeatureDeleted && _area(e.layer)),
    ],
    TutorialChapter.photo => [
      TutorialStepDef('open', targets: [TutorialTargets.layersButton], done: (e) => e is LayersPanelToggled && e.open),
      TutorialStepDef('add', targets: [TutorialTargets.photoMenuItem, TutorialTargets.addButton],
          done: (e) => e is PhotoPickerOpened),
      TutorialStepDef('legend', targets: [TutorialTargets.unlocatedPhoto]),
      // 位置つきの写真 → 選んだら取り込むボタン（ボタンの鍵は選んでいるときだけ付く）
      TutorialStepDef('import', waitNext: true, cardLift: 72,
          targets: [TutorialTargets.importButton, TutorialTargets.locatedPhoto], done: (e) => e is PhotosImported),
      // 取り込んだ写真を一覧から選ぶ（その場所へ地図が動く）→ パネルの写真を押して大きく
      TutorialStepDef('pick', targets: [TutorialTargets.photoTile, TutorialTargets.layersButton], done: (e) => e is PhotoSelected),
      TutorialStepDef('view', cardTop: true, targets: [TutorialTargets.photoPreview], done: (e) => e is PhotoViewed),
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

/// いちばん上の画面を見張る（MaterialApp の navigatorObservers に入れる）。
/// 「戻る」を囲むか・地図に戻ったかの判断に使う
final tutorialRoutes = TutorialRouteObserver();

class TutorialRouteObserver extends NavigatorObserver {
  /// いちばん上の画面
  final top = ValueNotifier<Route<dynamic>?>(null);

  /// 地図の画面（地図が組まれたときに入れる）
  Route<dynamic>? mapRoute;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => top.value = route;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => top.value = previousRoute;
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (top.value == route) top.value = previousRoute;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (top.value == oldRoute) top.value = newRoute;
  }

  /// 地図の上に別の画面（設定など。メニューやダイアログは数えない）が重なっているか
  bool get pageOverMap {
    final t = top.value;
    return t is PageRoute && mapRoute != null && t != mapRoute;
  }
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
    if (s == null || s.menu) return;
    // 編集の最中の手順で編集をやめたら、手前の「編集する」へ戻る（その先へは編集しないと進めない）
    if (e is EditCancelled && s.step.inEdit) {
      final steps = stepsOf(s.chapter);
      final back = steps.lastIndexWhere((d) => d.id == 'edit', s.index);
      if (back >= 0) state = s.copyWith(index: back);
      return;
    }
    if (s.satisfied) return;
    if (!(s.step.done?.call(e) ?? false)) return;
    if (s.step.waitNext) {
      state = s.copyWith(index: s.index, satisfied: true);
    } else {
      next();
    }
  }
}

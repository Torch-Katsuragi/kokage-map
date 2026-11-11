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
// Root Maps: フォルダメタデータモデル
// 各フォルダの設定。JSON にして `<dir名>.qgs` の `kokage/meta` に置く（読み書きは QgsMetaStore）

import 'dart:convert';

import '../core/fs/k_file_system.dart';
import '../utils/app_logger.dart';
import 'kmeta/kmeta_layer_style.dart';
import 'kmeta/kmeta_layout.dart';
import 'kmeta/kmeta_sync.dart';
import 'kmeta/kmeta_view.dart';
import 'kmeta/kmeta_visibility.dart';
import 'layer_join.dart';
import 'qgis_form.dart';

export 'kmeta/kmeta_layer_style.dart';
export 'kmeta/kmeta_layout.dart';
export 'kmeta/kmeta_sync.dart';
export 'kmeta/kmeta_view.dart';
export 'kmeta/kmeta_visibility.dart';

/// 旧フォルダ設定のファイル名。2026-09-29 に `.qgs` へ移した。
/// 残っていれば読んで `.qgs` に移す（[KMeta.loadFromFile]・QgsMetaStore.read）
const String kMetaFileName = '.kmeta.json';

/// 現在のスキーマバージョン
const int kMetaSchemaVersion = 2;

/// フォルダメタデータ（フォルダ設定（`.qgs`））
class KMeta {
  /// スキーマバージョン
  final int version;

  /// 可視性設定
  final KMetaVisibility visibility;

  /// スタイル設定
  final KMetaStyles styles;

  /// レイアウト設定
  final KMetaLayout layout;

  /// 同期設定
  final KMetaSync sync;

  /// 画像オーバーレイ設定（画像ファイル名 → 変換パラメータ）
  final Map<String, KMetaImageOverlay> imageOverlays;

  /// View定義（レイヤキー `gpkgName/layerName` → View の並び）
  ///
  /// **順序に意味がある。** 同一レイヤ内の z順はこのリストの順。
  /// キーが無い＝そのレイヤに View が定義されていない、という意味で、
  /// そのときアプリは「既定のView」を1つだけ暗黙に持つ（`LayerNode` 参照）。
  final Map<String, List<KMetaView>> views;

  /// QGIS の属性フォームの設定（レイヤキー → 設定）。`.qgs` の `<fieldConfiguration>` などを読んだ写しで、
  /// `.qgs` の側には書き戻さない（QGIS の持ち物。[[docs/technical/qgis-interop#属性フォーム（編集ウィジェット・既定値・制約）]]）
  final Map<String, QgisForm> forms;

  /// 表の結合（レイヤキー → 結合の並び）。`.qgs` の `<vectorjoins>` と往復する
  /// （[[docs/technical/qgis-interop#表の結合（属性 CSV と図面レイヤ）]]）
  final Map<String, List<LayerJoin>> joins;

  const KMeta({
    this.version = kMetaSchemaVersion,
    this.visibility = const KMetaVisibility(),
    this.styles = const KMetaStyles(),
    this.layout = const KMetaLayout(),
    this.sync = const KMetaSync(),
    this.imageOverlays = const {},
    this.views = const {},
    this.forms = const {},
    this.joins = const {},
  });

  /// 空のメタデータ
  static const KMeta empty = KMeta();

  /// JSONからパース
  factory KMeta.fromJson(Map<String, dynamic> json) {
    // 画像オーバーレイをパース
    final overlaysJson = json['imageOverlays'] as Map<String, dynamic>?;
    final overlays = <String, KMetaImageOverlay>{};
    if (overlaysJson != null) {
      for (final entry in overlaysJson.entries) {
        overlays[entry.key] = KMetaImageOverlay.fromJson(
          entry.value as Map<String, dynamic>,
        );
      }
    }

    // View定義をパース
    final viewsJson = json['views'] as Map<String, dynamic>?;
    final views = <String, List<KMetaView>>{};
    if (viewsJson != null) {
      for (final entry in viewsJson.entries) {
        final list = entry.value;
        if (list is! List) continue;
        views[entry.key] = [
          for (final v in list)
            if (v is Map<String, dynamic>) KMetaView.fromJson(v),
        ];
      }
    }

    final formsJson = json['forms'] as Map<String, dynamic>?;
    final forms = <String, QgisForm>{
      for (final e in formsJson?.entries ?? const <MapEntry<String, dynamic>>[])
        e.key: ?QgisForm.tryFromJson(e.value),
    };

    final joinsJson = json['joins'] as Map<String, dynamic>?;
    final joins = <String, List<LayerJoin>>{
      for (final e in joinsJson?.entries ?? const <MapEntry<String, dynamic>>[])
        if (e.value is List) e.key: [for (final j in e.value as List) ?LayerJoin.tryFromJson(j)],
    }..removeWhere((_, v) => v.isEmpty);

    return KMeta(
      version: json['version'] as int? ?? kMetaSchemaVersion,
      visibility: KMetaVisibility.fromJson(
        json['visibility'] as Map<String, dynamic>?,
      ),
      styles: KMetaStyles.fromJson(json['styles'] as Map<String, dynamic>?),
      layout: KMetaLayout.fromJson(json['layout'] as Map<String, dynamic>?),
      sync: KMetaSync.fromJson(json['sync'] as Map<String, dynamic>?),
      imageOverlays: overlays,
      views: views,
      forms: forms,
      joins: joins,
    );
  }

  /// JSONへシリアライズ
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'version': version};
    if (!visibility.isEmpty) json['visibility'] = visibility.toJson();
    if (!styles.isEmpty) json['styles'] = styles.toJson();
    if (!layout.isEmpty) json['layout'] = layout.toJson();
    if (!sync.isEmpty) json['sync'] = sync.toJson();
    if (imageOverlays.isNotEmpty) {
      json['imageOverlays'] = imageOverlays.map(
        (k, v) => MapEntry(k, v.toJson()),
      );
    }
    if (views.isNotEmpty) {
      json['views'] = views.map(
        (k, v) => MapEntry(k, [for (final view in v) view.toJson()]),
      );
    }
    if (forms.isNotEmpty) json['forms'] = forms.map((k, v) => MapEntry(k, v.toJson()));
    if (joins.isNotEmpty) json['joins'] = joins.map((k, v) => MapEntry(k, [for (final j in v) j.toJson()]));
    return json;
  }

  /// ファイルから読み込み
  static Future<KMeta?> loadFromFile(String folderPath) async {
    try {
      final path = '$folderPath/$kMetaFileName';
      if (!await fs.exists(path)) {
        return null;
      }
      final content = await fs.readAsString(path);
      final json = jsonDecode(content) as Map<String, dynamic>;
      return KMeta.fromJson(json);
    } catch (e) {
      AppLogger.debug('[KMeta] Error loading from $folderPath: $e');
      return null;
    }
  }

  /// 空かどうか
  bool get isEmpty =>
      visibility.isEmpty &&
      styles.isEmpty &&
      layout.isEmpty &&
      sync.isEmpty &&
      imageOverlays.isEmpty &&
      views.isEmpty &&
      forms.isEmpty &&
      joins.isEmpty;

  /// レイヤのView定義。定義が無ければ空リスト（＝既定のView1枚とみなす側の責務）
  List<KMetaView> getViews(String layerKey) => views[layerKey] ?? const [];

  /// Viewの可視状態を取得
  /// [viewKey] は `gpkgName/layerName/viewName` 形式
  bool? getViewVisibility(String viewKey) => visibility.views[viewKey];

  /// 特定レイヤーのスタイルを取得（デフォルト適用済み）
  /// [layerKey] はgpkgName/layerName形式（例: "survey.gpkg/points"）
  KMetaLayerStyle? getLayerStyle(String layerKey) {
    final layerStyle = styles.layers[layerKey];
    if (layerStyle != null) {
      return layerStyle.mergeWith(styles.defaultStyle);
    }
    return styles.defaultStyle;
  }

  /// レイヤーの可視状態を取得
  bool? getLayerVisibility(String layerName) => visibility.layers[layerName];

  /// コピーを作成（一部設定を変更）
  KMeta copyWith({
    int? version,
    KMetaVisibility? visibility,
    KMetaStyles? styles,
    KMetaLayout? layout,
    KMetaSync? sync,
    Map<String, KMetaImageOverlay>? imageOverlays,
    Map<String, List<KMetaView>>? views,
    Map<String, QgisForm>? forms,
    Map<String, List<LayerJoin>>? joins,
  }) {
    return KMeta(
      version: version ?? this.version,
      visibility: visibility ?? this.visibility,
      styles: styles ?? this.styles,
      layout: layout ?? this.layout,
      sync: sync ?? this.sync,
      imageOverlays: imageOverlays ?? this.imageOverlays,
      views: views ?? this.views,
      forms: forms ?? this.forms,
      joins: joins ?? this.joins,
    );
  }
}

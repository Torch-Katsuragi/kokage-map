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
/// `.qgs`（QGISプロジェクト）に書き出す内容を、XMLと切り離して表した型。
///
/// > [!IMPORTANT] `.qgs` は生成物であって、正典ではない
/// > いつでも dir 構造 + `.kmeta.json` から再生成できる。ビルド成果物として扱う。
/// > QGIS側で編集しても、次の生成で上書きされる。
/// > 設計は [[docs/technical/project-format-design]]。
///
/// XMLの組み立て（[[qgs_writer]]）とツリーの走査（[[qgs_project_builder]]）を
/// この型で分けている。おかげでXML側はDBもファイルシステムも要らずにテストできる。
library;

import 'package:flutter/material.dart';

import '../../models/geometry_type.dart';

/// こかげマップ のノードが QGIS の何になるか。
///
/// | こかげマップ | QGIS |
/// |---|---|
/// | dir | レイヤグループ |
/// | GeoPackage | レイヤグループ |
/// | Layer | レイヤグループ |
/// | **View** | **レイヤ** |
///
/// View だけが QGIS のレイヤになり、それ以外は全てグループ。この 1:1 が
/// 成り立つから `.qgs` を書いても破綻しない。
sealed class QgsTreeNode {
  const QgsTreeNode();
}

/// QGIS のレイヤグループ（こかげマップ の dir / GeoPackage / Layer）
class QgsGroup extends QgsTreeNode {
  const QgsGroup({
    required this.name,
    required this.children,
    this.visible = true,
    this.expanded = true,
  });

  final String name;
  final List<QgsTreeNode> children;
  final bool visible;

  /// レイヤパネルで開いているか（こかげマップ の dir の展開状態）
  final bool expanded;
}

/// 別プロジェクト（子 dir の `.qgs`）を埋め込むグループ。
///
/// QGIS の「他プロジェクトのレイヤ／グループを埋め込む」機能そのもの
/// （`layer-tree-group embedded="1" embedded_project="./写真/写真.qgs"`）。
/// 子要素は書かない。QGIS が読込時に子プロジェクトから再構成する。
/// `<projectlayers>` には `<maplayer embedded="1" project=... id=.../>` のスタブが要る。
class QgsEmbeddedGroup extends QgsTreeNode {
  const QgsEmbeddedGroup({
    required this.name,
    required this.projectPath,
    required this.layerIds,
    this.visible = true,
    this.expanded = true,
  });

  final String name;

  /// 親の `.qgs` から見た子 `.qgs` の相対パス（`./写真/写真.qgs`）
  final String projectPath;

  /// 子プロジェクトのレイヤ id（スタブに書く）
  final List<String> layerIds;

  final bool visible;
  final bool expanded;
}

/// QGIS のレイヤ（こかげマップ の View）
class QgsLayer extends QgsTreeNode {
  const QgsLayer({
    required this.id,
    required this.name,
    required this.dataSourcePath,
    required this.tableName,
    required this.geometryType,
    required this.crs,
    this.subset,
    this.style,
    this.visible = true,
  });

  /// プロジェクト内で一意なID。`layer-tree-layer` と `maplayer` を結ぶ。
  ///
  /// ⚠ **決定的に作ること。** 生成のたびに変わると `.qgs` の差分が毎回出て、
  /// Drive同期が無駄に動く。
  final String id;

  /// QGIS上のレイヤ名（＝View名）
  final String name;

  /// `.qgs` からの相対パス（例: `./林小班.gpkg`）
  final String dataSourcePath;

  /// GeoPackage内のテーブル名
  final String tableName;

  final GeometryType geometryType;

  final QgsCrs crs;

  /// subset string（SQLのWHERE句）。null なら絞り込み無し。
  final String? subset;

  /// 見た目。null ならQGISの既定シンボルに任せる。
  final QgsStyle? style;

  final bool visible;

  /// OGRプロバイダのデータソース文字列。
  ///
  /// QGIS は GeoPackage のレイヤ指定とフィルタをこの1本の文字列に詰める。
  String get dataSourceUri {
    final buffer = StringBuffer('$dataSourcePath|layername=$tableName');
    if (subset != null && subset!.trim().isNotEmpty) {
      buffer.write('|subset=${subset!.trim()}');
    }
    return buffer.toString();
  }
}

/// レイヤの座標参照系。gpkg から読んだものをそのまま渡す。
class QgsCrs {
  const QgsCrs({
    required this.authId,
    required this.srid,
    this.description,
    this.wkt,
    this.proj4,
    this.isGeographic = true,
  });

  /// WGS84。CRSを解決できなかったときの逃げ場でもある。
  static const wgs84 = QgsCrs(
    authId: 'EPSG:4326',
    srid: 4326,
    description: 'WGS 84',
    proj4: '+proj=longlat +datum=WGS84 +no_defs',
  );

  final String authId;
  final int srid;
  final String? description;
  final String? wkt;
  final String? proj4;
  final bool isGeographic;
}

/// QGIS のシンプルシンボルに落とせるぶんの見た目。
///
/// こかげマップ のスタイルは maplibre 向けの値なので、そのままでは QGIS に渡らない
/// （単位が px と mm で違う）。変換は [[qgs_writer]] で行う。
class QgsStyle {
  const QgsStyle({
    this.pointColor,
    this.pointSizePx,
    this.lineColor,
    this.lineWidthPx,
    this.fillColor,
    this.fillOpacity,
    this.strokeColor,
    this.strokeWidthPx,
    this.strokeOpacity,
    this.labelEnabled,
    this.labelField,
    this.labelFontSizePt,
    this.labelColor,
    this.labelHaloColor,
  });

  /// 簡易ラベル（QGIS の `labeling type="simple"`）。
  /// [labelEnabled] が true で [labelField] があるときだけ書く
  final bool? labelEnabled;
  final String? labelField;
  final double? labelFontSizePt;
  final Color? labelColor;
  final Color? labelHaloColor;

  bool get hasLabel => labelEnabled == true && (labelField?.isNotEmpty ?? false);

  final Color? pointColor;
  final double? pointSizePx;
  final Color? lineColor;
  final double? lineWidthPx;
  final Color? fillColor;
  final double? fillOpacity;
  final Color? strokeColor;
  final double? strokeWidthPx;
  final double? strokeOpacity;

  bool get isEmpty =>
      pointColor == null &&
      pointSizePx == null &&
      lineColor == null &&
      lineWidthPx == null &&
      fillColor == null &&
      fillOpacity == null &&
      strokeColor == null &&
      strokeWidthPx == null &&
      strokeOpacity == null;
}

/// 書き出す `.qgs` 1本ぶん。
class QgsProject {
  const QgsProject({
    required this.name,
    required this.root,
    this.projectCrs = QgsCrs.wgs84,
    this.skipped = const [],
  });

  final String name;

  /// レイヤツリーの最上位（ルートdir自身はグループにしない）
  final List<QgsTreeNode> root;

  final QgsCrs projectCrs;

  /// 書き出せなかったもの。
  ///
  /// > [!WARNING] 捨てるのはいい。黙って捨てるのがまずい
  /// > 呼び出し側は必ずユーザーに見せること。
  final List<String> skipped;

  /// 埋め込みグループを深さ優先で集める（スタブと layerorder に使う）
  List<QgsEmbeddedGroup> get embeddedGroups {
    final result = <QgsEmbeddedGroup>[];
    void walk(List<QgsTreeNode> nodes) {
      for (final node in nodes) {
        switch (node) {
          case QgsGroup(:final children):
            walk(children);
          case QgsEmbeddedGroup():
            result.add(node);
          case QgsLayer():
            break;
        }
      }
    }

    walk(root);
    return result;
  }

  /// ツリーを深さ優先で辿って、レイヤだけを順に返す。
  ///
  /// QGIS の `<projectlayers>` と `<layerorder>` はこの順で並べる。
  List<QgsLayer> get layers {
    final result = <QgsLayer>[];
    void walk(List<QgsTreeNode> nodes) {
      for (final node in nodes) {
        switch (node) {
          case QgsGroup(:final children):
            walk(children);
          case QgsLayer():
            result.add(node);
          case QgsEmbeddedGroup():
            break; // 子プロジェクトのもの。自分のレイヤではない
        }
      }
    }

    walk(root);
    return result;
  }
}

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
/// [QgsProject] を `.qgs`（QGISプロジェクトXML）にする。
///
/// > [!NOTE] 全部は書かない
/// > QGISプロジェクトXMLは巨大だが、**使う部分だけでもQGISは開ける**。
/// > ここが書くのはレイヤツリー・データソース参照・subset string・レンダラだけ。
/// > 印刷レイアウト、リレーション、スナップ設定などは書かない。
///
/// > [!IMPORTANT] 書くときは厳格に
/// > こかげマップ が出すものは規格に沿わせる（QGISでそのまま開ける）。
/// > 寛容さは読む側（インポータ）の話で、こちらには持ち込まない。
library;

import 'package:flutter/material.dart';
import 'package:xml/xml.dart';

import '../../models/geometry_type.dart';
import 'qgs_model.dart';

/// 生成する `.qgs` の想定QGISバージョン。
///
/// QGIS はこれより新しければ普通に開く。古いQGISで開くと警告が出るが読める。
const String kQgsVersion = '3.34.0-Prizren';

/// 旧・既定のファイル名（2026-09-06 まで）。
///
/// いまは `<dir名>.qgs`（[qgsFileNameFor]）。これが残っていたら新名に改名して引き継ぐ。
const String kLegacyQgsFileName = 'project.qgs';

/// dir ごとの `.qgs` のファイル名。`<dir名>.qgs`。
///
/// QGIS ユーザーがファイル一覧で「どの現場のプロジェクトか」を名前で分かるようにする。
/// dir 改名との追従は印（`kokage/dirName`）で判定する
/// （[[docs/technical/project-format-design#正典を `.qgs` に移す（2026-09-06 決定・設計）]]）。
String qgsFileNameFor(String dirName) => '$dirName.qgs';

/// px → mm（QGISのシンボル単位はMM）。96dpi 相当。
///
/// ⚠ こかげマップ のスタイル値は maplibre 向けの画面ピクセルなので、厳密な対応は無い。
/// **見た目が近くなるだけの近似**であって、往復しても同じ値には戻らない。
const double _kPxToMm = 25.4 / 96;

class QgsWriter {
  const QgsWriter();

  // =============================================
  // 断片（DOM 保持型の更新で使う）
  // =============================================
  //
  // [QgsDocument] は既存の `.qgs` を読んで自分の管轄のノードだけ差し替える。
  // 「無かったから足す」ときの要素はここで作る。組み立てのルールを1箇所に保つため、
  // 中身は下の private 関数と共通。

  /// `<maplayer>` 1本ぶんの要素
  XmlElement mapLayerElement(QgsLayer layer) =>
      _fragment((b) => _writeMapLayer(b, layer));

  /// `<renderer-v2>`。スタイルが無ければ null
  XmlElement? rendererElement(QgsLayer layer) {
    if (layer.style == null || layer.style!.isEmpty) return null;
    return _fragment((b) => _writeRenderer(b, layer));
  }

  /// `<layer-tree-layer>`
  XmlElement treeLayerElement(QgsLayer layer) =>
      _fragment((b) => _writeTreeNode(b, layer));

  /// ラスタの `<maplayer>`
  XmlElement rasterMapLayerElement(QgsRasterLayer layer) =>
      _fragment((b) => _writeRasterMapLayer(b, layer));

  /// ラスタの `<layer-tree-layer>`
  XmlElement treeRasterLayerElement(QgsRasterLayer layer) =>
      _fragment((b) => _writeTreeNode(b, layer));

  /// 子を持たない `<layer-tree-group>`
  XmlElement treeGroupElement(String name, {bool visible = true}) => _fragment(
    (b) => _writeTreeNode(b, QgsGroup(name: name, children: const [], visible: visible)),
  );

  XmlElement _fragment(void Function(XmlBuilder) write) {
    final b = XmlBuilder();
    write(b);
    // fragment が親になっているので、別の文書に足せるよう切り離す
    return b.buildFragment().childElements.first.copy();
  }

  /// QGIS の色表記 `R,G,B,A`（各0-255）
  static String formatColor(Color color, {double? opacity}) =>
      const QgsWriter()._color(color, opacity: opacity);

  /// px → QGIS のシンボル単位（MM）
  static String formatMm(double px) => const QgsWriter()._mm(px);

  /// 可視性属性の値
  static String checkedValue(bool visible) => const QgsWriter()._checked(visible);

  /// `.qgs` の中身を作る。
  String build(QgsProject project) {
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'qgis',
      attributes: {'projectname': project.name, 'version': kQgsVersion},
      nest: () {
        builder.element('homePath', attributes: {'path': ''});
        builder.element('title', nest: project.name);

        // 相対パスで書く。連携dirを丸ごと渡された人が、そのdirだけで開けるように。
        builder.element(
          'properties',
          nest: () {
            builder.element(
              'Paths',
              nest: () {
                builder.element(
                  'Absolute',
                  attributes: {'type': 'bool'},
                  nest: 'false',
                );
              },
            );
          },
        );

        builder.element(
          'projectCrs',
          nest: () => _writeCrs(builder, project.projectCrs),
        );

        _writeLayerTree(builder, project);
        _writeProjectLayers(builder, project);
        _writeLayerOrder(builder, project);
      },
    );

    return builder.buildDocument().toXmlString(pretty: true, indent: '  ');
  }

  // =============================================
  // レイヤツリー
  // =============================================

  void _writeLayerTree(XmlBuilder builder, QgsProject project) {
    builder.element(
      'layer-tree-group',
      nest: () {
        for (final node in project.root) {
          _writeTreeNode(builder, node);
        }
        // custom-order は「ツリーと違う描画順」の指定。こかげマップ は
        // dir構造がそのまま z順なので使わない。
        builder.element('custom-order', attributes: {'enabled': '0'});
      },
    );
  }

  void _writeTreeNode(XmlBuilder builder, QgsTreeNode node) {
    switch (node) {
      case QgsGroup(:final name, :final children, :final visible, :final expanded):
        builder.element(
          'layer-tree-group',
          attributes: {
            'name': name,
            'expanded': expanded ? '1' : '0',
            'checked': _checked(visible),
          },
          nest: () {
            builder.element('customproperties', nest: () {});
            for (final child in children) {
              _writeTreeNode(builder, child);
            }
          },
        );
      case QgsEmbeddedGroup(:final name, :final projectPath, :final visible, :final expanded):
        builder.element(
          'layer-tree-group',
          attributes: {
            'name': name,
            'expanded': expanded ? '1' : '0',
            'checked': _checked(visible),
            'embedded': '1',
            'embedded_project': projectPath,
          },
        );
      case QgsLayer():
        builder.element(
          'layer-tree-layer',
          attributes: {
            'id': node.id,
            'name': node.name,
            'source': node.dataSourceUri,
            'providerKey': 'ogr',
            'expanded': '1',
            'checked': _checked(node.visible),
            'patch_size': '-1,-1',
          },
          nest: () {
            builder.element('customproperties', nest: () {});
          },
        );
      case QgsRasterLayer():
        builder.element(
          'layer-tree-layer',
          attributes: {
            'id': node.id,
            'name': node.name,
            'source': node.dataSourcePath,
            'providerKey': 'gdal',
            'expanded': '1',
            'checked': _checked(node.visible),
            'patch_size': '-1,-1',
          },
          nest: () {
            builder.element('customproperties', nest: () {});
          },
        );
    }
  }

  String _checked(bool visible) => visible ? 'Qt::Checked' : 'Qt::Unchecked';

  // =============================================
  // レイヤ本体
  // =============================================

  void _writeProjectLayers(XmlBuilder builder, QgsProject project) {
    final layers = project.layers;
    builder.element(
      'projectlayers',
      nest: () {
        for (final layer in layers) {
          _writeMapLayer(builder, layer);
        }
        for (final raster in project.rasterLayers) {
          _writeRasterMapLayer(builder, raster);
        }
        for (final group in project.embeddedGroups) {
          for (final id in group.layerIds) {
            _writeEmbeddedStub(builder, group.projectPath, id);
          }
        }
      },
    );
  }

  /// ラスタ（GeoTIFF）の `<maplayer>`。レンダラ（`<pipe>`）は書かない。
  /// QGIS は読込時にプロバイダを作った段階で既定のレンダラを付けるので、無くても開ける
  void _writeRasterMapLayer(XmlBuilder builder, QgsRasterLayer layer) {
    builder.element(
      'maplayer',
      attributes: {
        'type': 'raster',
        'hasScaleBasedVisibilityFlag': '0',
        'minScale': '1e+08',
        'maxScale': '0',
        'refreshOnNotifyEnabled': '0',
        'autoRefreshMode': 'Disabled',
        'styleCategories': 'AllStyleCategories',
      },
      nest: () {
        builder.element('id', nest: layer.id);
        builder.element('datasource', nest: layer.dataSourcePath);
        builder.element('layername', nest: layer.name);
        builder.element('srs', nest: () => _writeCrs(builder, layer.crs));
        builder.element('provider', nest: 'gdal');
      },
    );
  }

  /// 埋め込みレイヤのスタブ。QGIS は読込時に子プロジェクトから本体を取る
  void _writeEmbeddedStub(XmlBuilder builder, String projectPath, String id) {
    builder.element(
      'maplayer',
      attributes: {'embedded': '1', 'project': projectPath, 'id': id},
    );
  }

  /// 埋め込みスタブの断片
  XmlElement embeddedStubElement(String projectPath, String id) =>
      _fragment((b) => _writeEmbeddedStub(b, projectPath, id));

  /// 埋め込みグループの断片
  XmlElement embeddedGroupElement(QgsEmbeddedGroup group) =>
      _fragment((b) => _writeTreeNode(b, group));

  void _writeMapLayer(XmlBuilder builder, QgsLayer layer) {
    builder.element(
      'maplayer',
      attributes: {
        'type': 'vector',
        'geometry': _geometryName(layer.geometryType),
        'hasScaleBasedVisibilityFlag': '0',
        'minScale': '1e+08',
        'maxScale': '0',
        'readOnly': '0',
        'refreshOnNotifyEnabled': '0',
        'autoRefreshMode': 'Disabled',
        'styleCategories': 'AllStyleCategories',
        'labelsEnabled': (layer.style?.hasLabel ?? false) ? '1' : '0',
      },
      nest: () {
        builder.element('id', nest: layer.id);
        builder.element('datasource', nest: layer.dataSourceUri);
        builder.element('layername', nest: layer.name);
        builder.element(
          'provider',
          attributes: {'encoding': 'UTF-8'},
          nest: 'ogr',
        );
        builder.element('srs', nest: () => _writeCrs(builder, layer.crs));
        _writeRenderer(builder, layer);
        _writeLabeling(builder, layer);
        // レイヤ名の表示に使う。空でよいが、無いと警告を出すQGISがある。
        builder.element('previewExpression', nest: '');
      },
    );
  }

  /// `<layerorder>` は描画順（先頭が最前面）。
  ///
  /// z順は **(dir由来の順) → (Layer内のView順)** で決まるので、
  /// ツリーの深さ優先の並びをそのまま使えばよい。
  void _writeLayerOrder(XmlBuilder builder, QgsProject project) {
    builder.element(
      'layerorder',
      nest: () {
        for (final id in project.orderedLayerIds) {
          builder.element('layer', attributes: {'id': id});
        }
        for (final group in project.embeddedGroups) {
          for (final id in group.layerIds) {
            builder.element('layer', attributes: {'id': id});
          }
        }
      },
    );
  }

  // =============================================
  // CRS
  // =============================================

  void _writeCrs(XmlBuilder builder, QgsCrs crs) {
    builder.element(
      'spatialrefsys',
      nest: () {
        // srsid（QGIS内部ID）は書かない。authid から引き直させる。
        // 環境ごとに違う数字を書き込むと、別のPCで別のCRSになりうる。
        if (crs.wkt != null) builder.element('wkt', nest: crs.wkt);
        if (crs.proj4 != null) builder.element('proj4', nest: crs.proj4);
        builder.element('srid', nest: '${crs.srid}');
        builder.element('authid', nest: crs.authId);
        builder.element('description', nest: crs.description ?? crs.authId);
        builder.element(
          'geographicflag',
          nest: crs.isGeographic ? 'true' : 'false',
        );
      },
    );
  }

  // =============================================
  // レンダラ
  // =============================================

  String _geometryName(GeometryType type) => switch (type) {
    GeometryType.point => 'Point',
    GeometryType.linestring => 'Line',
    GeometryType.polygon => 'Polygon',
  };

  /// 単一シンボルのレンダラを書く。
  ///
  /// スタイルが無いレイヤには書かない。QGIS がランダムな既定シンボルを割り当てる
  /// （そのほうが、中途半端なレンダラで読み込みに失敗するより安全）。
  void _writeRenderer(XmlBuilder builder, QgsLayer layer) {
    final style = layer.style;
    if (style == null || style.isEmpty) return;

    builder.element(
      'renderer-v2',
      attributes: {
        'type': 'singleSymbol',
        'forceraster': '0',
        'symbollevels': '0',
        'enableorderby': '0',
        'referencescale': '-1',
      },
      nest: () {
        builder.element(
          'symbols',
          nest: () {
            switch (layer.geometryType) {
              case GeometryType.point:
                _writeMarkerSymbol(builder, style);
              case GeometryType.linestring:
                _writeLineSymbol(builder, style);
              case GeometryType.polygon:
                _writeFillSymbol(builder, style);
            }
          },
        );
      },
    );
  }

  /// 簡易ラベル。
  ///
  /// QGIS の `QgsPalLayerSettings::readXml` は無い属性を既定値で埋めるので、
  /// フィールド名・フォントサイズ・文字色・縁取りだけ書く。
  void _writeLabeling(XmlBuilder builder, QgsLayer layer) {
    final style = layer.style;
    if (style == null || !style.hasLabel) return;
    builder.element(
      'labeling',
      attributes: {'type': 'simple'},
      nest: () {
        builder.element(
          'settings',
          attributes: {'calloutType': 'simple'},
          nest: () {
            builder.element(
              'text-style',
              attributes: labelTextStyleAttributes(style),
              nest: () {
                builder.element(
                  'text-buffer',
                  attributes: {
                    'bufferDraw': '1',
                    'bufferSize': '1',
                    'bufferSizeUnits': 'MM',
                    'bufferColor': _color(style.labelHaloColor ?? Colors.white),
                  },
                );
              },
            );
            builder.element('placement', attributes: {'placement': '0'});
            builder.element('rendering', attributes: {'drawLabels': '1'});
          },
        );
      },
    );
  }

  /// `text-style` の、こかげマップ が管轄する属性。
  /// ラベルは QGIS の式（`label_expression.dart`）で持っているので常に `isExpression="1"`
  /// （列 1 つでも `"列"` は正しい式）
  static Map<String, String> labelTextStyleAttributes(QgsStyle style) => {
    'fieldName': style.labelField ?? '',
    'isExpression': '1',
    'fontSize': (style.labelFontSizePt ?? 10).toStringAsFixed(1),
    'fontSizeUnit': 'Point',
    'textColor': const QgsWriter()._color(style.labelColor ?? Colors.black),
  };

  /// `<labeling>` の断片
  XmlElement? labelingElement(QgsLayer layer) {
    if (!(layer.style?.hasLabel ?? false)) return null;
    return _fragment((b) => _writeLabeling(b, layer));
  }

  void _writeSymbol(
    XmlBuilder builder,
    String type,
    String layerClass,
    Map<String, String> options,
  ) {
    builder.element(
      'symbol',
      attributes: {
        'name': '0',
        'type': type,
        'alpha': '1',
        'clip_to_extent': '1',
        'force_rhr': '0',
        'frame_rate': '10',
        'is_animated': '0',
      },
      nest: () {
        builder.element(
          'layer',
          attributes: {
            'class': layerClass,
            'enabled': '1',
            'locked': '0',
            'pass': '0',
          },
          nest: () {
            builder.element(
              'Option',
              attributes: {'type': 'Map'},
              nest: () {
                // QGIS は順不同で読むが、差分を安定させるため名前順で書く
                final keys = options.keys.toList()..sort();
                for (final key in keys) {
                  builder.element(
                    'Option',
                    attributes: {
                      'name': key,
                      'type': 'QString',
                      'value': options[key]!,
                    },
                  );
                }
              },
            );
          },
        );
      },
    );
  }

  void _writeMarkerSymbol(XmlBuilder builder, QgsStyle style) {
    _writeSymbol(builder, 'marker', 'SimpleMarker', {
      'angle': '0',
      'cap_style': 'square',
      'color': _color(style.pointColor ?? Colors.red),
      'horizontal_anchor_point': '1',
      'joinstyle': 'bevel',
      'name': 'circle',
      'offset': '0,0',
      'offset_map_unit_scale': '3x:0,0,0,0,0,0',
      'offset_unit': 'MM',
      'outline_color': '35,35,35,255',
      'outline_style': 'solid',
      'outline_width': '0',
      'outline_width_map_unit_scale': '3x:0,0,0,0,0,0',
      'outline_width_unit': 'MM',
      'scale_method': 'diameter',
      // こかげマップ の pointSize は半径感覚の px。QGIS の size は直径(MM)。
      'size': _mm((style.pointSizePx ?? 6) * 2),
      'size_map_unit_scale': '3x:0,0,0,0,0,0',
      'size_unit': 'MM',
      'vertical_anchor_point': '1',
    });
  }

  void _writeLineSymbol(XmlBuilder builder, QgsStyle style) {
    _writeSymbol(builder, 'line', 'SimpleLine', {
      'align_dash_pattern': '0',
      'capstyle': 'square',
      'customdash': '5;2',
      'customdash_map_unit_scale': '3x:0,0,0,0,0,0',
      'customdash_unit': 'MM',
      'dash_pattern_offset': '0',
      'dash_pattern_offset_map_unit_scale': '3x:0,0,0,0,0,0',
      'dash_pattern_offset_unit': 'MM',
      'draw_inside_polygon': '0',
      'joinstyle': 'bevel',
      'line_color': _color(style.lineColor ?? Colors.blue),
      'line_style': 'solid',
      'line_width': _mm(style.lineWidthPx ?? 2),
      'line_width_unit': 'MM',
      'offset': '0',
      'offset_map_unit_scale': '3x:0,0,0,0,0,0',
      'offset_unit': 'MM',
      'ring_filter': '0',
      'trim_distance_end': '0',
      'trim_distance_start': '0',
      'tweak_dash_pattern_on_corners': '0',
      'use_custom_dash': '0',
      'width_map_unit_scale': '3x:0,0,0,0,0,0',
    });
  }

  void _writeFillSymbol(XmlBuilder builder, QgsStyle style) {
    _writeSymbol(builder, 'fill', 'SimpleFill', {
      'border_width_map_unit_scale': '3x:0,0,0,0,0,0',
      'color': _color(
        style.fillColor ?? Colors.orange,
        opacity: style.fillOpacity,
      ),
      'joinstyle': 'bevel',
      'offset': '0,0',
      'offset_map_unit_scale': '3x:0,0,0,0,0,0',
      'offset_unit': 'MM',
      'outline_color': _color(
        style.strokeColor ?? Colors.black,
        opacity: style.strokeOpacity,
      ),
      'outline_style': 'solid',
      'outline_width': _mm(style.strokeWidthPx ?? 1),
      'outline_width_unit': 'MM',
      'style': 'solid',
    });
  }

  /// QGIS の色は `R,G,B,A`（各0-255）
  String _color(Color color, {double? opacity}) {
    final argb = color.toARGB32();
    final a = opacity != null
        ? (opacity.clamp(0.0, 1.0) * 255).round()
        : (argb >> 24) & 0xFF;
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    return '$r,$g,$b,$a';
  }

  String _mm(double px) => (px * _kPxToMm).toStringAsFixed(2);
}

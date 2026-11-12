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

import '../../core/terrain/svg_marker_atlas.dart';
import '../../models/geometry_type.dart';
import '../../models/qgis_symbol.dart';
import 'qgs_model.dart';
import 'qgs_xml.dart';

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

  /// 表の `<maplayer>`
  XmlElement tableMapLayerElement(QgsTableLayer layer) =>
      _fragment((b) => _writeTableMapLayer(b, layer));

  /// 表の `<layer-tree-layer>`
  XmlElement treeTableLayerElement(QgsTableLayer layer) =>
      _fragment((b) => _writeTreeNode(b, layer));

  /// `<vectorjoins>`（[QgsLayer.joins]）
  XmlElement vectorJoinsElement(List<QgsJoin> joins) =>
      _fragment((b) => b.element('vectorjoins', nest: () {
            for (final j in joins) {
              writeJoin(b, j);
            }
          }));

  /// `<join>` 1 本。属性は QGIS 4.2.2 が書く形（`tool/qgis/write_join_fixture.py`）
  static void writeJoin(XmlBuilder b, QgsJoin join) {
    b.element(
      'join',
      attributes: {
        'cascadedDelete': '0',
        if (join.customPrefix != null) 'customPrefix': join.customPrefix!,
        'dynamicForm': '0',
        'editable': '0',
        if (join.customPrefix != null) 'hasCustomPrefix': '1',
        'joinFieldName': join.joinFieldName,
        'joinLayerId': join.joinLayerId,
        'memoryCache': join.memoryCache ? '1' : '0',
        'targetFieldName': join.targetFieldName,
        'upsertOnEdit': '0',
      },
      nest: () {
        final subset = join.subset;
        if (subset == null) return;
        b.element('joinFieldsSubset', nest: () {
          for (final f in subset) {
            b.element('field', attributes: {'name': f});
          }
        });
      },
    );
  }

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
            'checked': qgsCheckedValue(visible),
          },
          nest: () {
            builder.element('customproperties', nest: () {});
            for (final child in children) {
              _writeTreeNode(builder, child);
            }
          },
        );
      case QgsLayer():
        _writeTreeLayer(builder, node.id, node.name, node.dataSourceUri, 'ogr', node.visible);
      case QgsRasterLayer():
        _writeTreeLayer(builder, node.id, node.name, node.dataSourcePath, 'gdal', node.visible);
      case QgsTableLayer():
        _writeTreeLayer(builder, node.id, node.name, node.dataSourceUri, 'delimitedtext', true);
    }
  }

  void _writeTreeLayer(XmlBuilder builder, String id, String name, String source, String provider, bool visible) {
    builder.element(
      'layer-tree-layer',
      attributes: {
        'id': id,
        'name': name,
        'source': source,
        'providerKey': provider,
        'expanded': '1',
        'checked': qgsCheckedValue(visible),
        'patch_size': '-1,-1',
      },
      nest: () {
        builder.element('customproperties', nest: () {});
      },
    );
  }

  // =============================================
  // レイヤ本体
  // =============================================

  static Map<String, String> _mapLayerAttributes({
    required String type,
    String? geometry,
    String? wkbType,
    String? readOnly,
    String? labelsEnabled,
  }) => {
    'type': type,
    'geometry': ?geometry,
    'wkbType': ?wkbType,
    'hasScaleBasedVisibilityFlag': '0',
    'minScale': '1e+08',
    'maxScale': '0',
    'readOnly': ?readOnly,
    'refreshOnNotifyEnabled': '0',
    'autoRefreshMode': 'Disabled',
    'styleCategories': 'AllStyleCategories',
    'labelsEnabled': ?labelsEnabled,
  };

  void _writeProjectLayers(XmlBuilder builder, QgsProject project) {
    builder.element(
      'projectlayers',
      nest: () {
        for (final layer in project.layers) {
          _writeMapLayer(builder, layer);
        }
        for (final raster in project.rasterLayers) {
          _writeRasterMapLayer(builder, raster);
        }
        for (final table in project.tableLayers) {
          _writeTableMapLayer(builder, table);
        }
      },
    );
  }

  /// 表（ジオメトリなし CSV）の `<maplayer>`。QGIS の「CSV テキストレイヤを追加」（geomType=none）と同じ形
  void _writeTableMapLayer(XmlBuilder builder, QgsTableLayer layer) {
    builder.element(
      'maplayer',
      attributes: _mapLayerAttributes(
        type: 'vector',
        geometry: 'No geometry',
        wkbType: 'NoGeometry',
        readOnly: '0',
      ),
      nest: () {
        builder.element('id', nest: layer.id);
        builder.element('datasource', nest: layer.dataSourceUri);
        builder.element('layername', nest: layer.name);
        builder.element('provider', attributes: {'encoding': ''}, nest: 'delimitedtext');
        builder.element('vectorjoins', nest: '');
        builder.element('previewExpression', nest: '');
      },
    );
  }

  /// ラスタ（GeoTIFF）の `<maplayer>`。レンダラ（`<pipe>`）は書かない。
  /// QGIS は読込時にプロバイダを作った段階で既定のレンダラを付けるので、無くても開ける
  void _writeRasterMapLayer(XmlBuilder builder, QgsRasterLayer layer) {
    builder.element(
      'maplayer',
      attributes: _mapLayerAttributes(type: 'raster'),
      nest: () {
        builder.element('id', nest: layer.id);
        builder.element('datasource', nest: layer.dataSourcePath);
        builder.element('layername', nest: layer.name);
        builder.element('srs', nest: () => _writeCrs(builder, layer.crs));
        builder.element('provider', nest: 'gdal');
      },
    );
  }

  void _writeMapLayer(XmlBuilder builder, QgsLayer layer) {
    builder.element(
      'maplayer',
      attributes: _mapLayerAttributes(
        type: 'vector',
        geometry: qgsGeometryName(layer.geometryType),
        readOnly: '0',
        labelsEnabled: (layer.style?.hasLabel ?? false) ? '1' : '0',
      ),
      nest: () {
        builder.element('id', nest: layer.id);
        builder.element('datasource', nest: layer.dataSourceUri);
        builder.element('layername', nest: layer.name);
        builder.element(
          'provider',
          attributes: {'encoding': layer.providerEncoding},
          nest: 'ogr',
        );
        builder.element('srs', nest: () => _writeCrs(builder, layer.crs));
        if (layer.joins.isNotEmpty) {
          builder.element('vectorjoins', nest: () {
            for (final j in layer.joins) {
              writeJoin(builder, j);
            }
          });
        }
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

  /// 単一シンボルのレンダラを書く。
  ///
  /// スタイルが無いレイヤには書かない。QGIS がランダムな既定シンボルを割り当てる
  /// （そのほうが、中途半端なレンダラで読み込みに失敗するより安全）。
  void _writeRenderer(XmlBuilder builder, QgsLayer layer) {
    final style = layer.style;
    if (style == null || style.isEmpty) return;

    final useSymbolLevels =
        (layer.geometryType == GeometryType.linestring && style.lineCasingEnabled == true && (style.lineCasingWidthPx ?? 2.0) > 0) ||
        (layer.geometryType == GeometryType.polygon && style.strokeCasingEnabled == true && (style.strokeCasingWidthPx ?? 2.0) > 0);

    builder.element(
      'renderer-v2',
      attributes: {
        'type': 'singleSymbol',
        'forceraster': '0',
        'symbollevels': useSymbolLevels ? '1' : '0',
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
                    'bufferColor': formatColor(style.labelHaloColor ?? Colors.white),
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
    'textColor': formatColor(style.labelColor ?? Colors.black),
  };

  /// `<labeling>` の断片
  XmlElement? labelingElement(QgsLayer layer) {
    if (!(layer.style?.hasLabel ?? false)) return null;
    return _fragment((b) => _writeLabeling(b, layer));
  }

  void _writeOptionMap(XmlBuilder builder, Map<String, String> options) {
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
  }

  void _writeSymbolLayer(
    XmlBuilder builder,
    String layerClass,
    Map<String, String> options, {
    int pass = 0,
    void Function()? extraChildren,
  }) {
    builder.element(
      'layer',
      attributes: {
        'class': layerClass,
        'enabled': '1',
        'locked': '0',
        'pass': '$pass',
      },
      nest: () {
        _writeOptionMap(builder, options);
        extraChildren?.call();
      },
    );
  }

  void _writeSymbolShell(
    XmlBuilder builder, {
    required String name,
    required String type,
    required void Function() writeLayers,
  }) {
    builder.element(
      'symbol',
      attributes: {
        'name': name,
        'type': type,
        'alpha': '1',
        'clip_to_extent': '1',
        'force_rhr': '0',
        'frame_rate': '10',
        'is_animated': '0',
      },
      nest: writeLayers,
    );
  }

  void _writeSymbol(
    XmlBuilder builder,
    String type,
    String layerClass,
    Map<String, String> options,
  ) {
    _writeSymbolShell(
      builder,
      name: '0',
      type: type,
      writeLayers: () => _writeSymbolLayer(builder, layerClass, options),
    );
  }

  Map<String, String> _simpleLineOptions({
    required String color,
    required String widthMm,
    String lineStyle = 'solid',
    String capStyle = 'square',
    String joinStyle = 'bevel',
  }) => {
    'align_dash_pattern': '0',
    'capstyle': capStyle,
    'customdash': '5;2',
    'customdash_map_unit_scale': '3x:0,0,0,0,0,0',
    'customdash_unit': 'MM',
    'dash_pattern_offset': '0',
    'dash_pattern_offset_map_unit_scale': '3x:0,0,0,0,0,0',
    'dash_pattern_offset_unit': 'MM',
    'draw_inside_polygon': '0',
    'joinstyle': joinStyle,
    'line_color': color,
    'line_style': lineStyle,
    'line_width': widthMm,
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
  };

  void _writeMarkerSymbol(XmlBuilder builder, QgsStyle style) {
    final outlineColor = style.pointOutlineColor != null
        ? formatColor(style.pointOutlineColor!, opacity: style.pointOpacity)
        : '35,35,35,255';
    final outlineWidth = style.pointOutlineEnabled == false
        ? '0'
        : (style.pointOutlineWidthPx != null ? formatMm(style.pointOutlineWidthPx!) : '0');
    final angle = (style.pointAngleDeg != null && style.pointAngleDeg != 0)
        ? style.pointAngleDeg!.toString()
        : '0';
    // こかげマップ の pointSize は半径感覚の px。QGIS の size は直径(MM)。
    final sizeMm = formatMm((style.pointSizePx ?? 6) * 2);

    if (style.pointSvgContent != null) {
      final svgName = (style.pointSvgPath != null && style.pointSvgPath!.startsWith('base64:'))
          ? style.pointSvgPath!
          : encodeBase64QgisSvg(style.pointSvgContent!);
      _writeSymbol(builder, 'marker', 'SvgMarker', {
        'angle': angle,
        'color': formatColor(style.pointColor ?? Colors.red, opacity: style.pointOpacity),
        'fixedAspectRatio': '0',
        'horizontal_anchor_point': '1',
        'name': svgName,
        'offset': '0,0',
        'offset_map_unit_scale': '3x:0,0,0,0,0,0',
        'offset_unit': 'MM',
        'outline_color': outlineColor,
        'outline_width': outlineWidth,
        'outline_width_map_unit_scale': '3x:0,0,0,0,0,0',
        'outline_width_unit': 'MM',
        'parameters': '',
        'scale_method': 'diameter',
        'size': sizeMm,
        'size_map_unit_scale': '3x:0,0,0,0,0,0',
        'size_unit': 'MM',
        'vertical_anchor_point': '1',
      });
      return;
    }

    final shapeName = style.pointShape == null
        ? 'circle'
        : PointMarkerShape.fromId(style.pointShape).qgisName;
    final outlineStyle = style.pointOutlineEnabled == false ? 'no' : 'solid';
    _writeSymbol(builder, 'marker', 'SimpleMarker', {
      'angle': angle,
      'cap_style': 'square',
      'color': formatColor(style.pointColor ?? Colors.red, opacity: style.pointOpacity),
      'horizontal_anchor_point': '1',
      'joinstyle': 'bevel',
      'name': shapeName,
      'offset': '0,0',
      'offset_map_unit_scale': '3x:0,0,0,0,0,0',
      'offset_unit': 'MM',
      'outline_color': outlineColor,
      'outline_style': outlineStyle,
      'outline_width': outlineWidth,
      'outline_width_map_unit_scale': '3x:0,0,0,0,0,0',
      'outline_width_unit': 'MM',
      'scale_method': 'diameter',
      'size': sizeMm,
      'size_map_unit_scale': '3x:0,0,0,0,0,0',
      'size_unit': 'MM',
      'vertical_anchor_point': '1',
    });
  }

  void _writeLineSymbol(XmlBuilder builder, QgsStyle style) {
    final dash = LineDashPattern.fromId(style.lineDash);
    final coreWidth = style.lineWidthPx ?? 2;
    final casingWidth = style.lineCasingWidthPx ?? 2;
    final hasCasing = style.lineCasingEnabled == true && casingWidth > 0;
    if (!hasCasing) {
      _writeSymbol(
        builder,
        'line',
        'SimpleLine',
        _simpleLineOptions(
          color: formatColor(style.lineColor ?? Colors.blue, opacity: style.lineOpacity),
          widthMm: formatMm(coreWidth),
          lineStyle: dash.qgisPenStyle,
        ),
      );
      return;
    }
    _writeSymbolShell(
      builder,
      name: '0',
      type: 'line',
      writeLayers: () {
        _writeSymbolLayer(
          builder,
          'SimpleLine',
          _simpleLineOptions(
            color: formatColor(style.lineCasingColor ?? Colors.white, opacity: style.lineOpacity),
            widthMm: formatMm(coreWidth + casingWidth * 2),
            capStyle: 'round',
            joinStyle: 'round',
          ),
          pass: 0,
        );
        _writeSymbolLayer(
          builder,
          'SimpleLine',
          _simpleLineOptions(
            color: formatColor(style.lineColor ?? Colors.blue, opacity: style.lineOpacity),
            widthMm: formatMm(coreWidth),
            lineStyle: dash.qgisPenStyle,
            capStyle: dash == LineDashPattern.solid ? 'round' : 'square',
            joinStyle: 'round',
          ),
          pass: 1,
        );
      },
    );
  }

  void _writeFillSymbol(XmlBuilder builder, QgsStyle style) {
    final fillPat = PolygonFillPattern.fromId(style.fillPattern);
    final strokeDash = LineDashPattern.fromId(style.strokeDash);
    final strokeW = style.strokeWidthPx ?? 1;
    final strokeCasingW = style.strokeCasingWidthPx ?? 2;
    final hasStrokeCasing = style.strokeCasingEnabled == true && strokeCasingW > 0 && strokeW > 0;

    // ベタ塗りまたは塗りなし・かつ輪郭の縁取りなし → 単一 SimpleFill（従来の XML と完全一致）
    if ((fillPat == PolygonFillPattern.solid || fillPat == PolygonFillPattern.none) && !hasStrokeCasing) {
      final outlineStyle = (style.strokeWidthPx != null && style.strokeWidthPx! <= 0)
          ? 'no'
          : strokeDash.qgisPenStyle;
      _writeSymbol(builder, 'fill', 'SimpleFill', {
        'border_width_map_unit_scale': '3x:0,0,0,0,0,0',
        'color': formatColor(
          style.fillColor ?? Colors.orange,
          opacity: style.fillOpacity,
        ),
        'joinstyle': 'bevel',
        'offset': '0,0',
        'offset_map_unit_scale': '3x:0,0,0,0,0,0',
        'offset_unit': 'MM',
        'outline_color': formatColor(
          style.strokeColor ?? Colors.black,
          opacity: style.strokeOpacity,
        ),
        'outline_style': outlineStyle,
        'outline_width': formatMm(strokeW),
        'outline_width_unit': 'MM',
        'style': fillPat == PolygonFillPattern.none ? 'no' : 'solid',
      });
      return;
    }

    // ハッチング・ドット・または輪郭の縁取りあり → 複数シンボルレイヤ
    final fillColorStr = formatColor(style.fillColor ?? Colors.orange, opacity: style.fillOpacity);
    final spacingMm = formatMm(style.patternSpacingPx ?? 8.0);
    final hatchWidthMm = formatMm(style.patternLineWidthPx ?? 1.5);

    _writeSymbolShell(
      builder,
      name: '0',
      type: 'fill',
      writeLayers: () {
        var subIdx = 0;
        switch (fillPat) {
          case PolygonFillPattern.none:
            break;
          case PolygonFillPattern.solid:
            _writeSymbolLayer(builder, 'SimpleFill', {
              'border_width_map_unit_scale': '3x:0,0,0,0,0,0',
              'color': fillColorStr,
              'joinstyle': 'bevel',
              'offset': '0,0',
              'offset_map_unit_scale': '3x:0,0,0,0,0,0',
              'offset_unit': 'MM',
              'outline_color': '0,0,0,0',
              'outline_style': 'no',
              'outline_width': '0',
              'outline_width_unit': 'MM',
              'style': 'solid',
            });
          case PolygonFillPattern.dots:
            final symName = '@0@${subIdx++}';
            _writeSymbolLayer(
              builder,
              'PointPatternFill',
              {
                'angle': '0',
                'clip_mode': 'shape',
                'coordinate_reference': 'feature',
                'displacement_x': '0',
                'displacement_x_map_unit_scale': '3x:0,0,0,0,0,0',
                'displacement_x_unit': 'MM',
                'displacement_y': '0',
                'displacement_y_map_unit_scale': '3x:0,0,0,0,0,0',
                'displacement_y_unit': 'MM',
                'distance_x': spacingMm,
                'distance_x_map_unit_scale': '3x:0,0,0,0,0,0',
                'distance_x_unit': 'MM',
                'distance_y': spacingMm,
                'distance_y_map_unit_scale': '3x:0,0,0,0,0,0',
                'distance_y_unit': 'MM',
                'offset_x': '0',
                'offset_x_map_unit_scale': '3x:0,0,0,0,0,0',
                'offset_x_unit': 'MM',
                'offset_y': '0',
                'offset_y_map_unit_scale': '3x:0,0,0,0,0,0',
                'offset_y_unit': 'MM',
                'outline_width_map_unit_scale': '3x:0,0,0,0,0,0',
                'outline_width_unit': 'MM',
                'random_deviation_x': '0',
                'random_deviation_y': '0',
                'seed': '0',
              },
              extraChildren: () => _writeSymbolShell(
                builder,
                name: symName,
                type: 'marker',
                writeLayers: () => _writeSymbolLayer(builder, 'SimpleMarker', {
                  'angle': '0',
                  'cap_style': 'square',
                  'color': fillColorStr,
                  'horizontal_anchor_point': '1',
                  'joinstyle': 'bevel',
                  'name': 'circle',
                  'offset': '0,0',
                  'offset_map_unit_scale': '3x:0,0,0,0,0,0',
                  'offset_unit': 'MM',
                  'outline_color': '35,35,35,255',
                  'outline_style': 'no',
                  'outline_width': '0',
                  'outline_width_map_unit_scale': '3x:0,0,0,0,0,0',
                  'outline_width_unit': 'MM',
                  'scale_method': 'diameter',
                  'size': formatMm((style.patternLineWidthPx ?? 1.5) * 2),
                  'size_map_unit_scale': '3x:0,0,0,0,0,0',
                  'size_unit': 'MM',
                  'vertical_anchor_point': '1',
                }),
              ),
            );
          case PolygonFillPattern.slash:
          case PolygonFillPattern.backslash:
          case PolygonFillPattern.cross:
          case PolygonFillPattern.grid:
          case PolygonFillPattern.horizontal:
          case PolygonFillPattern.vertical:
            final angles = switch (fillPat) {
              PolygonFillPattern.slash => const [45],
              PolygonFillPattern.backslash => const [135],
              PolygonFillPattern.cross => const [45, 135],
              PolygonFillPattern.grid => const [0, 90],
              PolygonFillPattern.horizontal => const [0],
              PolygonFillPattern.vertical => const [90],
              _ => const [45],
            };
            for (final deg in angles) {
              final symName = '@0@${subIdx++}';
              _writeSymbolLayer(
                builder,
                'LinePatternFill',
                {
                  'angle': '$deg',
                  'clip_mode': 'during_render',
                  'color': fillColorStr,
                  'coordinate_reference': 'feature',
                  'distance': spacingMm,
                  'distance_map_unit_scale': '3x:0,0,0,0,0,0',
                  'distance_unit': 'MM',
                  'line_width': hatchWidthMm,
                  'line_width_map_unit_scale': '3x:0,0,0,0,0,0',
                  'line_width_unit': 'MM',
                  'offset': '0',
                  'offset_map_unit_scale': '3x:0,0,0,0,0,0',
                  'offset_unit': 'MM',
                  'outline_width_map_unit_scale': '3x:0,0,0,0,0,0',
                  'outline_width_unit': 'MM',
                },
                extraChildren: () => _writeSymbolShell(
                  builder,
                  name: symName,
                  type: 'line',
                  writeLayers: () => _writeSymbolLayer(
                    builder,
                    'SimpleLine',
                    _simpleLineOptions(color: fillColorStr, widthMm: hatchWidthMm),
                  ),
                ),
              );
            }
        }

        // 輪郭線レイヤ
        if (strokeW > 0 && (style.strokeOpacity ?? 1.0) > 0 && strokeDash != LineDashPattern.none) {
          final outlineColorStr = formatColor(style.strokeColor ?? Colors.black, opacity: style.strokeOpacity);
          if (hasStrokeCasing) {
            _writeSymbolLayer(
              builder,
              'SimpleLine',
              _simpleLineOptions(
                color: formatColor(style.strokeCasingColor ?? Colors.white, opacity: style.strokeOpacity),
                widthMm: formatMm(strokeW + strokeCasingW * 2),
                capStyle: 'round',
                joinStyle: 'round',
              ),
              pass: 0,
            );
            _writeSymbolLayer(
              builder,
              'SimpleLine',
              _simpleLineOptions(
                color: outlineColorStr,
                widthMm: formatMm(strokeW),
                lineStyle: strokeDash.qgisPenStyle,
                capStyle: strokeDash == LineDashPattern.solid ? 'round' : 'square',
                joinStyle: 'round',
              ),
              pass: 1,
            );
          } else {
            _writeSymbolLayer(
              builder,
              'SimpleLine',
              _simpleLineOptions(
                color: outlineColorStr,
                widthMm: formatMm(strokeW),
                lineStyle: strokeDash.qgisPenStyle,
              ),
            );
          }
        }
      },
    );
  }

  /// QGIS の色表記 `R,G,B,A`（各0-255）。[opacity] があればアルファはそれにする
  static String formatColor(Color color, {double? opacity}) =>
      formatQgsColor(color, opacity: opacity);

  /// px → QGIS のシンボル単位（MM）
  static String formatMm(double px) => formatQgsMm(px);
}

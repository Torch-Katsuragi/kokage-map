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
// こかげマップ: レイヤスタイル（`.qml`）のエクスポート／インポートサービス

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart' show Colors;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../core/fs/k_file_system.dart';
import '../../models/geometry_type.dart';
import '../../models/kmeta.dart';
import '../../models/nodes/layer_node.dart';
import '../../models/nodes/view_node.dart';
import '../../models/qgis_renderer.dart';
import '../../utils/app_logger.dart';
import '../../utils/label_template.dart';
import 'qgs_importer.dart';
import 'qgs_model.dart';
import 'qgs_project_builder.dart';
import 'qgs_renderer_reader.dart';
import 'qgs_style_reader.dart';
import 'qgs_writer.dart';
import 'qgs_xml.dart';

/// `.qml` インポート結果
sealed class QmlImportResult {
  const QmlImportResult();
}

/// 正常にスタイルを読み取れた場合
final class QmlImportSuccess extends QmlImportResult {
  const QmlImportSuccess(this.style);
  final KMetaLayerStyle style;
}

/// ジオメトリ型（点・線・面）が対象レイヤと一致しない場合
final class QmlImportGeometryMismatch extends QmlImportResult {
  const QmlImportGeometryMismatch({
    required this.expected,
    required this.actual,
  });
  final GeometryType expected;
  final GeometryType actual;
}

/// XML 破損または QGIS スタイル要素が含まれない場合
final class QmlImportInvalid extends QmlImportResult {
  const QmlImportInvalid(this.reason);
  final String reason;
}

/// QGIS `.qml` スタイル定義ファイルの書き出し・読み込みサービス
abstract final class QgsQmlService {
  /// [style] と [geometryType] から QGIS 互換の `.qml` XML 文字列を生成する。
  ///
  /// [existingMapLayer] が渡され、かつ描き分けレンダラや未編集の複合シンボルを持つ場合は
  /// 元の `<renderer-v2>` をそのまま引き継ぐ。
  static String exportQml({
    required KMetaLayerStyle style,
    required GeometryType geometryType,
    XmlElement? existingMapLayer,
  }) {
    final hasScale = (style.minScale != null && style.minScale! > 0) ||
        (style.maxScale != null && style.maxScale! > 0);
    final minScaleStr = (style.minScale != null && style.minScale! > 0)
        ? _trimNum(style.minScale!)
        : '100000000';
    final maxScaleStr = (style.maxScale != null && style.maxScale! > 0)
        ? _trimNum(style.maxScale!)
        : '0';
    final hasLabel = style.labelEnabled == true &&
        (normalizeLabelExpression(style.labelProperty)?.isNotEmpty ?? false);

    final rendererEl = _buildRendererElement(
      style: style,
      geometryType: geometryType,
      existingMapLayer: existingMapLayer,
    );
    final labelingEl = hasLabel
        ? _buildLabelingElement(style)
        : null;

    final builder = XmlBuilder();
    builder.element(
      'qgis',
      attributes: {
        'version': kQgsVersion,
        'styleCategories': 'Symbology|Labeling|Rendering',
        'hasScaleBasedVisibilityFlag': hasScale ? '1' : '0',
        'minScale': minScaleStr,
        'maxScale': maxScaleStr,
        'labelsEnabled': hasLabel ? '1' : '0',
      },
      nest: () {
        builder.element('layerOpacity', nest: '1');
        builder.element('blendMode', nest: '0');
        if (rendererEl != null) {
          builder.xml(rendererEl.toXmlString());
        }
        if (labelingEl != null) {
          builder.xml(labelingEl.toXmlString());
        }
        builder.element(
          'layerGeometryType',
          nest: '${_qgisGeometryTypeCode(geometryType)}',
        );
      },
    );

    final docXml = builder.buildDocument().toXmlString(pretty: true, indent: '  ');
    return "<!DOCTYPE qgis PUBLIC 'http://mrcc.com/qgis.dtd' 'SYSTEM'>\n$docXml\n";
  }

  /// UTF-8 エンコード済みの `.qml` バイト列を返す
  static Uint8List exportQmlBytes({
    required KMetaLayerStyle style,
    required GeometryType geometryType,
    XmlElement? existingMapLayer,
  }) =>
      Uint8List.fromList(
        utf8.encode(
          exportQml(
            style: style,
            geometryType: geometryType,
            existingMapLayer: existingMapLayer,
          ),
        ),
      );

  /// `.qml` XML 文字列を検証・解析して [KMetaLayerStyle] に変換する
  static QmlImportResult importQml(
    String qmlXml, {
    GeometryType? expectedGeometryType,
    QgsSvgFileReader? svgFileReader,
  }) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(qmlXml);
    } on Object catch (e) {
      return QmlImportInvalid('$e');
    }

    final root = doc.rootElement;
    if (root.name.local != 'qgis' && root.name.local != 'maplayer') {
      return QmlImportInvalid('root=<${root.name.local}>');
    }

    final detectedGeom = _detectGeometryType(root);
    if (expectedGeometryType != null &&
        detectedGeom != null &&
        detectedGeom != expectedGeometryType) {
      return QmlImportGeometryMismatch(
        expected: expectedGeometryType,
        actual: detectedGeom,
      );
    }

    final parsed = QgsStyleReader.readStyleWithLabel(
      root,
      svgFileReader: svgFileReader,
    );
    if (parsed == null || parsed.isEmpty) {
      return const QmlImportInvalid('empty style');
    }
    return QmlImportSuccess(parsed);
  }

  /// フォルダ内の `.qgs` / `.qgz` から該当レイヤ（または View）の `<maplayer>` を読み取り専用で探す
  static Future<XmlElement?> findExistingMapLayerInFolder({
    required String? folderPath,
    required LayerNode layer,
    ViewNode? view,
  }) async {
    if (folderPath == null) return null;
    try {
      final dirName = p.basename(folderPath);
      final qgsCandidates = <String>[
        p.join(folderPath, qgsFileNameFor(dirName)),
        p.join(folderPath, kLegacyQgsFileName),
      ];
      String? qgsPath;
      for (final c in qgsCandidates) {
        if (await fs.exists(c)) {
          qgsPath = c;
          break;
        }
      }
      if (qgsPath == null) return null;
      final doc = XmlDocument.parse(await QgsImporter.readQgsText(qgsPath));
      final projectLayers = doc.rootElement.findElements('projectlayers').firstOrNull;
      if (projectLayers == null) return null;

      final gpkgName = layer.geoPackageNode.name;
      final wantSubset = view?.filter ?? '';
      final wantName = (view == null || view.isDefaultView) ? layer.layerName : view.name;

      XmlElement? fallbackMatch;
      for (final ml in projectLayers.findElements('maplayer')) {
        final ds = QgsDataSource.parse(childText(ml, 'datasource') ?? '');
        if (ds == null) continue;
        final dsBase = p.basename(ds.path.replaceAll(r'\', '/'));
        if (dsBase.toLowerCase() != gpkgName.toLowerCase()) continue;
        final table = ds.layerName ?? p.basenameWithoutExtension(dsBase);
        if (table.toLowerCase() != layer.layerName.toLowerCase()) continue;
        fallbackMatch ??= ml;
        final mlName = childText(ml, 'layername') ?? '';
        final mlSubset = ds.subset ?? '';
        if (mlName == wantName && mlSubset == wantSubset) {
          return ml;
        }
      }
      return view == null ? fallbackMatch : null;
    } on Object catch (e) {
      AppLogger.debug('[QgsQmlService] 既存 maplayer 参照失敗: $e');
      return null;
    }
  }

  // ── Internal Helpers ─────────────────────────────────

  static int _qgisGeometryTypeCode(GeometryType type) => switch (type) {
        GeometryType.point => 0,
        GeometryType.linestring => 1,
        GeometryType.polygon => 2,
      };

  static GeometryType? _detectGeometryType(XmlElement root) {
    final geomCode = childText(root, 'layerGeometryType')?.trim();
    switch (geomCode) {
      case '0':
        return GeometryType.point;
      case '1':
        return GeometryType.linestring;
      case '2':
        return GeometryType.polygon;
    }
    final renderer = root.findElements('renderer-v2').firstOrNull;
    final firstSym = renderer?.findAllElements('symbol').firstOrNull;
    return switch (firstSym?.getAttribute('type')) {
      'marker' => GeometryType.point,
      'line' => GeometryType.linestring,
      'fill' => GeometryType.polygon,
      _ => null,
    };
  }

  static XmlElement? _buildRendererElement({
    required KMetaLayerStyle style,
    required GeometryType geometryType,
    XmlElement? existingMapLayer,
  }) {
    if (existingMapLayer != null && style.qgisRenderer != null) {
      final existing = existingMapLayer.findElements('renderer-v2').firstOrNull;
      if (existing != null) return existing.copy();
    }

    if (style.qgisRenderer == 'nullSymbol' || style.symbolLayers?.nullSymbol == true) {
      final b = XmlBuilder();
      b.element(
        'renderer-v2',
        attributes: {
          'type': 'nullSymbol',
          'forceraster': '0',
          'symbollevels': '0',
          'enableorderby': '0',
          'referencescale': '-1',
        },
      );
      return b.buildFragment().children.whereType<XmlElement>().first;
    }

    final def = style.qgisRendererDef;
    if (def != null) {
      final built = _buildCategorizedOrRuleRenderer(def, geometryType);
      if (built != null) {
        return def.invertedPolygon ? _wrapInvertedPolygon(built) : built;
      }
    }

    final qgsStyle = QgsProjectBuilder.toQgsStyle(
      style.copyWith(clearSymbolLayers: false),
    );
    final effectiveQgsStyle = (qgsStyle == null || qgsStyle.isEmpty)
        ? _defaultQgsStyleFor(geometryType, style)
        : qgsStyle;

    const writer = QgsWriter();
    final single = writer.rendererElement(
      QgsLayer(
        id: 'qml_export',
        name: 'qml_export',
        dataSourcePath: './export.gpkg',
        tableName: 'export',
        geometryType: geometryType,
        crs: QgsCrs.wgs84,
        style: effectiveQgsStyle,
      ),
    );
    if (single == null) return null;
    final inverted = style.symbolLayers?.invertedPolygon == true ||
        style.qgisRenderer == 'invertedPolygonRenderer';
    return inverted ? _wrapInvertedPolygon(single) : single;
  }

  static QgsStyle _defaultQgsStyleFor(GeometryType geometryType, KMetaLayerStyle style) =>
      switch (geometryType) {
        GeometryType.point => QgsStyle(
            pointColor: style.pointColor ?? Colors.red,
            pointSizePx: style.pointSize ?? 6.0,
            pointOpacity: style.pointOpacity,
          ),
        GeometryType.linestring => QgsStyle(
            lineColor: style.lineColor ?? Colors.blue,
            lineWidthPx: style.lineWidth ?? 2.0,
            lineOpacity: style.lineOpacity,
          ),
        GeometryType.polygon => QgsStyle(
            fillColor: style.polygonFillColor ?? Colors.orange,
            fillOpacity: style.polygonFillOpacity,
            strokeColor: style.polygonBorderColor ?? Colors.black,
            strokeWidthPx: style.polygonBorderWidth ?? 1.0,
            strokeOpacity: style.polygonBorderOpacity,
          ),
      };

  static XmlElement _wrapInvertedPolygon(XmlElement innerRenderer) {
    final b = XmlBuilder();
    b.element(
      'renderer-v2',
      attributes: {
        'type': 'invertedPolygonRenderer',
        'forceraster': '0',
        'enableorderby': '0',
        'preprocessing': '0',
      },
      nest: () => b.xml(innerRenderer.toXmlString()),
    );
    return b.buildFragment().children.whereType<XmlElement>().first;
  }

  static XmlElement? _buildCategorizedOrRuleRenderer(
    QgisRenderer def,
    GeometryType geometryType,
  ) {
    final symbolElements = <XmlElement>[];
    for (var i = 0; i < def.classes.length; i++) {
      final clsStyle = def.classes[i].style ?? const KMetaLayerStyle();
      final qgsStyle = QgsProjectBuilder.toQgsStyle(clsStyle) ??
          _defaultQgsStyleFor(geometryType, clsStyle);
      final single = const QgsWriter().rendererElement(
        QgsLayer(
          id: 'c_$i',
          name: 'c_$i',
          dataSourcePath: './export.gpkg',
          tableName: 'export',
          geometryType: geometryType,
          crs: QgsCrs.wgs84,
          style: qgsStyle,
        ),
      );
      final sym = single?.getElement('symbols')?.findElements('symbol').firstOrNull;
      if (sym != null) {
        final renamedXml = sym
            .toXmlString()
            .replaceFirst('name="0"', 'name="$i"')
            .replaceAll('@0@', '@$i@');
        symbolElements.add(XmlDocument.parse(renamedXml).rootElement.copy());
      }
    }

    final b = XmlBuilder();
    switch (def.kind) {
      case QgisRendererKind.categorized:
        b.element(
          'renderer-v2',
          attributes: {
            'type': 'categorizedSymbol',
            'attr': def.attr ?? '',
            'forceraster': '0',
            'symbollevels': '0',
            'enableorderby': '0',
            'referencescale': '-1',
          },
          nest: () {
            b.element(
              'categories',
              nest: () {
                for (var i = 0; i < def.classes.length; i++) {
                  final c = def.classes[i];
                  final vals = c.values;
                  if (vals.length > 1) {
                    b.element(
                      'category',
                      attributes: {
                        'symbol': '$i',
                        'label': c.label,
                        'render': c.render ? 'true' : 'false',
                      },
                      nest: () {
                        for (final v in vals) {
                          b.element(
                            'val',
                            attributes: v == null
                                ? {'type': 'NULL'}
                                : {'type': 'QString', 'value': v},
                          );
                        }
                      },
                    );
                  } else {
                    final singleVal = vals.isEmpty ? null : vals.first;
                    b.element(
                      'category',
                      attributes: {
                        'symbol': '$i',
                        'label': c.label,
                        'render': c.render ? 'true' : 'false',
                        'type': singleVal == null ? 'NULL' : 'string',
                        'value': singleVal ?? '',
                      },
                    );
                  }
                }
              },
            );
            b.element(
              'symbols',
              nest: () {
                for (final s in symbolElements) {
                  b.xml(s.toXmlString());
                }
              },
            );
          },
        );
      case QgisRendererKind.graduated:
        b.element(
          'renderer-v2',
          attributes: {
            'type': 'graduatedSymbol',
            'attr': def.attr ?? '',
            'graduatedMethod': 'GraduatedColor',
            'forceraster': '0',
            'symbollevels': '0',
            'enableorderby': '0',
            'referencescale': '-1',
          },
          nest: () {
            b.element(
              'ranges',
              nest: () {
                for (var i = 0; i < def.classes.length; i++) {
                  final r = def.classes[i];
                  b.element(
                    'range',
                    attributes: {
                      'symbol': '$i',
                      'lower': '${r.lower ?? 0}',
                      'upper': '${r.upper ?? 0}',
                      'label': r.label,
                      'render': r.render ? 'true' : 'false',
                    },
                  );
                }
              },
            );
            b.element(
              'symbols',
              nest: () {
                for (final s in symbolElements) {
                  b.xml(s.toXmlString());
                }
              },
            );
          },
        );
      case QgisRendererKind.rule:
        void writeRule(QgisRule r, int idx) {
          final attrs = <String, String>{
            'key': '{00000000-0000-4000-8000-${idx.toRadixString(16).padLeft(12, '0')}}',
            if (r.classIndex != null) 'symbol': '${r.classIndex}',
            if (r.isElse)
              'filter': 'ELSE'
            else if (r.filter != null && r.filter!.isNotEmpty)
              'filter': r.filter!,
            if (r.classIndex != null && r.classIndex! < def.classes.length)
              'label': def.classes[r.classIndex!].label,
            if (!r.active) 'active': '0',
            if (r.scaleMinDenom != null) 'scalemindenom': _trimNum(r.scaleMinDenom!),
            if (r.scaleMaxDenom != null) 'scalemaxdenom': _trimNum(r.scaleMaxDenom!),
          };
          b.element(
            'rule',
            attributes: attrs,
            nest: () {
              var sub = idx * 16 + 1;
              for (final child in r.children) {
                writeRule(child, sub++);
              }
            },
          );
        }

        b.element(
          'renderer-v2',
          attributes: {
            'type': 'RuleRenderer',
            'forceraster': '0',
            'symbollevels': '0',
            'enableorderby': '0',
            'referencescale': '-1',
          },
          nest: () {
            b.element(
              'rules',
              attributes: {'key': '{00000000-0000-4000-8000-000000000000}'},
              nest: () {
                var idx = 1;
                for (final r in def.rules) {
                  writeRule(r, idx++);
                }
              },
            );
            b.element(
              'symbols',
              nest: () {
                for (final s in symbolElements) {
                  b.xml(s.toXmlString());
                }
              },
            );
          },
        );
    }
    return b.buildFragment().children.whereType<XmlElement>().firstOrNull;
  }

  static XmlElement _buildLabelingElement(KMetaLayerStyle style) {
    final expr = normalizeLabelExpression(style.labelProperty) ?? '';
    final fontSizePt = ((style.labelFontSize ?? 12.0) * kQgsPxToPt).toStringAsFixed(1);
    final textColor = QgsWriter.formatColor(style.labelColor ?? Colors.black);
    final textOp = (style.labelOpacity ?? 1.0).clamp(0.0, 1.0);
    final haloDraw = (style.labelHaloEnabled ?? true) ? '1' : '0';
    final haloMm = style.labelHaloSize != null ? QgsWriter.formatMm(style.labelHaloSize!) : '1';
    final haloColor = QgsWriter.formatColor(style.labelHaloColor ?? Colors.white);

    final b = XmlBuilder();
    b.element(
      'labeling',
      attributes: {'type': 'simple'},
      nest: () {
        b.element(
          'settings',
          attributes: {'calloutType': 'simple'},
          nest: () {
            if (style.labelWrapChar != null && style.labelWrapChar!.isNotEmpty) {
              b.element(
                'text-format',
                attributes: {'wrapChar': style.labelWrapChar!},
              );
            }
            b.element(
              'text-style',
              attributes: {
                'fieldName': expr,
                'isExpression': '1',
                'fontSize': fontSizePt,
                'fontSizeUnit': 'Point',
                'textColor': textColor,
                'textOpacity': _trimNum(textOp),
              },
              nest: () {
                b.element(
                  'text-buffer',
                  attributes: {
                    'bufferDraw': haloDraw,
                    'bufferSize': haloMm,
                    'bufferSizeUnits': 'MM',
                    'bufferColor': haloColor,
                  },
                );
                if (style.labelBgEnabled == true) {
                  final shapeCode = switch (style.labelBgShape) {
                    'circle' => '3',
                    _ => '0',
                  };
                  final radii = style.labelBgShape == 'roundRect' ? '1.2' : '0';
                  final bgCol = style.labelBgColor ?? Colors.white;
                  final borderCol = style.labelBgBorderColor ?? Colors.black54;
                  final borderW = style.labelBgBorderWidth ?? 0.0;
                  b.element(
                    'background',
                    attributes: {
                      'shapeDraw': '1',
                      'shapeType': shapeCode,
                      'shapeRadiiX': radii,
                      'shapeRadiiY': radii,
                      'shapeFillColor': formatQgsColor(bgCol, opacity: bgCol.a),
                      'shapeBorderColor': formatQgsColor(borderCol, opacity: borderCol.a),
                      'shapeBorderWidth': borderW > 0 ? QgsWriter.formatMm(borderW) : '0',
                      'shapeBorderWidthUnit': 'MM',
                      'shapeOpacity': '1',
                    },
                  );
                }
              },
            );
            b.element('placement', attributes: {'placement': '0'});
            b.element('rendering', attributes: {'drawLabels': '1'});
          },
        );
      },
    );
    return b.buildFragment().children.whereType<XmlElement>().first;
  }

  static String _trimNum(double v) {
    final s = v.toStringAsFixed(4);
    if (!s.contains('.')) return s;
    return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
}

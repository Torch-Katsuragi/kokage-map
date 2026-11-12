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
/// `.qgs` / `.qml` の `<maplayer>`（または `<qgis>`）からシンボル/レンダラ・ラベル設定・縮尺制限・不透明度を読み取る。
library;

import 'package:flutter/material.dart' show Color;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../core/fs/k_file_system.dart';
import '../../models/kmeta.dart';
import '../../models/nodes/layer_node.dart';
import '../../utils/app_logger.dart';
import '../../utils/label_expression.dart';
import '../kmeta_service.dart';
import 'qgs_renderer_reader.dart';
import 'qgs_source_resolver.dart';
import 'qgs_xml.dart';

/// シンボル・分類/段階/ルール/特殊レンダラ・ラベル設定・縮尺依存表示の読み取りと既存スタイルへの反映。
abstract final class QgsStyleReader {
  /// `<layer class="SvgMarker">` がプロジェクト内の相対 `.svg` ファイルを指している場合に先読みする。
  ///
  /// **ルート外への参照は丸ごと無視する**（`relativeInside(rootDir, absPath) != null` のみ読む）。
  static Future<Map<String, String>> preloadLocalSvgFiles(
    XmlNode docOrElement, {
    required String? baseDir,
    required String? rootDir,
  }) async {
    if (baseDir == null || rootDir == null) return const {};
    final out = <String, String>{};
    for (final layerEl in docOrElement.findAllElements('layer')) {
      if (layerEl.getAttribute('class') != 'SvgMarker') continue;
      final rawName = QgsSymbolReader.readProps(layerEl)['name']?.trim();
      if (rawName == null || rawName.isEmpty || rawName.startsWith('base64:')) continue;
      if (out.containsKey(rawName)) continue;
      final normalizedRel = rawName.replaceAll(r'\', p.separator).replaceAll('/', p.separator);
      final absPath = p.normalize(
        p.isAbsolute(normalizedRel) ? normalizedRel : p.join(baseDir, normalizedRel),
      );
      if (!absPath.toLowerCase().endsWith('.svg')) continue;
      if (relativeInside(rootDir, absPath) == null) continue;
      try {
        if (await fs.exists(absPath)) {
          final text = await fs.readAsString(absPath);
          if (text.contains('<svg')) out[rawName] = text;
        }
      } on Object catch (e) {
        AppLogger.debug('[QgsStyleReader] SVG 読み込み失敗 ($rawName): $e');
      }
    }
    return out;
  }

  /// シンボル・ラベル・縮尺制限をまとめて読む（すべて無ければ null）
  static KMetaLayerStyle? readStyleWithLabel(
    XmlElement maplayer, {
    QgsSvgFileReader? svgFileReader,
  }) {
    final symbol = readStyle(maplayer, svgFileReader: svgFileReader);
    final label = readLabel(maplayer, svgFileReader: svgFileReader);
    final scale = readScaleVisibility(maplayer);
    var out = symbol;
    if (label != null) out = (out ?? const KMetaLayerStyle()).mergeWith(label);
    if (scale != null) out = (out ?? const KMetaLayerStyle()).mergeWith(scale);
    return out;
  }

  /// レイヤの縮尺依存表示（`hasScaleBasedVisibilityFlag="1"` のときの `minScale` / `maxScale`）
  static KMetaLayerStyle? readScaleVisibility(XmlElement maplayer) {
    if (maplayer.getAttribute('hasScaleBasedVisibilityFlag') != '1') return null;
    final minScale = double.tryParse(maplayer.getAttribute('minScale') ?? '');
    final maxScale = double.tryParse(maplayer.getAttribute('maxScale') ?? '');
    final effMin = (minScale != null && minScale > 0) ? minScale : null;
    final effMax = (maxScale != null && maxScale > 0) ? maxScale : null;
    if (effMin == null && effMax == null) return null;
    return KMetaLayerStyle(minScale: effMin, maxScale: effMax);
  }

  /// `<labeling type="simple" | "rule-based">` のフィールド（式）・サイズ・色・縁取り・背景枠・改行文字と `labelsEnabled`。
  ///
  /// QGIS が `isExpression="0"` で書いた列名は `"列"` の式に読み替える。
  /// 式そのものは検証せずに持ち帰る（読めない式は地図に出ないだけで、消さない）
  static KMetaLayerStyle? readLabel(
    XmlElement maplayer, {
    QgsSvgFileReader? svgFileReader,
  }) {
    final enabledAttr = maplayer.getAttribute('labelsEnabled');
    final labeling = maplayer.findElements('labeling').firstOrNull;
    if (enabledAttr == null && labeling == null) return null;

    String? expression;
    double? fontPx;
    Color? color;
    Color? halo;
    double? opacity;
    bool? haloEnabled;
    double? haloSizePx;
    String? wrapChar;
    bool? bgEnabled;
    String? bgShape;
    Color? bgColor;
    Color? bgBorderColor;
    double? bgBorderWidth;

    XmlElement? settings;
    if (labeling != null) {
      final lType = labeling.getAttribute('type');
      if (lType == 'simple') {
        settings = labeling.getElement('settings');
      } else if (lType == 'rule-based') {
        // ルールベースラベルは最初の有効な <rule> の <settings> を代表として読む
        final rulesRoot = labeling.getElement('rules') ?? labeling;
        settings = _firstActiveLabelRuleSettings(rulesRoot);
      }
    }

    if (settings != null) {
      final textFormat = settings.getElement('text-format');
      final wc = textFormat?.getAttribute('wrapChar');
      if (wc != null && wc.isNotEmpty) wrapChar = wc;

      final textStyle = settings.getElement('text-style');
      if (textStyle != null) {
        final field = textStyle.getAttribute('fieldName');
        if (field != null && field.isNotEmpty) {
          expression = textStyle.getAttribute('isExpression') == '1' ? field : quoteField(field);
        }
        final size = double.tryParse(textStyle.getAttribute('fontSize') ?? '');
        if (size != null) {
          final unit = textStyle.getAttribute('fontSizeUnit');
          fontPx = unit == 'Point' || unit == null
              ? size / kQgsPxToPt
              : parseQgsSizeToPx(textStyle.getAttribute('fontSize'), unit: unit);
        }
        final rawTextColor = textStyle.getAttribute('textColor');
        color = parseQgsColor(rawTextColor);
        final textAlpha = parseQgsColorAlpha(rawTextColor) ?? 1.0;
        final textOpacity = double.tryParse(textStyle.getAttribute('textOpacity') ?? '') ?? 1.0;
        final effOp = (textAlpha * textOpacity).clamp(0.0, 1.0);
        if ((effOp - 1.0).abs() > 1e-6) opacity = effOp;

        final buffer = textStyle.getElement('text-buffer');
        if (buffer != null) {
          if (buffer.getAttribute('bufferDraw') == '1') {
            halo = parseQgsColor(buffer.getAttribute('bufferColor'));
            final bSize = double.tryParse(buffer.getAttribute('bufferSize') ?? '');
            final bUnit = buffer.getAttribute('bufferSizeUnits') ?? 'MM';
            // 既定の 1 MM は既存ゴールデン互換のため null のままにし、明示変更時のみ持つ
            if (bSize != null && ((bSize - 1.0).abs() > 1e-6 || bUnit != 'MM')) {
              haloSizePx = parseQgsSizeToPx(buffer.getAttribute('bufferSize'), unit: bUnit);
            }
          } else if (buffer.getAttribute('bufferDraw') == '0') {
            haloEnabled = false;
          }
        }

        final bg = textStyle.getElement('background');
        if (bg != null && bg.getAttribute('shapeDraw') == '1') {
          bgEnabled = true;
          final shapeType = bg.getAttribute('shapeType') ?? '0';
          final radiiX = double.tryParse(bg.getAttribute('shapeRadiiX') ?? '') ?? 0.0;
          bgShape = switch (shapeType) {
            '2' || '3' => 'circle',
            _ => radiiX > 0 ? 'roundRect' : 'rect',
          };
          final bgOp = double.tryParse(bg.getAttribute('shapeOpacity') ?? '') ?? 1.0;
          Color? fillRgb = parseQgsColor(bg.getAttribute('shapeFillColor'));
          double fillAlpha = (parseQgsColorAlpha(bg.getAttribute('shapeFillColor')) ?? 1.0) * bgOp;
          Color? borderRgb = parseQgsColor(bg.getAttribute('shapeBorderColor'));
          double borderAlpha = (parseQgsColorAlpha(bg.getAttribute('shapeBorderColor')) ?? 1.0) * bgOp;
          double? borderW = parseQgsSizeToPx(
            bg.getAttribute('shapeBorderWidth'),
            unit: bg.getAttribute('shapeBorderWidthUnit'),
          );

          // QGIS 3.20+ / 4.x の fillSymbol 子要素があればそちらの SimpleFill 設定も考慮
          final fillSym = bg.findElements('symbol').where((s) => s.getAttribute('type') == 'fill').firstOrNull;
          if (fillSym != null) {
            final sub = QgsSymbolReader.read(fillSym, opacity: bgOp, svgFileReader: svgFileReader);
            if (sub != null) {
              fillRgb = sub.polygonFillColor ?? fillRgb;
              fillAlpha = sub.polygonFillOpacity ?? fillAlpha;
              if ((sub.polygonBorderWidth ?? 0) > 0 && (sub.polygonBorderOpacity ?? 1) > 0) {
                borderRgb = sub.polygonBorderColor ?? borderRgb;
                borderAlpha = sub.polygonBorderOpacity ?? borderAlpha;
                borderW = sub.polygonBorderWidth;
              }
            }
          }
          if (fillRgb != null) {
            bgColor = fillRgb.withValues(alpha: fillAlpha.clamp(0.0, 1.0));
          }
          if (borderRgb != null && (borderW ?? 0) > 0) {
            bgBorderColor = borderRgb.withValues(alpha: borderAlpha.clamp(0.0, 1.0));
            bgBorderWidth = borderW;
          }
        }
      }
    }

    final enabled = enabledAttr == null ? (expression != null) : enabledAttr == '1';
    return KMetaLayerStyle(
      labelEnabled: enabled,
      labelProperty: expression,
      labelFontSize: fontPx,
      labelColor: color,
      labelHaloColor: halo,
      labelOpacity: opacity,
      labelHaloEnabled: enabled ? haloEnabled : null,
      labelHaloSize: enabled ? haloSizePx : null,
      labelWrapChar: wrapChar,
      labelBgEnabled: bgEnabled,
      labelBgShape: bgShape,
      labelBgColor: bgColor,
      labelBgBorderColor: bgBorderColor,
      labelBgBorderWidth: bgBorderWidth,
    );
  }

  static XmlElement? _firstActiveLabelRuleSettings(XmlElement parent) {
    for (final rule in parent.findElements('rule')) {
      if (rule.getAttribute('active') == '0') continue;
      final s = rule.getElement('settings');
      if (s != null) return s;
      final child = _firstActiveLabelRuleSettings(rule);
      if (child != null) return child;
    }
    return null;
  }

  /// `renderer-v2` から見た目を拾う。読めない形なら null（＝スタイル無し）。
  static KMetaLayerStyle? readStyle(
    XmlElement maplayer, {
    QgsSvgFileReader? svgFileReader,
  }) {
    final rawRenderer = maplayer.findElements('renderer-v2').firstOrNull;
    if (rawRenderer == null) return null;
    final (:effective, :outerType, :invertedPolygon) = unwrapQgsRendererElement(rawRenderer);

    if (outerType == 'nullSymbol' || effective.getAttribute('type') == 'nullSymbol') {
      return const KMetaLayerStyle(
        pointOpacity: 0,
        lineOpacity: 0,
        polygonFillOpacity: 0,
        polygonBorderOpacity: 0,
        symbolLayers: ResolvedSymbolLayers(nullSymbol: true),
        qgisRenderer: 'nullSymbol',
      );
    }

    final opacity = double.tryParse(childText(maplayer, 'layerOpacity') ?? '') ?? 1.0;
    final style = _readSymbolStyle(
      effective,
      opacity: opacity,
      invertedPolygon: invertedPolygon,
      svgFileReader: svgFileReader,
    );
    final innerType = effective.getAttribute('type');

    if (outerType == 'singleSymbol' || outerType.isEmpty) return style;

    // ラッパー系（invertedPolygonRenderer / mergedFeatureRenderer / pointCluster / pointDisplacement）で
    // 中身が singleSymbol の場合も、`.qgs` のレンダラ構造を壊さないよう qgisRenderer 印を付ける
    if (innerType == 'singleSymbol') {
      return (style ?? const KMetaLayerStyle()).copyWith(
        qgisRenderer: outerType,
      );
    }

    return (style ?? const KMetaLayerStyle()).copyWith(
      qgisRenderer: outerType,
      qgisRendererDef: QgsRendererReader.read(maplayer, svgFileReader: svgFileReader),
    );
  }

  static KMetaLayerStyle? _readSymbolStyle(
    XmlElement renderer, {
    required double opacity,
    required bool invertedPolygon,
    QgsSvgFileReader? svgFileReader,
  }) {
    final symbol = renderer.getElement('symbols')?.findElements('symbol').firstOrNull ??
        renderer.findElements('symbol').firstOrNull;
    if (symbol == null) {
      if (invertedPolygon) {
        return const KMetaLayerStyle(symbolLayers: ResolvedSymbolLayers(invertedPolygon: true));
      }
      return null;
    }
    return QgsSymbolReader.read(
      symbol,
      opacity: opacity,
      invertedPolygon: invertedPolygon,
      svgFileReader: svgFileReader,
    );
  }

  /// QGIS から読んだスタイルをレイヤのスタイルに重ねる。QGIS が持たない項目（ラベルの濃さ等）は残し、
  /// 描き分けの印（[KMetaLayerStyle.qgisRenderer]）は QGIS の今の状態に合わせる（単一シンボルに戻したら外す）
  static Future<void> applyImportedLayerStyle(LayerNode layer, KMetaLayerStyle imported) async {
    final folder = layer.folderNode;
    final folderPath = folder?.getAbsoluteFilePath();
    if (folder == null || folderPath == null) return;
    final existing = (await KMetaService.instance.getMeta(folderPath)).styles.layers[layer.layerKey];
    var merged = imported.mergeWith(existing);
    if (imported.qgisRenderer == null && merged.qgisRenderer != null) {
      merged = merged.withoutQgisRenderer();
    }
    // QGIS 側で単層シンボルに戻された場合は、以前の複合 symbolLayers が残らないようにする
    if (imported.symbolLayers == null && merged.symbolLayers != null) {
      merged = merged.copyWith(clearSymbolLayers: true);
    }
    await KMetaService.instance.setLayerStyle(folderPath, layer.layerKey, merged);
    folder.invalidateMetaCache();
    layer.invalidateKmetaStyleCache();
  }

  /// 描き分けの印（[KMetaLayerStyle.qgisRenderer]）だけを持ち、中身（[KMetaLayerStyle.qgisRendererDef]）が
  /// 無いスタイルに、`.qgs` のレンダラの中身を足す。足した数を返す。
  static Future<int> backfillRendererDefs(
    XmlDocument doc,
    String qgsPath,
    QgsSourceResolver sources,
  ) async {
    var filled = 0;
    final svgFiles = await preloadLocalSvgFiles(
      doc,
      baseDir: p.dirname(p.normalize(qgsPath)),
      rootDir: sources.rootPath,
    );
    String? svgReader(String raw) => svgFiles[raw];
    final projectLayers = doc.rootElement.findElements('projectlayers').firstOrNull;
    for (final maplayer in projectLayers?.findElements('maplayer') ?? const <XmlElement>[]) {
      final def = QgsRendererReader.read(maplayer, svgFileReader: svgReader);
      if (def == null) continue;
      final target = sources.resolve(maplayer, <String>[]);
      if (target == null) continue;
      final (:name, :source, :layer, gpkg: _) = target;
      final folder = layer.folderNode;
      final folderPath = folder?.getAbsoluteFilePath();
      if (folder == null || folderPath == null) continue;

      final isDefault = name == layer.layerName && (source.subset == null || source.subset!.isEmpty);
      if (isDefault) {
        final existing = (await KMetaService.instance.getMeta(folderPath)).styles.layers[layer.layerKey];
        if (existing == null || existing.qgisRenderer == null || existing.qgisRendererDef != null) continue;
        await KMetaService.instance.setLayerStyle(
          folderPath,
          layer.layerKey,
          existing.copyWith(qgisRendererDef: def),
        );
        folder.invalidateMetaCache();
        layer.invalidateKmetaStyleCache();
        filled++;
        continue;
      }
      if (layer.views.isEmpty) await layer.loadViews();
      final view = layer.views.where((v) => v.name == name).firstOrNull;
      final style = view?.style;
      if (view == null || style == null || style.qgisRenderer == null || style.qgisRendererDef != null) {
        continue;
      }
      view.style = style.copyWith(qgisRendererDef: def);
      await layer.persistViews();
      filled++;
    }
    if (filled > 0) AppLogger.debug('[QgsImporter] 描き分けの中身を $filled 件補った（${p.basename(qgsPath)}）');
    return filled;
  }
}

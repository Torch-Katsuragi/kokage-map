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
/// `.qgs` の `<maplayer>` からシンボル/レンダラ・ラベル式（`isExpression` 含む）・不透明度を読み取る。
library;

import 'package:flutter/material.dart' show Color;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../models/kmeta.dart';
import '../../models/nodes/layer_node.dart';
import '../../utils/app_logger.dart';
import '../../utils/label_expression.dart';
import '../kmeta_service.dart';
import 'qgs_renderer_reader.dart';
import 'qgs_source_resolver.dart';
import 'qgs_xml.dart';

/// シンボル・分類/段階/ルール別レンダラ・ラベル設定の読み取りと既存スタイルへの反映。
abstract final class QgsStyleReader {
  /// シンボルとラベルをまとめて読む（どちらも無ければ null）
  static KMetaLayerStyle? readStyleWithLabel(XmlElement maplayer) {
    final symbol = readStyle(maplayer);
    final label = readLabel(maplayer);
    if (label == null) return symbol;
    return (symbol ?? const KMetaLayerStyle()).mergeWith(label);
  }

  /// `<labeling type="simple">` のフィールド（式）・サイズ・色と `labelsEnabled`。
  ///
  /// QGIS が `isExpression="0"` で書いた列名は `"列"` の式に読み替える。
  /// 式そのものは検証せずに持ち帰る（読めない式は地図に出ないだけで、消さない）
  static KMetaLayerStyle? readLabel(XmlElement maplayer) {
    final enabledAttr = maplayer.getAttribute('labelsEnabled');
    final labeling = maplayer.findElements('labeling').firstOrNull;
    if (enabledAttr == null && labeling == null) return null;
    String? expression;
    double? fontPx;
    Color? color;
    Color? halo;
    if (labeling != null && labeling.getAttribute('type') == 'simple') {
      final textStyle = labeling.getElement('settings')?.getElement('text-style');
      if (textStyle != null) {
        final field = textStyle.getAttribute('fieldName');
        if (field != null && field.isNotEmpty) {
          expression = textStyle.getAttribute('isExpression') == '1' ? field : quoteField(field);
        }
        final size = double.tryParse(textStyle.getAttribute('fontSize') ?? '');
        if (size != null) {
          // Point → px（書き出しの逆: px * kQgsPxToPt = pt）
          fontPx = textStyle.getAttribute('fontSizeUnit') == 'Point' ? size / kQgsPxToPt : size;
        }
        color = parseQgsColor(textStyle.getAttribute('textColor'));
        final buffer = textStyle.getElement('text-buffer');
        if (buffer != null && buffer.getAttribute('bufferDraw') == '1') {
          halo = parseQgsColor(buffer.getAttribute('bufferColor'));
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
    );
  }

  /// `renderer-v2` から見た目を拾う。読めない形なら null（＝スタイル無し）。
  ///
  /// > [!NOTE] 拾うのは単一シンボルの1レイヤ目だけ
  /// > QGISのシンボルは重ね合わせもできるが、こかげマップ 側に受け皿が無い。
  /// > **完全再現は狙わない。** 狙うと「開けるファイルを選り好みする」方向に行く。
  ///
  /// 描き分け（分類・段階・ルール）は、最初のシンボルの色を代表の色にし、中身を
  /// [KMetaLayerStyle.qgisRendererDef] に読む（地物ごとの色はそこから決める。2026-10-11）
  static KMetaLayerStyle? readStyle(XmlElement maplayer) {
    final style = _readSymbolStyle(maplayer);
    final type = maplayer.findElements('renderer-v2').firstOrNull?.getAttribute('type');
    // 単一シンボル以外は、代表の色で描きつつ「QGIS で設定されたスタイル」として印を付ける
    if (type == null || type == 'singleSymbol') return style;
    return (style ?? const KMetaLayerStyle()).copyWith(
      qgisRenderer: type,
      qgisRendererDef: QgsRendererReader.read(maplayer),
    );
  }

  static KMetaLayerStyle? _readSymbolStyle(XmlElement maplayer) {
    final renderer = maplayer.findElements('renderer-v2').firstOrNull;
    if (renderer == null) return null;
    final symbol = renderer.findAllElements('symbol').firstOrNull;
    if (symbol == null) return null;
    return QgsSymbolReader.read(symbol);
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
    await KMetaService.instance.setLayerStyle(folderPath, layer.layerKey, merged);
    folder.invalidateMetaCache();
    layer.invalidateKmetaStyleCache();
  }

  /// 描き分けの印（[KMetaLayerStyle.qgisRenderer]）だけを持ち、中身（[KMetaLayerStyle.qgisRendererDef]）が
  /// 無いスタイルに、`.qgs` のレンダラの中身を足す。足した数を返す。
  ///
  /// 中身を持つようになった版（2026-10-11）より前に取り込んだプロジェクトは印だけを持つ。自分が書いた
  /// `.qgs` は読み戻さないので、QGIS で保存し直すまで代表の 1 色のままになる。それを埋めるだけで、
  /// View・可視性・他のスタイルには触らない（全部を取り込み直すとアプリだけが持つ設定を巻き戻しうる）
  static Future<int> backfillRendererDefs(
    XmlDocument doc,
    String qgsPath,
    QgsSourceResolver sources,
  ) async {
    var filled = 0;
    final projectLayers = doc.rootElement.findElements('projectlayers').firstOrNull;
    for (final maplayer in projectLayers?.findElements('maplayer') ?? const <XmlElement>[]) {
      final def = QgsRendererReader.read(maplayer);
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
        if (existing?.qgisRenderer != def.kind.qgisType || existing?.qgisRendererDef != null) continue;
        await KMetaService.instance.setLayerStyle(
          folderPath,
          layer.layerKey,
          existing!.copyWith(qgisRendererDef: def),
        );
        folder.invalidateMetaCache();
        layer.invalidateKmetaStyleCache();
        filled++;
        continue;
      }
      if (layer.views.isEmpty) await layer.loadViews();
      final view = layer.views.where((v) => v.name == name).firstOrNull;
      final style = view?.style;
      if (view == null || style == null || style.qgisRenderer != def.kind.qgisType || style.qgisRendererDef != null) {
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

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
/// `.qgs` の属性フォーム（`ValueRelation` の参照先解決を含む）とテーブル結合（`<vectorjoins>`）の取り込み。
library;

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../models/layer_join.dart';
import '../../models/nodes/layer_node.dart';
import '../../models/qgis_form.dart';
import '../../utils/app_logger.dart';
import '../kmeta_service.dart';
import 'qgs_form_reader.dart';
import 'qgs_source_resolver.dart';
import 'qgs_xml.dart';

/// 属性フォーム設定と CSV テーブル結合の読み取り・反映。
abstract final class QgsRelationImporter {
  /// [formSource] のレイヤごとに、maplayer の属性フォームの設定を読んでフォルダ設定に書く。
  /// 設定の無いレイヤは外す（[onlyNonEmpty] なら外さない）。書いた（設定のある）数を返す。
  ///
  /// ValueRelation の参照先（maplayer の id）は、ツリーの gpkg とレイヤに読み替えて設定に入れる。
  /// 読み替えられなければ [discarded] に足す（その列は文字の欄になる）
  static Future<int> applyForms(
    Map<LayerNode, XmlElement> formSource,
    XmlElement? projectLayers,
    QgsSourceResolver sources,
    List<String> discarded, {
    bool onlyNonEmpty = false,
  }) async {
    final byId = <String, XmlElement>{
      for (final m in projectLayers?.findElements('maplayer') ?? const <XmlElement>[])
        ?childText(m, 'id'): m,
    };
    var count = 0;
    for (final MapEntry(key: layer, value: maplayer) in formSource.entries) {
      final folder = layer.folderNode;
      final folderPath = folder?.getAbsoluteFilePath();
      if (folder == null || folderPath == null) continue;
      var form = QgsFormReader.read(maplayer);
      if (form == null && onlyNonEmpty) continue;
      if (form != null) {
        final fields = <String, QgisFieldForm>{};
        for (final MapEntry(key: name, value: field) in form.fields.entries) {
          if (field.kind != QgisWidgetKind.valueRelation) {
            fields[name] = field;
            continue;
          }
          final ref = byId[field.config['Layer']];
          final target = ref == null ? null : sources.resolve(ref, <String>[]);
          final gpkgPath = target == null ? null : QgsSourceResolver.gpkgIndexPath(target.gpkg);
          if (target == null || gpkgPath == null) {
            discarded.add('${layer.layerName} の $name（値の関係の参照先 ${field.config['LayerName'] ?? ''} が見つかりません）');
            fields[name] = field;
            continue;
          }
          fields[name] = QgisFieldForm.fromJson({
            ...field.toJson(),
            'config': {
              ...field.config,
              kRelationTargetKey: {
                'gpkg': p.relative(gpkgPath, from: folderPath).replaceAll(r'\', '/'),
                'layer': target.layer.layerName,
              },
            },
          });
        }
        form = form.withFields(fields);
        count++;
      }
      await KMetaService.instance.setLayerForm(folderPath, layer.layerKey, form);
      folder.invalidateMetaCache();
    }
    return count;
  }

  /// 属性フォームの設定を持たないレイヤに、`.qgs` の設定を足す。足した数を返す。
  ///
  /// 属性フォームを読むようになった版（2026-10-11）より前に取り込んだプロジェクトと、QGIS で設定してから
  /// こかげマップが先に書き直した `.qgs`（QGIS の `<fieldConfiguration>` などはそのまま残る）のため。
  /// 既に持っているレイヤには触らない（QGIS で保存し直したときの取り込みが差し替える）
  static Future<int> backfillForms(
    XmlDocument doc,
    String qgsPath,
    QgsSourceResolver sources,
  ) async {
    final projectLayers = doc.rootElement.findElements('projectlayers').firstOrNull;
    final formSource = <LayerNode, XmlElement>{};
    for (final maplayer in projectLayers?.findElements('maplayer') ?? const <XmlElement>[]) {
      final target = sources.resolve(maplayer, <String>[]);
      if (target == null) continue;
      final (:name, :source, :layer, gpkg: _) = target;
      final isDefault = name == layer.layerName && (source.subset == null || source.subset!.isEmpty);
      if (isDefault || !formSource.containsKey(layer)) formSource[layer] = maplayer;
    }
    final missing = <LayerNode, XmlElement>{};
    for (final MapEntry(key: layer, value: maplayer) in formSource.entries) {
      final folderPath = layer.folderNode?.getAbsoluteFilePath();
      if (folderPath == null) continue;
      if ((await KMetaService.instance.getMeta(folderPath)).forms.containsKey(layer.layerKey)) continue;
      missing[layer] = maplayer;
    }
    final filled = await applyForms(missing, projectLayers, sources, <String>[], onlyNonEmpty: true);
    if (filled > 0) AppLogger.debug('[QgsImporter] 属性フォームの設定を $filled 件補った（${p.basename(qgsPath)}）');
    return filled;
  }

  /// [formSource] のレイヤごとに、maplayer の `<vectorjoins>` を読んでフォルダ設定の結合に書く（無ければ外す）。
  /// 結合先が表のノード（座標の無い CSV）に読み替えられなければ [discarded] に足す
  static Future<void> applyJoins(
    Map<LayerNode, XmlElement> formSource,
    XmlElement? projectLayers,
    QgsSourceResolver sources,
    List<String> discarded,
  ) async {
    final names = <String, String>{
      for (final m in projectLayers?.findElements('maplayer') ?? const <XmlElement>[])
        ?childText(m, 'id'): childText(m, 'layername') ?? '',
    };
    for (final MapEntry(key: layer, value: maplayer) in formSource.entries) {
      final folder = layer.folderNode;
      final folderPath = folder?.getAbsoluteFilePath();
      if (folder == null || folderPath == null) continue;
      final joins = <LayerJoin>[];
      for (final j in maplayer.getElement('vectorjoins')?.findElements('join') ?? const <XmlElement>[]) {
        final id = j.getAttribute('joinLayerId') ?? '';
        final table = sources.tables[id];
        final joinField = j.getAttribute('joinFieldName');
        final targetField = j.getAttribute('targetFieldName');
        if (table == null || joinField == null || targetField == null) {
          discarded.add('${layer.layerName} の結合（結合先 ${names[id] ?? id} は表ではないので未対応）');
          continue;
        }
        final subset = j.getElement('joinFieldsSubset');
        joins.add(
          LayerJoin(
            table: p.relative(table.sourcePath, from: folderPath).replaceAll(r'\', '/'),
            joinField: joinField,
            targetField: targetField,
            fields: subset == null ? null : [for (final f in subset.findElements('field')) ?f.getAttribute('name')],
            prefix: j.getAttribute('hasCustomPrefix') == '1' ? (j.getAttribute('customPrefix') ?? '') : null,
            memoryCache: j.getAttribute('memoryCache') != '0',
          ),
        );
      }
      await KMetaService.instance.setLayerJoins(folderPath, layer.layerKey, joins);
      folder.invalidateMetaCache();
      if (layer.featuresLoaded) {
        await layer.loadJoins();
        await layer.refreshStyleGroups();
      }
    }
  }
}

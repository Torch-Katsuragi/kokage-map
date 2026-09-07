// View（レイヤに対する「フィルタ＋スタイル」）のテスト
//
// View は `.qgs` のレイヤと 1:1 で対応させる前提の概念なので、
// **永続化した形が壊れないこと**が要件になる。設計は
// docs/technical/project-format-design.md。
//
// 検証するのは3点:
//   1. `.kmeta.json` への往復で View 定義が壊れないこと（順序を含む）
//   2. View を持たない `.kmeta.json` を読んでも壊れないこと（後方互換）
//   3. 表示中 View のフィルタが WHERE 句として正しく束ねられること
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/geopackage/feature_repository.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/models/nodes/view_node.dart';

void main() {
  group('KMetaView の永続化', () {
    test('往復しても内容と順序が保たれる', () {
      const meta = KMeta(
        views: {
          'rinshoban.gpkg/rinshoban': [
            KMetaView(name: 'スギ', filter: "樹種 = 'スギ'"),
            KMetaView(name: 'ヒノキ', filter: "樹種 = 'ヒノキ'"),
            KMetaView(name: '全部'),
          ],
        },
        visibility: KMetaVisibility(
          views: {'rinshoban.gpkg/rinshoban/ヒノキ': false},
        ),
      );

      final restored = KMeta.fromJson(
        jsonDecode(jsonEncode(meta.toJson())) as Map<String, dynamic>,
      );

      final views = restored.getViews('rinshoban.gpkg/rinshoban');
      expect(views.map((v) => v.name), ['スギ', 'ヒノキ', '全部'],
          reason: 'z順の根拠なので順序が変わってはいけない');
      expect(views[0].filter, "樹種 = 'スギ'");
      expect(views[2].filter, isNull, reason: 'フィルタ無しは書かない');

      expect(restored.getViewVisibility('rinshoban.gpkg/rinshoban/ヒノキ'), false);
      expect(restored.getViewVisibility('rinshoban.gpkg/rinshoban/スギ'), isNull,
          reason: '未設定は null（＝既定の true を呼び出し側が入れる）');
    });

    test('スタイル付きの View も往復する', () {
      const meta = KMeta(
        views: {
          'a.gpkg/l': [
            KMetaView(
              name: '色つき',
              style: KMetaLayerStyle(
                lineWidth: 3.5,
                lineColor: Color(0xFFF44336),
              ),
            ),
          ],
        },
      );

      final restored = KMeta.fromJson(
        jsonDecode(jsonEncode(meta.toJson())) as Map<String, dynamic>,
      );
      final style = restored.getViews('a.gpkg/l').single.style;
      expect(style, isNotNull);
      expect(style!.lineWidth, 3.5);
      // 往復後は素の Color になる（MaterialColor では戻らない）
      expect(style.lineColor?.toARGB32(), 0xFFF44336);
    });

    test('views を持たない .kmeta.json を読んでも壊れない（後方互換）', () {
      // View 導入前に書かれたファイルを模す
      final legacy = {
        'version': 2,
        'visibility': {
          'layers': {'a.gpkg/l': true},
        },
      };

      final meta = KMeta.fromJson(legacy);
      expect(meta.views, isEmpty);
      expect(meta.getViews('a.gpkg/l'), isEmpty,
          reason: '空＝「View未定義」。既定Viewを1枚作るのは呼び出し側の責務');
      expect(meta.getLayerVisibility('a.gpkg/l'), true);
    });

    test('View が空なら JSON に views キーを書かない', () {
      const meta = KMeta();
      expect(meta.toJson().containsKey('views'), isFalse);
      expect(meta.isEmpty, isTrue);
    });
  });

  group('フィルタの検査', () {
    test('空・空白は絞り込み無しになる', () {
      expect(FeatureRepository.sanitizeFilter(null), isNull);
      expect(FeatureRepository.sanitizeFilter(''), isNull);
      expect(FeatureRepository.sanitizeFilter('   '), isNull);
    });

    test('通常の式は通る（前後の空白は落とす）', () {
      expect(
        FeatureRepository.sanitizeFilter("  樹種 = 'スギ' AND 面積 > 10 "),
        "樹種 = 'スギ' AND 面積 > 10",
      );
    });

    test('文を切り替えられる形は弾く', () {
      // `.kmeta.json` は Drive 経由で他人から届きうる
      expect(
        FeatureRepository.sanitizeFilter('1=1; DROP TABLE rinshoban'),
        isNull,
      );
    });
  });

  group('表示中Viewのフィルタの束ね方', () {
    /// DBには触らない。[LayerNode.activeViewFilter] は [LayerNode.views] しか
    /// 見ないので、親を持たない裸のレイヤで足りる。
    PointLayerNode makeLayer(List<ViewNode> Function(PointLayerNode) build) {
      final layer = PointLayerNode(
        GeoPackageFile(const ['dummy.gpkg'], absolutePath: '/dummy.gpkg'),
        'l',
      );
      layer.views.addAll(build(layer));
      return layer;
    }

    test('View未ロードなら絞り込まない', () {
      final layer = makeLayer((_) => []);
      expect(layer.activeViewFilter, isNull);
      expect(layer.hasVisibleView, isTrue, reason: '未ロードを「全消灯」と誤解しないこと');
    });

    test('フィルタ付きViewが複数見えていれば OR で束ねる', () {
      final layer = makeLayer(
        (l) => [
          ViewNode(name: 'スギ', parent: l, filter: "樹種 = 'スギ'"),
          ViewNode(name: 'ヒノキ', parent: l, filter: "樹種 = 'ヒノキ'"),
        ],
      );
      expect(layer.activeViewFilter, "(樹種 = 'スギ') OR (樹種 = 'ヒノキ')");
    });

    test('消灯したViewのフィルタは入らない', () {
      final layer = makeLayer(
        (l) => [
          ViewNode(name: 'スギ', parent: l, filter: "樹種 = 'スギ'"),
          ViewNode(
            name: 'ヒノキ',
            parent: l,
            filter: "樹種 = 'ヒノキ'",
            visible: false,
          ),
        ],
      );
      expect(layer.activeViewFilter, "(樹種 = 'スギ')");
    });

    test('フィルタ無しのViewが1枚でも見えていれば全件出す', () {
      final layer = makeLayer(
        (l) => [
          ViewNode(name: 'スギ', parent: l, filter: "樹種 = 'スギ'"),
          ViewNode(name: '全部', parent: l),
        ],
      );
      expect(layer.activeViewFilter, isNull);
    });

    test('全消灯なら何も描かない', () {
      final layer = makeLayer(
        (l) => [
          ViewNode(name: 'スギ', parent: l, filter: "樹種 = 'スギ'", visible: false),
        ],
      );
      expect(layer.hasVisibleView, isFalse);
    });
  });
}

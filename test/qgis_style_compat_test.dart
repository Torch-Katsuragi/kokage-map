// QGIS スタイル表現強化（縁取り・ハッチング・破線・点7形状・縮尺制限・追加レンダラ・ラベル背景・データ定義式）と
// プロジェクト互換（.qgz・単一別名.qgs・GeoPackage 内 qgis_projects / layer_styles・横置き.qml）の統合テスト。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart' show Color, Colors, Offset, Path, Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/core/terrain/dem_grid.dart';
import 'package:root_maps/core/terrain/fill_pattern_painter.dart';
import 'package:root_maps/core/terrain/terrain_mesh.dart';
import 'package:root_maps/core/terrain/terrain_scene.dart';
import 'package:root_maps/core/terrain/web_mercator.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/models/nodes/layer_tree_node.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/qgis/qgs_auto_refresh.dart';
import 'package:root_maps/services/qgis/qgs_document.dart';
import 'package:root_maps/services/qgis/qgs_embedded_style_loader.dart';
import 'package:root_maps/services/qgis/qgs_meta_store.dart';
import 'package:root_maps/services/qgis/qgs_model.dart';
import 'package:root_maps/services/qgis/qgs_read_back.dart';
import 'package:root_maps/services/qgis/qgs_style_reader.dart';
import 'package:root_maps/services/qgis/qgs_writer.dart';
import 'package:root_maps/services/qgis/qgs_xml.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xml/xml.dart';

import 'support/foreign_geom_gpkg.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    QgsAutoRefresh.instance.enabled = false;
  });

  XmlElement parseMapLayer(String innerXml, {String attrs = ''}) {
    final doc = XmlDocument.parse('<maplayer type="vector" $attrs>$innerXml</maplayer>');
    return doc.rootElement;
  }

  TerrainMesh buildFlatMesh({double lon = 135.96, double lat = 33.93}) {
    final ox = WebMercator.xFromLon(lon) - 200;
    final oy = WebMercator.yFromLat(lat) - 200;
    final dem = DemGrid(
      cols: 9,
      rows: 9,
      originX: ox,
      originY: oy,
      cellSize: 50,
      heights: Float32List(81),
    );
    return TerrainMeshBuilder(dem, textureWidth: 8, textureHeight: 8, chunkSize: 4).buildStatic();
  }

  group('線の縁取り（ケーシング）・破線・オフセット・シンボルレベル融合', () {
    test('2層 SimpleLine を UI の縁取り設定と pass 0/1 ストロークへ読み取る', () {
      final ml = parseMapLayer('''
        <renderer-v2 type="singleSymbol" symbollevels="1">
          <symbols>
            <symbol type="line" name="0" alpha="1">
              <layer class="SimpleLine" enabled="1" pass="0" locked="0">
                <Option type="Map">
                  <Option type="QString" name="line_color" value="255,255,255,255"/>
                  <Option type="QString" name="line_width" value="2.11667"/>
                  <Option type="QString" name="line_width_unit" value="MM"/>
                  <Option type="QString" name="line_style" value="solid"/>
                </Option>
              </layer>
              <layer class="SimpleLine" enabled="1" pass="1" locked="0">
                <Option type="Map">
                  <Option type="QString" name="line_color" value="220,30,30,255"/>
                  <Option type="QString" name="line_width" value="1.05833"/>
                  <Option type="QString" name="line_width_unit" value="MM"/>
                  <Option type="QString" name="line_style" value="dash"/>
                </Option>
              </layer>
            </symbol>
          </symbols>
        </renderer-v2>
      ''');

      final style = QgsStyleReader.readStyleWithLabel(ml)!;
      expect(style.lineCasingEnabled, isTrue);
      expect(style.lineColor, const Color(0xFFDC1E1E));
      expect(style.lineCasingColor, const Color(0xFFFFFFFF));
      expect(style.lineWidth, closeTo(4.0, 0.05));
      expect(style.lineCasingWidth, closeTo(2.0, 0.05));
      expect(style.lineDash, 'dash');
      // 同一不透明度の標準 2 層ケーシングは UI から編集しやすいようフラット項目へ集約される
      expect(style.symbolLayers, isNull);
      final effective = buildEffectiveLineStrokes(
        lineColor: style.lineColor!,
        lineWidth: style.lineWidth!,
        dash: LineDashPattern.fromId(style.lineDash),
        casingEnabled: style.lineCasingEnabled!,
        casingColor: style.lineCasingColor!,
        casingWidth: style.lineCasingWidth!,
      );
      expect(effective, hasLength(2));
      expect(effective[0].pass, 0);
      expect(effective[1].pass, 1);
      expect(effective[1].isDashed, isTrue);
    });

    test('<symbol><buffer enabled="1"> も縁取りストロークとして読み取る', () {
      final ml = parseMapLayer('''
        <renderer-v2 type="singleSymbol">
          <symbols>
            <symbol type="line" name="0" alpha="1">
              <buffer enabled="1" size="0.529167" sizeUnit="MM" color="0,0,0,255"/>
              <layer class="SimpleLine" enabled="1" pass="0">
                <Option type="Map">
                  <Option type="QString" name="line_color" value="255,200,0,255"/>
                  <Option type="QString" name="line_width" value="0.79375"/>
                  <Option type="QString" name="line_width_unit" value="MM"/>
                </Option>
              </layer>
            </symbol>
          </symbols>
        </renderer-v2>
      ''');

      final style = QgsStyleReader.readStyleWithLabel(ml)!;
      expect(style.lineCasingEnabled, isTrue);
      expect(style.lineCasingColor, const Color(0xFF000000));
      expect(style.symbolLayers!.strokes, hasLength(2));
      expect(style.symbolLayers!.strokes.first.widthPx, greaterThan(style.symbolLayers!.strokes.last.widthPx));
    });

    test('カスタム破線（use_custom_dash）・平行オフセット・MarkerLine を読み取る', () {
      final ml = parseMapLayer('''
        <renderer-v2 type="singleSymbol">
          <symbols>
            <symbol type="line" name="0" alpha="0.8">
              <layer class="SimpleLine" enabled="1" pass="0">
                <Option type="Map">
                  <Option type="QString" name="line_color" value="10,20,30,255"/>
                  <Option type="QString" name="line_width" value="2"/>
                  <Option type="QString" name="line_width_unit" value="Pixel"/>
                  <Option type="QString" name="use_custom_dash" value="1"/>
                  <Option type="QString" name="customdash" value="6;3;2;3"/>
                  <Option type="QString" name="customdash_unit" value="Pixel"/>
                  <Option type="QString" name="offset" value="3"/>
                  <Option type="QString" name="offset_unit" value="Pixel"/>
                </Option>
              </layer>
              <layer class="MarkerLine" enabled="1" pass="1">
                <Option type="Map">
                  <Option type="QString" name="interval" value="8"/>
                  <Option type="QString" name="interval_unit" value="Pixel"/>
                </Option>
                <symbol type="marker" name="@0@1" alpha="1">
                  <layer class="SimpleMarker" enabled="1">
                    <Option type="Map">
                      <Option type="QString" name="color" value="200,0,0,255"/>
                      <Option type="QString" name="size" value="3"/>
                      <Option type="QString" name="size_unit" value="Pixel"/>
                    </Option>
                  </layer>
                </symbol>
              </layer>
            </symbol>
          </symbols>
        </renderer-v2>
        <layerOpacity>0.5</layerOpacity>
      ''');

      final style = QgsStyleReader.readStyleWithLabel(ml)!;
      // symbol alpha 0.8 * layerOpacity 0.5 = 0.4
      expect(style.lineOpacity, closeTo(0.4, 0.02));
      final strokes = style.symbolLayers!.strokes;
      expect(strokes, hasLength(2));
      expect(strokes[0].dashArray, [6.0, 3.0, 2.0, 3.0]);
      expect(strokes[0].offsetPx, closeTo(3.0, 1e-6));
      expect(strokes[1].isDashed, isTrue);
    });

    test('TerrainSceneBuilder は複数地物のケーシングを pass 昇順（背面一括 → 前面一括）に整列する', () {
      final mesh = buildFlatMesh();
      final f1 = geo.Feature(
        geometry: geo.LineString.from(const [
          geo.Geographic(lon: 135.9595, lat: 33.9300),
          geo.Geographic(lon: 135.9605, lat: 33.9300),
        ]),
        properties: const {'__style': 'road'},
      );
      final f2 = geo.Feature(
        geometry: geo.LineString.from(const [
          geo.Geographic(lon: 135.9600, lat: 33.9295),
          geo.Geographic(lon: 135.9600, lat: 33.9305),
        ]),
        properties: const {'__style': 'road'},
      );

      const casedStyle = TerrainFeatureStyle(
        lineColor: Colors.orange,
        lineWidth: 4,
        fillColor: Color(0x00000000),
        outlineColor: Color(0x00000000),
        outlineWidth: 0,
        pointColor: Color(0x00000000),
        pointSize: 0,
        lineStrokes: [
          ResolvedLineStroke(color: Colors.white, widthPx: 8, pass: 0),
          ResolvedLineStroke(color: Colors.orange, widthPx: 4, pass: 1),
        ],
      );

      final scene = TerrainSceneBuilder(
        mesh: mesh,
        styleKeyProp: '__style',
        stylesByKey: {'road': casedStyle},
      ).build(lines: [f1, f2]);

      expect(scene.lines, hasLength(4));
      // 先頭 2 本が全地物の縁取り（白・太さ8）、後半 2 本が全地物の芯線（橙・太さ4）
      expect(scene.lines[0].color, Colors.white);
      expect(scene.lines[1].color, Colors.white);
      expect(scene.lines[2].color, Colors.orange);
      expect(scene.lines[3].color, Colors.orange);
    });
  });

  group('面のハッチング・ドット・パターンシェーダ描画', () {
    test('SimpleFill のブラシ種別（b_diagonal / diagonal_x / dense4 / no）を読み取る', () {
      for (final (brush, expected) in [
        ('b_diagonal', 'slash'),
        ('f_diagonal', 'backslash'),
        ('diagonal_x', 'cross'),
        ('cross', 'grid'),
        ('horizontal', 'horizontal'),
        ('vertical', 'vertical'),
        ('dense4', 'dots'),
      ]) {
        final ml = parseMapLayer('''
          <renderer-v2 type="singleSymbol">
            <symbols>
              <symbol type="fill" name="0" alpha="1">
                <layer class="SimpleFill" enabled="1">
                  <Option type="Map">
                    <Option type="QString" name="color" value="46,125,50,255"/>
                    <Option type="QString" name="style" value="$brush"/>
                    <Option type="QString" name="outline_color" value="20,60,20,255"/>
                    <Option type="QString" name="outline_width" value="0.5"/>
                    <Option type="QString" name="outline_width_unit" value="MM"/>
                  </Option>
                </layer>
              </symbol>
            </symbols>
          </renderer-v2>
        ''');
        final style = QgsStyleReader.readStyleWithLabel(ml)!;
        expect(style.polygonFillPattern, expected, reason: 'brush=$brush');
      }
      // style="no" + 実線枠は既存互換のとおり polygonFillOpacity=0 として読まれる
      final noFillMl = parseMapLayer('''
        <renderer-v2 type="singleSymbol">
          <symbols>
            <symbol type="fill" name="0" alpha="1">
              <layer class="SimpleFill" enabled="1">
                <Option type="Map">
                  <Option type="QString" name="color" value="46,125,50,255"/>
                  <Option type="QString" name="style" value="no"/>
                  <Option type="QString" name="outline_color" value="20,60,20,255"/>
                  <Option type="QString" name="outline_width" value="0.5"/>
                  <Option type="QString" name="outline_width_unit" value="MM"/>
                </Option>
              </layer>
            </symbol>
          </symbols>
        </renderer-v2>
      ''');
      expect(QgsStyleReader.readStyleWithLabel(noFillMl)!.polygonFillOpacity, 0.0);
    });

    test('下地 SimpleFill + LinePatternFill + PointPatternFill + SimpleLine の複合塗りを保持する', () {
      final ml = parseMapLayer('''
        <renderer-v2 type="singleSymbol">
          <symbols>
            <symbol type="fill" name="0" alpha="1">
              <layer class="SimpleFill" enabled="1">
                <Option type="Map">
                  <Option type="QString" name="color" value="230,245,230,180"/>
                  <Option type="QString" name="style" value="solid"/>
                  <Option type="QString" name="outline_style" value="no"/>
                </Option>
              </layer>
              <layer class="LinePatternFill" enabled="1">
                <Option type="Map">
                  <Option type="QString" name="angle" value="45"/>
                  <Option type="QString" name="distance" value="2.5"/>
                  <Option type="QString" name="distance_unit" value="MM"/>
                </Option>
                <symbol type="line" name="@0@1" alpha="1">
                  <layer class="SimpleLine" enabled="1">
                    <Option type="Map">
                      <Option type="QString" name="line_color" value="0,120,40,255"/>
                      <Option type="QString" name="line_width" value="0.4"/>
                      <Option type="QString" name="line_width_unit" value="MM"/>
                    </Option>
                  </layer>
                </symbol>
              </layer>
              <layer class="PointPatternFill" enabled="1">
                <Option type="Map">
                  <Option type="QString" name="distance_x" value="4.0"/>
                  <Option type="QString" name="distance_y" value="4.0"/>
                  <Option type="QString" name="distance_x_unit" value="MM"/>
                </Option>
                <symbol type="marker" name="@0@2" alpha="1">
                  <layer class="SimpleMarker" enabled="1">
                    <Option type="Map">
                      <Option type="QString" name="color" value="0,80,20,255"/>
                      <Option type="QString" name="size" value="1.2"/>
                      <Option type="QString" name="size_unit" value="MM"/>
                    </Option>
                  </layer>
                </symbol>
              </layer>
              <layer class="SimpleLine" enabled="1">
                <Option type="Map">
                  <Option type="QString" name="line_color" value="0,60,15,255"/>
                  <Option type="QString" name="line_width" value="0.6"/>
                  <Option type="QString" name="line_width_unit" value="MM"/>
                  <Option type="QString" name="line_style" value="dash dot"/>
                </Option>
              </layer>
            </symbol>
          </symbols>
        </renderer-v2>
      ''');

      final style = QgsStyleReader.readStyleWithLabel(ml)!;
      final sl = style.symbolLayers!;
      expect(sl.fills, hasLength(3));
      expect(sl.fills[0].kind, FillLayerKind.solid);
      expect(sl.fills[1].kind, FillLayerKind.linePattern);
      expect(sl.fills[1].angleDeg, 45.0);
      expect(sl.fills[2].kind, FillLayerKind.pointPattern);
      expect(sl.outlineStrokes, hasLength(1));
      expect(sl.outlineStrokes.single.isDashed, isTrue);
    });

    test('FillPatternCache・区域外マスク塗り・7形状マーカーが Canvas に実ピクセルを描画する', () async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      const bounds = Rect.fromLTWH(0, 0, 128, 128);
      final poly = Path()..addRect(const Rect.fromLTWH(32, 32, 64, 64));

      // 通常ハッチング + ドット
      drawPolygonFillLayers(
        canvas,
        poly,
        const [
          ResolvedFillLayer.linePattern(color: Color(0xFF1B5E20), angleDeg: 45, spacingPx: 8, lineWidthPx: 2),
          ResolvedFillLayer.pointPattern(color: Color(0xFF0D47A1), dxPx: 10, dyPx: 10, pointRadiusPx: 2),
        ],
      );
      // 区域外マスク塗り（外周だけ塗る）
      drawPolygonFillLayers(
        canvas,
        poly,
        const [ResolvedFillLayer.solid(color: Color(0x88000000))],
        inverted: true,
        outerBounds: bounds,
      );
      // 全 7 形状マーカー
      for (var i = 0; i < PointMarkerShape.values.length; i++) {
        drawPointMarkerShape(
          canvas,
          Offset(12.0 + i * 16.0, 16.0),
          6.0,
          shape: PointMarkerShape.values[i],
          fillColor: const Color(0xFFE53935),
          outlineColor: const Color(0xFFFFFFFF),
          outlineWidth: 1.5,
          angleDeg: 15.0 * i,
        );
      }

      final picture = recorder.endRecording();
      final image = picture.toImageSync(128, 128);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      picture.dispose();
      image.dispose();

      expect(bytes, isNotNull);
      final u8 = bytes!.buffer.asUint8List();
      // 非透明ピクセルが描画されていること
      var nonZeroAlpha = 0;
      for (var i = 3; i < u8.length; i += 4) {
        if (u8[i] > 0) nonZeroAlpha++;
      }
      expect(nonZeroAlpha, greaterThan(2000));
    });
  });

  group('点マーカー 7 形状・単位換算・縮尺制限・追加レンダラ・ラベル・データ定義式', () {
    test('点マーカーの 7 形状・縁取り OFF・回転角と単位換算（MM / Point / Inch / Pixel）', () {
      expect(parseQgsSizeToPx('1', unit: 'MM'), closeTo(1 / kQgsPxToMm, 1e-4));
      expect(parseQgsSizeToPx('12', unit: 'Point'), closeTo(16.0, 1e-4));
      expect(parseQgsSizeToPx('1', unit: 'Inch'), closeTo(96.0, 1e-2));
      expect(parseQgsSizeToPx('7', unit: 'Pixel'), closeTo(7.0, 1e-6));

      final ml = parseMapLayer('''
        <renderer-v2 type="singleSymbol">
          <symbols>
            <symbol type="marker" name="0" alpha="1">
              <layer class="SimpleMarker" enabled="1">
                <Option type="Map">
                  <Option type="QString" name="name" value="star"/>
                  <Option type="QString" name="color" value="255,180,0,255"/>
                  <Option type="QString" name="size" value="16"/>
                  <Option type="QString" name="size_unit" value="Pixel"/>
                  <Option type="QString" name="outline_style" value="no"/>
                  <Option type="QString" name="angle" value="30"/>
                </Option>
              </layer>
            </symbol>
          </symbols>
        </renderer-v2>
      ''');

      final style = QgsStyleReader.readStyleWithLabel(ml)!;
      expect(style.pointShape, 'star');
      expect(style.pointOutlineEnabled, isFalse);
      expect(style.pointAngle, closeTo(30.0, 1e-6));
      // 直径 16px → 半径 8px
      expect(style.pointSize, closeTo(8.0, 1e-6));
    });

    test('縮尺依存表示: <maplayer> 極性と <rule> 極性の両方で正しく表示・非表示を判定する', () {
      // <maplayer>: minScale=50000（縮小側上限）, maxScale=1000（拡大側下限）
      final ml = parseMapLayer(
        '''
        <renderer-v2 type="RuleRenderer">
          <rules>
            <rule symbol="0" scalemindenom="2000" scalemaxdenom="25000" label="中縮尺"/>
          </rules>
          <symbols>
            <symbol type="marker" name="0" alpha="1">
              <layer class="SimpleMarker" enabled="1">
                <Option type="Map">
                  <Option type="QString" name="color" value="0,150,255,255"/>
                  <Option type="QString" name="size" value="8"/>
                  <Option type="QString" name="size_unit" value="Pixel"/>
                </Option>
              </layer>
            </symbol>
          </symbols>
        </renderer-v2>
        ''',
        attrs: 'hasScaleBasedVisibilityFlag="1" minScale="50000" maxScale="1000"',
      );

      final style = QgsStyleReader.readStyleWithLabel(ml)!;
      expect(style.minScale, 50000);
      expect(style.maxScale, 1000);
      final ruleClass = style.qgisRendererDef!.classes.single;
      // <rule> の scalemindenom=2000（拡大側）/ scalemaxdenom=25000（縮小側）
      expect(ruleClass.scaleMinDenom, 2000);
      expect(ruleClass.scaleMaxDenom, 25000);

      final tfLayer = TerrainFeatureStyle(
        lineColor: Colors.blue,
        lineWidth: 3,
        fillColor: Colors.green,
        outlineColor: Colors.green,
        outlineWidth: 2,
        pointColor: Colors.red,
        pointSize: 6,
        minScale: style.minScale,
        maxScale: style.maxScale,
      );
      expect(tfLayer.isScaleVisible(10000), isTrue);
      expect(tfLayer.isScaleVisible(500), isFalse);
      expect(tfLayer.isScaleVisible(100000), isFalse);
    });

    test('nullSymbol は地物本体を描画せずラベルのみ生成し、invertedPolygon / pointCluster を読み取る', () {
      final nullMl = parseMapLayer(
        '''
        <renderer-v2 type="nullSymbol"/>
        <labeling type="rule-based">
          <rules>
            <rule description="林班">
              <settings calloutType="simple">
                <text-style fieldName="rinpan" isExpression="0" fontSize="12" fontSizeUnit="Point" textColor="20,20,20,255">
                  <text-buffer bufferDraw="0" bufferSize="1" bufferColor="255,255,255,255"/>
                  <background shapeDraw="1" shapeType="3" shapeFillColor="255,255,240,255" shapeBorderColor="30,30,30,255" shapeBorderWidth="0.4" shapeBorderWidthUnit="MM"/>
                </text-style>
                <text-format wrapChar="/"/>
              </settings>
            </rule>
          </rules>
        </labeling>
        ''',
        attrs: 'labelsEnabled="1"',
      );

      final nullStyle = QgsStyleReader.readStyleWithLabel(nullMl)!;
      expect(nullStyle.qgisRenderer, 'nullSymbol');
      expect(nullStyle.symbolLayers?.nullSymbol, isTrue);
      expect(nullStyle.labelEnabled, isTrue);
      expect(nullStyle.labelProperty, '"rinpan"');
      expect(nullStyle.labelHaloEnabled, isFalse);
      expect(nullStyle.labelBgEnabled, isTrue);
      expect(nullStyle.labelBgShape, 'circle');
      expect(nullStyle.labelWrapChar, '/');

      // TerrainSceneBuilder で点は 0 個、ラベルだけ改行分割されて 1 個出る
      final mesh = buildFlatMesh();
      const ptFeature = geo.Feature(
        geometry: geo.Point(geo.Geographic(lon: 135.96, lat: 33.93)),
        properties: {'__style': 's', '__label': '12/イ'},
      );
      final scene = TerrainSceneBuilder(
        mesh: mesh,
        styleKeyProp: '__style',
        labelProp: '__label',
        stylesByKey: {
          's': const TerrainFeatureStyle(
            lineColor: Colors.blue,
            lineWidth: 3,
            fillColor: Colors.green,
            outlineColor: Colors.green,
            outlineWidth: 2,
            pointColor: Colors.red,
            pointSize: 6,
            nullSymbol: true,
            labelHaloEnabled: false,
            labelWrapChar: '/',
            labelBgShape: 'circle',
            labelBgColor: Color(0xFFFFFFF0),
          ),
        },
      ).build(points: [ptFeature]);

      expect(scene.points, isEmpty);
      expect(scene.labels, hasLength(1));
      expect(scene.labels.single.text, '12\nイ');
      expect(scene.labels.single.haloEnabled, isFalse);
      expect(scene.labels.single.bgShape, 'circle');

      // invertedPolygonRenderer & pointCluster
      final invMl = parseMapLayer('''
        <renderer-v2 type="invertedPolygonRenderer">
          <renderer-v2 type="singleSymbol">
            <symbols>
              <symbol type="fill" name="0" alpha="0.6">
                <layer class="SimpleFill" enabled="1">
                  <Option type="Map">
                    <Option type="QString" name="color" value="255,255,255,255"/>
                    <Option type="QString" name="style" value="solid"/>
                  </Option>
                </layer>
              </symbol>
            </symbols>
          </renderer-v2>
        </renderer-v2>
      ''');
      final invStyle = QgsStyleReader.readStyleWithLabel(invMl)!;
      expect(invStyle.qgisRenderer, 'invertedPolygonRenderer');
      expect(invStyle.symbolLayers?.invertedPolygon, isTrue);

      final clusterMl = parseMapLayer('''
        <renderer-v2 type="pointCluster">
          <renderer-v2 type="categorizedSymbol" attr="kind">
            <categories>
              <category value="A" symbol="0" label="A種" render="true"/>
            </categories>
            <symbols>
              <symbol type="marker" name="0" alpha="1">
                <layer class="SimpleMarker" enabled="1">
                  <Option type="Map">
                    <Option type="QString" name="color" value="200,50,50,255"/>
                    <Option type="QString" name="size" value="6"/>
                    <Option type="QString" name="size_unit" value="Pixel"/>
                  </Option>
                </layer>
              </symbol>
            </symbols>
          </renderer-v2>
        </renderer-v2>
      ''');
      final clusterStyle = QgsStyleReader.readStyleWithLabel(clusterMl)!;
      expect(clusterStyle.qgisRenderer, 'pointCluster');
      expect(clusterStyle.qgisRendererDef!.classes.single.label, 'A種');
    });

    test('データ定義プロパティ（size / angle / color の属性式）を読み取る', () {
      final ml = parseMapLayer('''
        <renderer-v2 type="singleSymbol">
          <symbols>
            <symbol type="marker" name="0" alpha="1">
              <layer class="SimpleMarker" enabled="1">
                <Option type="Map">
                  <Option type="QString" name="color" value="100,100,100,255"/>
                  <Option type="QString" name="size" value="6"/>
                  <Option type="QString" name="size_unit" value="Pixel"/>
                </Option>
                <data_defined_properties>
                  <Option type="Map">
                    <Option type="QString" name="name" value=""/>
                    <Option type="Map" name="properties">
                      <Option type="Map" name="size">
                        <Option type="bool" name="active" value="true"/>
                        <Option type="QString" name="expression" value="&quot;dbh&quot; * 0.5"/>
                        <Option type="int" name="type" value="3"/>
                      </Option>
                      <Option type="Map" name="angle">
                        <Option type="bool" name="active" value="true"/>
                        <Option type="QString" name="field" value="azimuth"/>
                        <Option type="int" name="type" value="2"/>
                      </Option>
                    </Option>
                    <Option type="QString" name="type" value="collection"/>
                  </Option>
                </data_defined_properties>
              </layer>
            </symbol>
          </symbols>
        </renderer-v2>
      ''');

      final style = QgsStyleReader.readStyleWithLabel(ml)!;
      expect(style.dataDefined, isNotNull);
      expect(style.dataDefined!['pointSize'], '"dbh" * 0.5');
      expect(style.dataDefined!['pointAngle'], '"azimuth"');
    });
  });

  group('.qgs 書き出し・往復・DOM保持と .qgz / GeoPackage 埋め込みスタイル救済', () {
    late Directory tmp;
    late String proj;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      KMetaService.instance.clearCache();
      tmp = await Directory.systemTemp.createTemp('qgis_compat_');
      proj = (await Directory(p.join(tmp.path, 'ForestProj')).create()).path;
      ProjectPathResolver.instance.setRootPathGetter(() => proj);
    });

    tearDown(() async {
      KMetaService.instance.clearCache();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    Future<FolderNode> openTree() async {
      final root = FolderNode('Home', children: []);
      Future<void> load(LayerTreeNode n) async {
        await n.updateChildren();
        for (final c in n.children) {
          if (c is FolderNode || c is GeoPackageNode || c is LayerNode) await load(c);
        }
      }

      await load(root);
      return root;
    }

    Future<void> closeTree(LayerTreeNode n) async {
      if (n is GeoPackageNode) await n.geoPackageFile.dispose();
      for (final c in n.children) {
        await closeTree(c);
      }
    }

    test('QgsWriter が書いた縁取り線・斜線ハッチング面・星形マーカーを QgsStyleReader で往復復元できる', () {
      const project = QgsProject(
        name: 'RoundTrip',
        root: [
          QgsLayer(
            id: 'l_roads',
            name: '林道',
            dataSourcePath: './data.gpkg',
            tableName: 'roads',
            geometryType: GeometryType.linestring,
            crs: QgsCrs.wgs84,
            style: QgsStyle(
              lineColor: Color(0xFFD84315),
              lineWidthPx: 4.0,
              lineDash: 'dash',
              lineCasingEnabled: true,
              lineCasingColor: Color(0xFFFFFFFF),
              lineCasingWidthPx: 2.0,
            ),
          ),
          QgsLayer(
            id: 'l_stands',
            name: '小班',
            dataSourcePath: './data.gpkg',
            tableName: 'stands',
            geometryType: GeometryType.polygon,
            crs: QgsCrs.wgs84,
            style: QgsStyle(
              fillColor: Color(0xFF2E7D32),
              fillOpacity: 0.8,
              fillPattern: 'slash',
              patternSpacingPx: 10.0,
              patternLineWidthPx: 1.5,
              strokeColor: Color(0xFF1B5E20),
              strokeWidthPx: 2.0,
              strokeDash: 'dash_dot',
              strokeCasingEnabled: true,
              strokeCasingColor: Color(0xFFFFFFFF),
              strokeCasingWidthPx: 1.5,
            ),
          ),
          QgsLayer(
            id: 'l_dots',
            name: '保安林',
            dataSourcePath: './data.gpkg',
            tableName: 'stands',
            geometryType: GeometryType.polygon,
            crs: QgsCrs.wgs84,
            style: QgsStyle(
              fillColor: Color(0xFF1565C0),
              fillPattern: 'dots',
              patternSpacingPx: 8.0,
              strokeColor: Color(0xFF0D47A1),
              strokeWidthPx: 1.5,
            ),
          ),
          QgsLayer(
            id: 'l_pts',
            name: '調査木',
            dataSourcePath: './data.gpkg',
            tableName: 'trees',
            geometryType: GeometryType.point,
            crs: QgsCrs.wgs84,
            style: QgsStyle(
              pointColor: Color(0xFFF9A825),
              pointSizePx: 7.0,
              pointShape: 'star',
              pointOutlineEnabled: true,
              pointOutlineColor: Color(0xFF212121),
              pointOutlineWidthPx: 1.5,
              pointAngleDeg: 15.0,
            ),
          ),
        ],
      );

      final xml = const QgsWriter().build(project);
      final keepDir = Platform.environment['KOKAGE_KEEP_QGS'];
      if (keepDir != null && keepDir.isNotEmpty) {
        Directory(keepDir).createSync(recursive: true);
        File(p.join(keepDir, 'kokage_styles.qgs')).writeAsStringSync(xml);
      }
      final doc = XmlDocument.parse(xml);
      final maplayers = {
        for (final ml in doc.findAllElements('maplayer')) ml.getElement('id')!.innerText: ml,
      };

      final roadStyle = QgsStyleReader.readStyleWithLabel(maplayers['l_roads']!)!;
      expect(roadStyle.lineCasingEnabled, isTrue);
      expect(roadStyle.lineColor, const Color(0xFFD84315));
      expect(roadStyle.lineCasingColor, const Color(0xFFFFFFFF));
      expect(roadStyle.lineWidth, closeTo(4.0, 0.05));
      expect(roadStyle.lineCasingWidth, closeTo(2.0, 0.05));
      expect(roadStyle.lineDash, 'dash');

      final standStyle = QgsStyleReader.readStyleWithLabel(maplayers['l_stands']!)!;
      expect(standStyle.polygonFillPattern, 'slash');
      expect(standStyle.polygonPatternSpacing, closeTo(10.0, 0.1));
      expect(standStyle.polygonBorderDash, 'dash_dot');
      expect(standStyle.polygonBorderCasingEnabled, isTrue);

      final dotStyle = QgsStyleReader.readStyleWithLabel(maplayers['l_dots']!)!;
      expect(dotStyle.polygonFillPattern, 'dots');

      final ptStyle = QgsStyleReader.readStyleWithLabel(maplayers['l_pts']!)!;
      expect(ptStyle.pointShape, 'star');
      expect(ptStyle.pointSize, closeTo(7.0, 0.05));
      expect(ptStyle.pointOutlineEnabled, isTrue);
      expect(ptStyle.pointAngle, closeTo(15.0, 0.05));
    });

    test('QgsDocument.apply は preserveExistingSymbol=true のとき QGIS 側の複合シンボルを壊さない', () {
      const baseProject = QgsProject(
        name: 'DomPreserve',
        root: [
          QgsLayer(
            id: 'l_poly',
            name: '区画',
            dataSourcePath: './a.gpkg',
            tableName: 'parcels',
            geometryType: GeometryType.polygon,
            crs: QgsCrs.wgs84,
            style: QgsStyle(fillColor: Color(0xFF4CAF50)),
          ),
        ],
      );
      final initialXml = const QgsWriter().build(baseProject);
      // QGIS 側で下地ベタ塗り + ハッチングの 2 層に編集された状態を作る
      final editedXml = initialXml.replaceFirst(
        RegExp(r'<symbol [^>]*type="fill"[^>]*>[\s\S]*?</symbol>'),
        '''<symbol alpha="1" name="0" type="fill">
          <layer class="SimpleFill" enabled="1"><Option type="Map"><Option name="color" type="QString" value="200,230,200,255"/></Option></layer>
          <layer class="LinePatternFill" enabled="1"><Option type="Map"><Option name="angle" type="QString" value="45"/></Option></layer>
        </symbol>''',
      );

      final qgsDoc = QgsDocument.parse(editedXml);
      qgsDoc.apply(
        const QgsProject(
          name: 'DomPreserve',
          root: [
            QgsLayer(
              id: 'l_poly',
              name: '区画',
              dataSourcePath: './a.gpkg',
              tableName: 'parcels',
              geometryType: GeometryType.polygon,
              crs: QgsCrs.wgs84,
              style: QgsStyle(preserveExistingSymbol: true),
            ),
          ],
        ),
      );
      final outXml = qgsDoc.toXmlString();
      expect(outXml, contains('class="LinePatternFill"'));
      expect(outXml, contains('200,230,200,255'));
    });

    test('.qgz（QGIS 既定の ZIP 形式）から .qgs を自動展開し、元 .qgz を .qgz.bak に退避してスタイルを読む', () async {
      final gpkgPath = p.join(proj, 'stands.gpkg');
      await ForeignGeomGpkg.geopandas.write(gpkgPath);
      final gpkgShaBefore = sha256.convert(File(gpkgPath).readAsBytesSync()).toString();

      const foreignQgsXml = '''<!DOCTYPE qgis PUBLIC 'http://mrcc.com/qgis.dtd' 'SYSTEM'>
<qgis version="3.34.0-Prizren" projectname="QgzSample">
  <layer-tree-group>
    <layer-tree-layer id="parcels_1" name="parcels" checked="Qt::Checked" providerKey="ogr" source="./stands.gpkg|layername=parcels"/>
  </layer-tree-group>
  <projectlayers>
    <maplayer type="vector" geometry="Point" hasScaleBasedVisibilityFlag="1" minScale="25000" maxScale="500">
      <id>parcels_1</id>
      <datasource>./stands.gpkg|layername=parcels</datasource>
      <layername>parcels</layername>
      <provider encoding="UTF-8">ogr</provider>
      <renderer-v2 type="singleSymbol">
        <symbols>
          <symbol type="marker" name="0" alpha="1">
            <layer class="SimpleMarker" enabled="1">
              <Option type="Map">
                <Option type="QString" name="name" value="diamond"/>
                <Option type="QString" name="color" value="255,60,0,255"/>
                <Option type="QString" name="size" value="10"/>
                <Option type="QString" name="size_unit" value="Pixel"/>
              </Option>
            </layer>
          </symbol>
        </symbols>
      </renderer-v2>
    </maplayer>
  </projectlayers>
</qgis>''';

      final archive = Archive()..addFile(ArchiveFile.string('my_qgis_work.qgs', foreignQgsXml));
      final zipped = ZipEncoder().encode(archive);
      final qgzPath = p.join(proj, 'my_qgis_work.qgz');
      File(qgzPath).writeAsBytesSync(zipped);

      final root = await openTree();
      final report = await const QgsReadBack().run(root);
      await closeTree(root);

      expect(report, isNotNull);
      expect(File(p.join(proj, 'ForestProj.qgs')).existsSync(), isTrue);
      expect(File('$qgzPath.bak').existsSync(), isTrue);
      expect(File(qgzPath).existsSync(), isFalse);
      // GeoPackage は 1 バイトも書き換えていないこと
      expect(sha256.convert(File(gpkgPath).readAsBytesSync()).toString(), gpkgShaBefore);

      final meta = await QgsMetaStore.read(proj);
      final layerStyle = meta!.styles.layers['stands.gpkg/parcels']!;
      expect(layerStyle.pointShape, 'diamond');
      expect(layerStyle.pointColor, const Color(0xFFFF3C00));
      expect(layerStyle.minScale, 25000);
      expect(layerStyle.maxScale, 500);
    });

    test('GeoPackage 内 layer_styles と qgis_projects（16進ZIP）を読み取り専用で救済し gpkg を 1 バイトも変えない', () async {
      final gpkgPath = p.join(proj, 'embedded.gpkg');
      await ForeignGeomGpkg.arcgis.write(gpkgPath);

      // GPKG 内に QGIS 標準の layer_styles と qgis_projects（16進 ZIP）を用意する
      const qmlXml = '''<!DOCTYPE qgis PUBLIC 'http://mrcc.com/qgis.dtd' 'SYSTEM'>
<qgis version="3.34.0-Prizren" styleCategories="AllStyleCategories">
  <renderer-v2 type="singleSymbol">
    <symbols>
      <symbol type="marker" name="0" alpha="1">
        <layer class="SimpleMarker" enabled="1">
          <Option type="Map">
            <Option type="QString" name="name" value="triangle"/>
            <Option type="QString" name="color" value="20,160,80,255"/>
            <Option type="QString" name="size" value="12"/>
            <Option type="QString" name="size_unit" value="Pixel"/>
          </Option>
        </layer>
      </symbol>
    </symbols>
  </renderer-v2>
</qgis>''';

      const embeddedQgs = '''<!DOCTYPE qgis PUBLIC 'http://mrcc.com/qgis.dtd' 'SYSTEM'>
<qgis version="3.34.0-Prizren" projectname="InGpkg">
  <projectlayers/>
</qgis>''';
      final qgzBytes = ZipEncoder().encode(Archive()..addFile(ArchiveFile.string('in_gpkg.qgs', embeddedQgs)));
      final hexZip = qgzBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      final setupDb = await openDatabase(gpkgPath, singleInstance: false);
      await setupDb.execute(
        'CREATE TABLE layer_styles (id INTEGER PRIMARY KEY, f_table_name TEXT, styleQML TEXT, useAsDefault BOOLEAN)',
      );
      await setupDb.rawInsert(
        'INSERT INTO layer_styles (f_table_name, styleQML, useAsDefault) VALUES (?, ?, 1)',
        ['Stands', qmlXml],
      );
      await setupDb.execute('CREATE TABLE qgis_projects (name TEXT PRIMARY KEY, metadata BLOB, content BLOB)');
      await setupDb.rawInsert('INSERT INTO qgis_projects (name, content) VALUES (?, ?)', ['default', hexZip]);
      await setupDb.close();

      // 準備完了時点の SHA-256 を記録
      final shaBefore = sha256.convert(File(gpkgPath).readAsBytesSync()).toString();

      final root = await openTree();
      final extractedXml = await QgsEmbeddedStyleLoader.readEmbeddedProjectXml(root);
      expect(extractedXml, contains('projectname="InGpkg"'));

      final applied = await QgsEmbeddedStyleLoader.applyFallbackLayerStyles(root);
      expect(applied, 1);
      await closeTree(root);

      // 見ただけの GeoPackage は 1 バイトたりとも変わっていないこと
      final shaAfter = sha256.convert(File(gpkgPath).readAsBytesSync()).toString();
      expect(shaAfter, shaBefore);

      final meta = await KMetaService.instance.getMeta(proj);
      final st = meta.styles.layers['embedded.gpkg/Stands']!;
      expect(st.pointShape, 'triangle');
      expect(st.pointColor, const Color(0xFF14A050));
      expect(st.pointSize, closeTo(6.0, 1e-4));
    });

    test('LayerNode.refreshStyleGroups はデータ定義式（size / angle / color）を地物ごとに評価する', () async {
      final gpkgPath = p.join(proj, 'trees.gpkg');
      const gpkgSpec = ForeignGeomGpkg(
        'trees',
        table: 'trees',
        geomColumn: 'geom',
        pk: 'fid',
        extraColumns: {'dbh': 'REAL', 'sp_color': 'TEXT'},
      );
      await gpkgSpec.write(gpkgPath);
      final db = await openDatabase(gpkgPath, singleInstance: false);
      await db.execute("UPDATE trees SET dbh = 20, sp_color = '#FF0000' WHERE name = 'a'");
      await db.execute("UPDATE trees SET dbh = 40, sp_color = '#0000FF' WHERE name = 'b'");
      await db.close();

      await KMetaService.instance.setLayerStyle(
        proj,
        'trees.gpkg/trees',
        const KMetaLayerStyle(
          pointSize: 5,
          dataDefined: {
            'pointSize': '"dbh" * 0.25',
            'pointColor': '"sp_color"',
          },
        ),
      );

      final root = await openTree();
      final layer = root.children
          .whereType<GeoPackageNode>()
          .single
          .children
          .whereType<LayerNode>()
          .single;
      await layer.refreshStyleGroups();

      final groups = layer.styleGroups;
      // QGIS の SimpleMarker size 式は直径 mm を返すため px 半径へ換算（5mm→9.5px, 10mm→19.0px）
      expect(groups.values.map((s) => s.pointSize), containsAll([5.0, 9.5, 19.0]));
      expect(
        groups.values.map((s) => s.pointColor),
        containsAll([const Color(0xFFFF0000), const Color(0xFF0000FF)]),
      );
      await closeTree(root);
    });
  });
}

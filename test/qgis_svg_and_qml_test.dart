import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/terrain/dem_grid.dart';
import 'package:root_maps/core/terrain/fill_pattern_painter.dart';
import 'package:root_maps/core/terrain/gpu/gpu_geometry.dart';
import 'package:root_maps/core/terrain/svg_marker_atlas.dart';
import 'package:root_maps/core/terrain/terrain_camera.dart';
import 'package:root_maps/core/terrain/terrain_mesh.dart';
import 'package:root_maps/core/terrain/terrain_scene.dart';
import 'package:root_maps/core/terrain/terrain_world_painter.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/models/qgis_renderer.dart';
import 'package:root_maps/services/qgis/qgs_qml_service.dart';
import 'package:root_maps/services/qgis/qgs_renderer_reader.dart';
import 'package:root_maps/services/qgis/qgs_style_reader.dart';
import 'package:xml/xml.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(SvgMarkerCache.instance.clear);

  group('SvgMarker parameter substitution & base64 helpers', () {
    test('encodes and decodes base64: SVG strings', () {
      const raw = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"/></svg>';
      final encoded = encodeBase64QgisSvg(raw);
      expect(encoded, startsWith('base64:'));
      expect(decodeBase64QgisSvg(encoded), raw);
      expect(decodeBase64QgisSvg('gpsicons/tree.svg'), isNull);
    });

    test('replaces QGIS param(fill), param(outline), opacities and viewBox-scaled stroke width', () {
      const qgisTemplate = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 580 580">
  <path fill="param(fill) #000000" fill-opacity="param(fill-opacity) 1"
        stroke="param(outline) #ffffff" stroke-opacity="param(outline-opacity) 1"
        stroke-width="param(outline-width) 0" d="M290 40 L520 500 L60 500 Z"/>
</svg>''';

      final resolved = applyQgisSvgParams(
        qgisTemplate,
        fillColor: const Color(0xFF2E7D32),
        fillOpacity: 0.8,
        outlineColor: const Color(0xFFFAFAFA),
        outlineOpacity: 1.0,
        outlineWidthPx: 2.0,
        diameterPx: 20.0,
      );

      expect(resolved, isNot(contains('param(')));
      expect(resolved.toLowerCase(), contains('#2e7d32'));
      expect(resolved.toLowerCase(), contains('#fafafa'));
      // (2.0 / 20.0) * 580 = 58
      expect(resolved, contains('stroke-width="58"'));
      expect(resolved, contains('fill-opacity="0.8"'));
    });
  });

  group('QgsSymbolReader & QgsStyleReader SvgMarker support', () {
    test('reads embedded base64: SvgMarker with parameterized fill and angle', () {
      const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
          '<circle cx="12" cy="12" r="9" fill="param(fill)" stroke="param(outline)" stroke-width="param(outline-width)"/>'
          '</svg>';
      final b64 = encodeBase64QgisSvg(svg);
      final sym = XmlDocument.parse('''
<symbol type="marker" name="0" alpha="1">
  <layer class="SvgMarker" enabled="1" pass="0">
    <Option type="Map">
      <Option name="name" type="QString" value="$b64"/>
      <Option name="color" type="QString" value="220,38,38,255"/>
      <Option name="outline_color" type="QString" value="255,255,255,255"/>
      <Option name="outline_width" type="QString" value="0.6"/>
      <Option name="outline_width_unit" type="QString" value="MM"/>
      <Option name="size" type="QString" value="6"/>
      <Option name="size_unit" type="QString" value="MM"/>
      <Option name="angle" type="QString" value="45"/>
    </Option>
  </layer>
</symbol>''').rootElement;

      final style = QgsSymbolReader.read(sym);
      expect(style, isNotNull);
      expect(style!.pointColor, const Color(0xFFDC2626));
      expect(style.pointAngle, 45.0);
      final marker = style.symbolLayers?.markers.single;
      expect(marker, isNotNull);
      expect(marker!.svgPath, b64);
      expect(marker.svgContent, isNotNull);
      expect(marker.svgContent!.toLowerCase(), contains('#dc2626'));
    });

    test('resolves project-local SVG files inside rootDir and ignores outside-root paths', () async {
      final tmpRoot = await Directory.systemTemp.createTemp('kokage_svg_test_');
      final outsideDir = await Directory.systemTemp.createTemp('kokage_svg_outside_');
      try {
        final iconsDir = Directory(p.join(tmpRoot.path, 'icons'));
        await iconsDir.create(recursive: true);
        final localSvgFile = File(p.join(iconsDir.path, 'dam.svg'));
        await localSvgFile.writeAsString(
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
          '<rect x="3" y="6" width="18" height="12" fill="param(fill)"/></svg>',
        );
        final outsideSvgFile = File(p.join(outsideDir.path, 'secret.svg'));
        await outsideSvgFile.writeAsString(
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><rect width="24" height="24"/></svg>',
        );

        final doc = XmlDocument.parse('''
<qgis>
  <symbol type="marker" name="local">
    <layer class="SvgMarker" enabled="1">
      <Option type="Map">
        <Option name="name" type="QString" value="./icons/dam.svg"/>
        <Option name="color" type="QString" value="30,136,229,255"/>
        <Option name="size" type="QString" value="5"/>
      </Option>
    </layer>
  </symbol>
  <symbol type="marker" name="outside">
    <layer class="SvgMarker" enabled="1">
      <Option type="Map">
        <Option name="name" type="QString" value="${outsideSvgFile.path.replaceAll(r'\', '/')}"/>
      </Option>
    </layer>
  </symbol>
</qgis>''');

        final preloaded = await QgsStyleReader.preloadLocalSvgFiles(
          doc,
          baseDir: tmpRoot.path,
          rootDir: tmpRoot.path,
        );
        expect(preloaded.containsKey('./icons/dam.svg'), isTrue);
        expect(preloaded.length, 1);

        final localSym = doc.rootElement.findElements('symbol').first;
        final style = QgsSymbolReader.read(localSym, svgFileReader: (k) => preloaded[k]);
        expect(style?.symbolLayers?.markers.single.svgContent, contains('<rect'));
        expect(style?.symbolLayers?.markers.single.svgContent?.toLowerCase(), contains('#1e88e5'));
      } finally {
        await tmpRoot.delete(recursive: true);
        await outsideDir.delete(recursive: true);
      }
    });

    test('maps QGIS standard SVG paths and PointPatternFill SvgMarker sub-symbols', () {
      final polySym = XmlDocument.parse('''
<symbol type="fill" name="0" alpha="1">
  <layer class="PointPatternFill" enabled="1">
    <Option type="Map">
      <Option name="distance_x" type="QString" value="6"/>
      <Option name="distance_y" type="QString" value="6"/>
    </Option>
    <symbol type="marker" name="@0@0" alpha="1">
      <layer class="SvgMarker" enabled="1">
        <Option type="Map">
          <Option name="name" type="QString" value="gpsicons/tree.svg"/>
          <Option name="color" type="QString" value="46,125,50,255"/>
          <Option name="size" type="QString" value="4"/>
        </Option>
      </layer>
    </symbol>
  </layer>
</symbol>''').rootElement;

      final style = QgsSymbolReader.read(polySym);
      expect(style, isNotNull);
      final fill = style!.symbolLayers?.fills.single;
      expect(fill, isNotNull);
      expect(fill!.kind, FillLayerKind.pointPattern);
      expect(fill.pointSvgContent, isNotNull);
      expect(fill.pointSvgContent!.toLowerCase(), contains('#2e7d32'));
    });
  });

  group('SvgMarkerCache sprite atlas, GpuPointGeometry filter & 3D drawAtlas', () {
    test('packs multiple SVGs into one 512x512 atlas and renders via TerrainWorldPainter', () async {
      final svgA = applyQgisSvgParams(
        QgisStandardSvgLibrary.resolve('gpsicons/tree.svg')!,
        fillColor: const Color(0xFF2E7D32),
        fillOpacity: 1.0,
        outlineColor: Colors.white,
        outlineOpacity: 1.0,
        outlineWidthPx: 1.5,
        diameterPx: 16,
      );
      final svgB = applyQgisSvgParams(
        QgisStandardSvgLibrary.resolve('arrows/Arrow_01.svg')!,
        fillColor: const Color(0xFFD32F2F),
        fillOpacity: 1.0,
        outlineColor: Colors.white,
        outlineOpacity: 1.0,
        outlineWidthPx: 1.5,
        diameterPx: 16,
      );

      final revBefore = SvgMarkerCache.instance.revision.value;
      await Future.wait([
        SvgMarkerCache.instance.ensureLoaded(svgA),
        SvgMarkerCache.instance.ensureLoaded(svgB),
      ]);
      final slotA = SvgMarkerCache.instance.slotFor(svgA);
      final slotB = SvgMarkerCache.instance.slotFor(svgB);

      expect(slotA, isNotNull);
      expect(slotB, isNotNull);
      expect(SvgMarkerCache.instance.pageCount, 1);
      expect(SvgMarkerCache.instance.spriteCount, 2);
      expect(SvgMarkerCache.instance.revision.value, greaterThan(revBefore));
      expect(slotA!.atlas.width, 512);
      expect(slotA.atlas.height, 512);
      expect(identical(slotA.atlas, slotB!.atlas), isTrue);
      expect(slotA.srcRect, const Rect.fromLTWH(2, 2, 60, 60));
      expect(slotB.srcRect, const Rect.fromLTWH(66, 2, 60, 60));

      final points = <TerrainPoint>[
        TerrainPoint(
          x: 40,
          y: 50,
          color: const Color(0xFF2E7D32),
          sizePx: 10,
          svgContent: svgA,
        ),
        TerrainPoint(
          x: 60,
          y: 50,
          color: const Color(0xFFD32F2F),
          sizePx: 10,
          angleDeg: 90,
          svgContent: svgB,
        ),
        const TerrainPoint(
          x: 50,
          y: 70,
          color: Color(0xFF1976D2),
          sizePx: 8,
          shape: PointMarkerShape.star,
        ),
      ];

      // GPU SDF パッカーは SvgMarker 点を除外し、通常の SDF 点（1 件）だけを詰める
      final packed = GpuPointGeometry.pack(points, elevationAt: (_, _) => 0);
      expect(packed.pointCount, 1);

      // FillPatternCache でも SVG PointPatternFill シェーダが生成される
      final patternLayer = ResolvedFillLayer.pointPattern(
        color: const Color(0xFF2E7D32),
        dxPx: 12,
        dyPx: 12,
        pointRadiusPx: 5,
        pointSvgContent: svgA,
      );
      expect(FillPatternCache.instance.shaderFor(patternLayer), isNotNull);

      // TerrainWorldPainter で 3D ビルボード（drawAtlas）描画を実行しピクセル出力を確認
      final grid = DemGrid(
        cols: 4,
        rows: 4,
        originX: 0,
        originY: 0,
        cellSize: 40,
        heights: Float32List(16),
      );
      final mesh = TerrainMeshBuilder(
        grid,
        textureWidth: 256,
        textureHeight: 256,
      ).build(TerrainCamera(centerX: 50, centerY: 50, scale: 1));
      final tile = TerrainTileDrawable(
        originX: 0,
        originY: 0,
        mesh: mesh,
        texture: null,
        points: points,
      );
      expect(tile.hasSvgPoints, isTrue);

      final camera = TerrainCamera(
        centerX: 50,
        centerY: 50,
        scale: 2.0,
        pitch: 0,
        bearing: 0,
      );
      final painter = TerrainWorldPainter(
        camera: camera,
        tiles: [tile],
        elevationAt: (_, _) => 0,
        heightRange: (0, 100),
        stepMeters: 10,
      );

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      painter.paint(canvas, const Size(200, 200));
      final pic = recorder.endRecording();
      final img = await pic.toImage(200, 200);
      final byteData = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      pic.dispose();
      img.dispose();

      expect(byteData, isNotNull);
      final rgba = byteData!.buffer.asUint8List();
      // (x=40, y=50) は中心 (50,50) から左に 10m * scale 2.0 = 20px → 画面 X=80, Y=100 付近に不透明ピクセルが描かれる
      var nonZeroAroundTree = 0;
      for (var dy = -6; dy <= 6; dy++) {
        for (var dx = -6; dx <= 6; dx++) {
          final px = 80 + dx;
          final py = 100 + dy;
          final idx = (py * 200 + px) * 4;
          if (rgba[idx + 3] > 0) nonZeroAroundTree++;
        }
      }
      expect(nonZeroAroundTree, greaterThan(10));
    });
  });

  group('QgsQmlService export & import round-trip', () {
    test('round-trips SvgMarker point style with rich label and scale limits', () {
      const rawSvg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
          '<path d="M12 2 L22 20 L2 20 Z" fill="param(fill)"/></svg>';
      final b64 = encodeBase64QgisSvg(rawSvg);
      final resolvedSvg = applyQgisSvgParams(
        rawSvg,
        fillColor: const Color(0xFFE65100),
        fillOpacity: 1.0,
        outlineColor: Colors.white,
        outlineOpacity: 1.0,
        outlineWidthPx: 1.5,
        diameterPx: 16,
      );

      final original = KMetaLayerStyle(
        pointColor: const Color(0xFFE65100),
        pointSize: 8.0,
        pointAngle: 30.0,
        minScale: 50000,
        maxScale: 1000,
        labelEnabled: true,
        labelProperty: '"name"',
        labelFontSize: 14.0,
        labelColor: const Color(0xFF111111),
        labelWrapChar: '|',
        labelBgEnabled: true,
        labelBgShape: 'roundRect',
        labelBgColor: const Color(0xEEFFFFFF),
        symbolLayers: ResolvedSymbolLayers(
          markers: [
            ResolvedPointLayer(
              color: const Color(0xFFE65100),
              radiusPx: 8.0,
              angleDeg: 30.0,
              svgContent: resolvedSvg,
              svgPath: b64,
            ),
          ],
        ),
      );

      final qml = QgsQmlService.exportQml(
        style: original,
        geometryType: GeometryType.point,
      );
      expect(qml, contains('<!DOCTYPE qgis'));
      expect(qml, contains('class="SvgMarker"'));
      expect(qml, contains('<layerGeometryType>0</layerGeometryType>'));

      final res = QgsQmlService.importQml(
        qml,
        expectedGeometryType: GeometryType.point,
      );
      expect(res, isA<QmlImportSuccess>());
      final imported = (res as QmlImportSuccess).style;
      expect(imported.pointColor, const Color(0xFFE65100));
      expect(imported.pointSize, closeTo(8.0, 0.2));
      expect(imported.pointAngle, 30.0);
      expect(imported.minScale, 50000);
      expect(imported.maxScale, 1000);
      expect(imported.labelEnabled, isTrue);
      expect(imported.labelWrapChar, '|');
      expect(imported.labelBgEnabled, isTrue);
      expect(imported.labelBgShape, 'roundRect');
      expect(imported.symbolLayers?.markers.single.svgPath, b64);
      expect(imported.symbolLayers?.markers.single.svgContent?.toLowerCase(), contains('#e65100'));
    });

    test('round-trips line casing, polygon hatching, categorized renderer and checks geometry mismatch', () {
      const lineStyle = KMetaLayerStyle(
        lineColor: Color(0xFFD84315),
        lineWidth: 3.0,
        lineDash: 'dash_dot',
        lineCasingEnabled: true,
        lineCasingColor: Color(0xFFFFFFFF),
        lineCasingWidth: 2.0,
      );
      final lineQml = QgsQmlService.exportQml(
        style: lineStyle,
        geometryType: GeometryType.linestring,
      );
      expect(lineQml, contains('symbollevels="1"'));

      // 線用の QML を面レイヤに読み込もうとすると型不一致を返す
      final mismatch = QgsQmlService.importQml(
        lineQml,
        expectedGeometryType: GeometryType.polygon,
      );
      expect(mismatch, isA<QmlImportGeometryMismatch>());

      final lineImported = (QgsQmlService.importQml(
        lineQml,
        expectedGeometryType: GeometryType.linestring,
      ) as QmlImportSuccess)
          .style;
      expect(lineImported.lineCasingEnabled, isTrue);
      expect(lineImported.lineDash, 'dash_dot');
      expect(lineImported.lineCasingWidth, closeTo(2.0, 0.2));

      // 分類レンダラ（categorizedSymbol）の QML 書き出し・再読み込み
      final catStyle = KMetaLayerStyle(
        qgisRenderer: 'categorizedSymbol',
        qgisRendererDef: QgisRenderer(
          kind: QgisRendererKind.categorized,
          attr: '樹種',
          classes: [
            const QgisRendererClass(
              label: 'スギ',
              values: ['スギ'],
              style: KMetaLayerStyle(
                polygonFillColor: Color(0xFF2E7D32),
                polygonFillPattern: 'slash',
                polygonBorderColor: Color(0xFF1B5E20),
                polygonBorderWidth: 1.5,
              ),
            ),
            const QgisRendererClass(
              label: 'ヒノキ',
              values: ['ヒノキ'],
              style: KMetaLayerStyle(
                polygonFillColor: Color(0xFF66BB6A),
                polygonBorderColor: Color(0xFF2E7D32),
                polygonBorderWidth: 1.5,
              ),
            ),
          ],
        ),
      );
      final catQml = QgsQmlService.exportQml(
        style: catStyle,
        geometryType: GeometryType.polygon,
      );
      final catRes = QgsQmlService.importQml(
        catQml,
        expectedGeometryType: GeometryType.polygon,
      );
      expect(catRes, isA<QmlImportSuccess>());
      final catImported = (catRes as QmlImportSuccess).style;
      expect(catImported.qgisRenderer, 'categorizedSymbol');
      expect(catImported.qgisRendererDef?.attr, '樹種');
      expect(catImported.qgisRendererDef?.classes.length, 2);
      expect(catImported.qgisRendererDef?.classes.first.style?.polygonFillPattern, 'slash');

      final verifyDir = Platform.environment['KOKAGE_QML_VERIFY_DIR'];
      if (verifyDir != null && verifyDir.isNotEmpty) {
        File(p.join(verifyDir, 'kokage_line_casing.qml')).writeAsStringSync(lineQml);
        File(p.join(verifyDir, 'kokage_poly_cat.qml')).writeAsStringSync(catQml);
        final fromQgisFile = File(p.join(verifyDir, 'from_qgis422.qml'));
        if (fromQgisFile.existsSync()) {
          final qgisRes = QgsQmlService.importQml(
            fromQgisFile.readAsStringSync(),
            expectedGeometryType: GeometryType.point,
          );
          expect(qgisRes, isA<QmlImportSuccess>());
          final qgisStyle = (qgisRes as QmlImportSuccess).style;
          expect(qgisStyle.pointColor, const Color(0xFF1B5E20));
          expect(qgisStyle.pointAngle, 15.0);
          expect(qgisStyle.minScale, 25000);
          expect(qgisStyle.maxScale, 500);
          expect(qgisStyle.symbolLayers?.markers.single.svgContent?.toLowerCase(), contains('#1b5e20'));
          final reExportedPt = QgsQmlService.exportQml(
            style: qgisStyle.copyWith(
              labelEnabled: true,
              labelProperty: '"name"',
              labelFontSize: 13.0,
            ),
            geometryType: GeometryType.point,
          );
          File(p.join(verifyDir, 'kokage_point_svg.qml')).writeAsStringSync(reExportedPt);
        }
      }
    });
  });
}

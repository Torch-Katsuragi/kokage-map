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
// こかげマップ: QGIS `SvgMarker` のパラメータ置換・標準 SVG ライブラリ・512×512 スプライトアトラス

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_svg/flutter_svg.dart';

/// `base64:...` 形式の QGIS 埋め込み SVG 文字列を復号する（該当しなければ null）
String? decodeBase64QgisSvg(String? rawName) {
  if (rawName == null) return null;
  final trimmed = rawName.trim();
  if (!trimmed.startsWith('base64:')) return null;
  final payload = trimmed.substring('base64:'.length).replaceAll(RegExp(r'\s+'), '');
  if (payload.isEmpty) return null;
  try {
    return utf8.decode(base64.decode(payload), allowMalformed: true);
  } on Object {
    return null;
  }
}

/// SVG XML 文字列を QGIS の `base64:...` 形式へエンコードする
String encodeBase64QgisSvg(String svgXml) => 'base64:${base64.encode(utf8.encode(svgXml))}';

/// QGIS の動的パラメータ付き SVG（`param(fill)` / `param(outline)` / `param(outline-width)` 等）に
/// 実際の塗り色・枠線色・不透明度・viewBox スケール換算した線幅を適用する。
String applyQgisSvgParams(
  String rawSvg, {
  required Color fillColor,
  required double fillOpacity,
  required Color outlineColor,
  required double outlineOpacity,
  required double outlineWidthPx,
  required double diameterPx,
}) {
  final viewBoxSpan = _extractSvgViewBoxSpan(rawSvg);
  final effDiameter = math.max(diameterPx, 4.0);
  final svgStrokeW = outlineWidthPx <= 0 ? 0.0 : (outlineWidthPx / effDiameter) * viewBoxSpan;

  final fillHex = _rgbHex(fillColor);
  final outlineHex = _rgbHex(outlineColor);
  final fillOpStr = _fmtNum(fillOpacity.clamp(0.0, 1.0));
  final outOpStr = _fmtNum((outlineWidthPx <= 0 ? 0.0 : outlineOpacity).clamp(0.0, 1.0));
  final strokeWStr = _fmtNum(svgStrokeW);

  var out = rawSvg;
  out = out.replaceAll(_reParamFillOpacity, fillOpStr);
  out = out.replaceAll(_reParamOutlineOpacity, outOpStr);
  out = out.replaceAll(_reParamOutlineWidth, strokeWStr);
  out = out.replaceAll(_reParamFill, fillHex);
  out = out.replaceAll(_reParamOutline, outlineHex);
  return out;
}

final RegExp _reParamFill = RegExp(
  r'param\(\s*fill\s*\)(?:[\t ]+(?:#[0-9a-fA-F]{3,8}|rgba?\([^)]*\)|[a-zA-Z]+))?',
);
final RegExp _reParamOutline = RegExp(
  r'param\(\s*outline\s*\)(?:[\t ]+(?:#[0-9a-fA-F]{3,8}|rgba?\([^)]*\)|[a-zA-Z]+))?',
);
final RegExp _reParamFillOpacity = RegExp(
  r'param\(\s*fill-opacity\s*\)(?:[\t ]+[0-9.]+)?',
);
final RegExp _reParamOutlineOpacity = RegExp(
  r'param\(\s*outline-opacity\s*\)(?:[\t ]+[0-9.]+)?',
);
final RegExp _reParamOutlineWidth = RegExp(
  r'param\(\s*outline-width\s*\)(?:[\t ]+[0-9.]+)?',
);
final RegExp _reViewBox = RegExp(
  r'''viewBox\s*=\s*["']\s*[-+0-9.eE]+[\s,]+[-+0-9.eE]+[\s,]+([0-9.eE+-]+)[\s,]+([0-9.eE+-]+)\s*["']''',
);
final RegExp _reWidthAttr = RegExp(r'''\bwidth\s*=\s*["']\s*([0-9.]+)''');

double _extractSvgViewBoxSpan(String svg) {
  final m = _reViewBox.firstMatch(svg);
  if (m != null) {
    final w = double.tryParse(m.group(1) ?? '');
    final h = double.tryParse(m.group(2) ?? '');
    if (w != null && h != null && w > 0 && h > 0) {
      return math.max(w, h);
    }
  }
  final wm = _reWidthAttr.firstMatch(svg);
  if (wm != null) {
    final w = double.tryParse(wm.group(1) ?? '');
    if (w != null && w > 0) return w;
  }
  return 24.0;
}

String _rgbHex(Color c) {
  final rgb = c.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

String _fmtNum(double v) {
  final s = v.toStringAsFixed(3);
  if (!s.contains('.')) return s;
  return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

/// QGIS 標準同梱の SVG パス（`gpsicons/tree.svg`・`arrows/Arrow_01.svg`・`emergency/...` 等）に対応する
/// 軽量な内蔵ベクタシンボルテンプレート集。
///
/// 外部で作成された QGIS プロジェクトが PC 上の QGIS 標準 SVG を参照していても、
/// スマホや Web でアイコン欠損にならず `param(fill)` / `param(outline)` 付きで描画できる。
abstract final class QgisStandardSvgLibrary {
  static String _wrap(String inner) =>
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
      '<g fill="param(fill)" fill-opacity="param(fill-opacity)" '
      'stroke="param(outline)" stroke-opacity="param(outline-opacity)" '
      'stroke-width="param(outline-width)" stroke-linejoin="round" stroke-linecap="round">'
      '$inner'
      '</g></svg>';

  static final String _tree = _wrap(
    '<path d="M12 2 L5 11 H9 L4 18 H10 V22 H14 V18 H20 L15 11 H19 Z"/>',
  );
  static final String _deciduous = _wrap(
    '<path d="M10.5 16 H13.5 V22 H10.5 Z"/>'
    '<circle cx="12" cy="9.5" r="6.8"/>',
  );
  static final String _arrow = _wrap(
    '<path d="M12 2 L20 12 H15 V22 H9 V12 H4 Z"/>',
  );
  static final String _northArrow = _wrap(
    '<path d="M12 2 L19 21 L12 16.5 L5 21 Z"/>',
  );
  static final String _pin = _wrap(
    '<path d="M12 2 C7.8 2 4.5 5.3 4.5 9.5 C4.5 14.8 12 22 12 22 C12 22 19.5 14.8 19.5 9.5 C19.5 5.3 16.2 2 12 2 Z"/>'
    '<circle cx="12" cy="9.5" r="2.6" fill="param(outline)"/>',
  );
  static final String _flag = _wrap(
    '<path d="M6 2 V22 M6 3 H19 L16 8 L19 13 H6 Z"/>',
  );
  static final String _peak = _wrap(
    '<path d="M12 3 L22 20 H2 Z"/>',
  );
  static final String _warning = _wrap(
    '<path d="M12 2.5 L22 20.5 H2 Z"/>'
    '<path d="M12 9 V14.5 M12 17.5 V18" stroke="param(outline)" stroke-width="2.2"/>',
  );
  static final String _crossMedical = _wrap(
    '<path d="M9 3 H15 V9 H21 V15 H15 V21 H9 V15 H3 V9 H9 Z"/>',
  );
  static final String _house = _wrap(
    '<path d="M12 3 L3 11 H6 V21 H18 V11 H21 Z"/>',
  );
  static final String _tent = _wrap(
    '<path d="M12 3 L2 20 H22 Z M12 11 L8.5 20 H15.5 Z"/>',
  );
  static final String _camera = _wrap(
    '<rect x="3" y="7" width="18" height="13" rx="2"/>'
    '<path d="M8 7 L9.5 4.5 H14.5 L16 7 Z"/>'
    '<circle cx="12" cy="13.5" r="3.5"/>',
  );
  static final String _car = _wrap(
    '<path d="M5 12 L7 6.5 H17 L19 12 H21 V17.5 H19 V19.5 H16.5 V17.5 H7.5 V19.5 H5 V17.5 H3 V12 Z"/>',
  );
  static final String _parking = _wrap(
    '<rect x="3" y="3" width="18" height="18" rx="3"/>'
    '<path d="M9.5 17 V7 H13.8 C15.6 7 16.8 8.1 16.8 9.8 C16.8 11.5 15.6 12.6 13.8 12.6 H9.5" fill="none" stroke="param(outline)" stroke-width="2.2"/>',
  );
  static final String _tower = _wrap(
    '<path d="M12 2 L16.5 21 H13.5 L12.7 16 H11.3 L10.5 21 H7.5 Z M9 12 H15"/>',
  );
  static final String _water = _wrap(
    '<path d="M12 2.5 C12 2.5 5.5 10.2 5.5 15 C5.5 18.6 8.4 21.5 12 21.5 C15.6 21.5 18.5 18.6 18.5 15 C18.5 10.2 12 2.5 12 2.5 Z"/>',
  );
  static final String _bridge = _wrap(
    '<path d="M2 9 H22 V13 H19 C17.5 13 16 14.5 16 17 H8 C8 14.5 6.5 13 5 13 H2 Z"/>',
  );
  static final String _star = _wrap(
    '<path d="M12 2.2 L14.9 8.4 L21.7 9.3 L16.7 14.0 L18.0 20.8 L12 17.5 L6.0 20.8 L7.3 14.0 L2.3 9.3 L9.1 8.4 Z"/>',
  );
  static final String _fire = _wrap(
    '<path d="M12.5 2.5 C13.5 6.5 18.5 8.5 18.5 14 C18.5 18.2 15.5 21.5 12 21.5 C8.5 21.5 5.5 18.2 5.5 14 C5.5 10.5 8 8 9.5 6.5 C9.2 8.8 10.5 9.8 11.5 10.2 C10.8 7.5 11.3 4.8 12.5 2.5 Z"/>',
  );
  static final String _anchor = _wrap(
    '<circle cx="12" cy="5.5" r="2.2"/>'
    '<path d="M12 7.8 V20.5 M8.5 11 H15.5 M5 14.5 C5 18.5 8.2 21 12 21 C15.8 21 19 18.5 19 14.5"/>',
  );
  static final String _info = _wrap(
    '<circle cx="12" cy="12" r="9.5"/>'
    '<path d="M12 11 V16.5 M12 7.5 V8" stroke="param(outline)" stroke-width="2.3"/>',
  );

  /// QGIS の `name`（例: `gpsicons/tree.svg`、`arrows/Arrow_01.svg`）から標準 SVG を引く
  static String? resolve(String? rawPath) {
    if (rawPath == null || rawPath.isEmpty) return null;
    final norm = rawPath.replaceAll(r'\', '/').trim().toLowerCase();
    final slash = norm.lastIndexOf('/');
    final file = slash >= 0 ? norm.substring(slash + 1) : norm;
    final dir = slash >= 0 ? norm.substring(0, slash) : '';
    final stem = file.endsWith('.svg') ? file.substring(0, file.length - 4) : file;

    bool hasAny(Iterable<String> keys) => keys.any((k) => stem.contains(k) || dir.contains(k));

    if (hasAny(const ['deciduous', 'broadleaf', 'orchard'])) return _deciduous;
    if (hasAny(const ['tree', 'conifer', 'forest', 'wood', 'pine', 'park'])) return _tree;
    if (hasAny(const ['north', 'compass'])) return _northArrow;
    if (hasAny(const ['arrow', 'wind', 'direction'])) return _arrow;
    if (hasAny(const ['flag', 'golf', 'finish'])) return _flag;
    if (hasAny(const ['warning', 'danger', 'hazard', 'caution', 'exclamation', 'skull'])) return _warning;
    if (hasAny(const ['fire', 'flame', 'volcano_active'])) return _fire;
    if (hasAny(const ['hospital', 'medical', 'clinic', 'doctor', 'pharmacy', 'cross', 'health', 'emergency'])) {
      return _crossMedical;
    }
    if (hasAny(const ['tent', 'camp', 'caravan'])) return _tent;
    if (hasAny(const ['house', 'home', 'building', 'hut', 'shelter', 'accommodation', 'hotel', 'cabin'])) {
      return _house;
    }
    if (hasAny(const ['camera', 'photo', 'viewpoint'])) return _camera;
    if (hasAny(const ['parking'])) return _parking;
    if (hasAny(const ['car', 'vehicle', 'taxi', 'bus', 'truck', 'transport'])) return _car;
    if (hasAny(const ['tower', 'antenna', 'radio', 'power', 'lighthouse', 'windmill'])) return _tower;
    if (hasAny(const ['bridge', 'viaduct', 'dam', 'gate'])) return _bridge;
    if (hasAny(const ['anchor', 'harbor', 'harbour', 'port', 'marina', 'ferry', 'boat'])) return _anchor;
    if (hasAny(const ['water', 'spring', 'fountain', 'droplet', 'well', 'hydrant', 'waterfall'])) return _water;
    if (hasAny(const ['peak', 'mountain', 'summit', 'triangle', 'trig', 'benchmark', 'volcano'])) return _peak;
    if (hasAny(const ['star', 'landmark', 'monument', 'castle', 'shrine', 'temple'])) return _star;
    if (hasAny(const ['info', 'question', 'help'])) return _info;
    if (hasAny(const ['pin', 'marker', 'waypoint', 'location', 'gps', 'poi', 'symbol', 'tourist', 'amenity', 'shopping'])) {
      return _pin;
    }
    if (norm.endsWith('.svg')) {
      // パス解決できなかった未知の .svg 指定でもピン形状のベクタマーカーとして欠損なく表示する
      return _pin;
    }
    return null;
  }
}

/// スプライトアトラス内の 1 スロット（`Canvas.drawAtlas` の引数そのまま使える）
class SvgAtlasSlot {
  const SvgAtlasSlot({
    required this.atlas,
    required this.srcRect,
  });

  final ui.Image atlas;
  final ui.Rect srcRect;
}

class _AtlasPage {
  final List<ui.Image> cellImages = <ui.Image>[];
  final List<String> keys = <String>[];
  ui.Image? atlasImage;
  bool dirty = false;
}

/// `SvgMarker` の SVG XML をラスタライズし、512×512 `ui.Image` のスプライトアトラスへ
/// パックして保持するシングルトンキャッシュ。
///
/// - 1 セル 64×64 px（内側 60×60 px ＋ 周囲 2 px の透明ガターでバイリニア滲みを防止）
/// - 1 ページあたり 8×8 = 64 個のシンボルを格納し、3D 地図面では `Canvas.drawAtlas` 1 発でバッチ描画する
/// - 非同期デコード完了時に [revision] を更新し、地図面・プレビュー・凡例の再描画を促す
class SvgMarkerCache {
  SvgMarkerCache._();

  static final SvgMarkerCache instance = SvgMarkerCache._();

  static const int kAtlasSize = 512;
  static const int kCellSize = 64;
  static const double kCellPad = 2.0;
  static const double kSpriteSize = kCellSize - kCellPad * 2; // 60.0
  static const int kCols = kAtlasSize ~/ kCellSize; // 8
  static const int kCellsPerPage = kCols * kCols; // 64
  static const int _maxSprites = 256;

  /// 新しい SVG がアトラスに入ったときにインクリメントされる通知カウンタ
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  final Map<String, SvgAtlasSlot> _slots = <String, SvgAtlasSlot>{};
  final Map<String, Future<SvgAtlasSlot?>> _inflight = <String, Future<SvgAtlasSlot?>>{};
  final Set<String> _failed = <String>{};
  final List<_AtlasPage> _pages = <_AtlasPage>[];
  bool _rebuildScheduled = false;
  Completer<void>? _rebuildCompleter;

  /// 現在のアトラスページ数（テスト・診断用）
  int get pageCount => _pages.length;

  /// 現在登録済みのスプライト数（テスト・診断用）
  int get spriteCount => _slots.length;

  /// 同期参照。既にアトラスにあれば [SvgAtlasSlot] を返し、未デコードなら裏でラスタライズを開始して null を返す
  SvgAtlasSlot? slotFor(String svgXml) {
    final hit = _slots[svgXml];
    if (hit != null) return hit;
    if (_failed.contains(svgXml)) return null;
    unawaited(ensureLoaded(svgXml));
    return null;
  }

  /// [svgXml] のラスタライズとアトラスページ構築の完了を待って [SvgAtlasSlot] を返す
  Future<SvgAtlasSlot?> ensureLoaded(String svgXml) {
    final hit = _slots[svgXml];
    if (hit != null) return Future<SvgAtlasSlot?>.value(hit);
    if (_failed.contains(svgXml)) return Future<SvgAtlasSlot?>.value(null);
    return _inflight.putIfAbsent(svgXml, () => _loadAndPack(svgXml));
  }

  Future<SvgAtlasSlot?> _loadAndPack(String svgXml) async {
    try {
      if (_slots.length >= _maxSprites) {
        clear();
      }
      final info = await vg.loadPicture(SvgStringLoader(svgXml), null);
      final srcW = info.size.width > 0 ? info.size.width : 24.0;
      final srcH = info.size.height > 0 ? info.size.height : 24.0;
      final scale = math.min(kSpriteSize / srcW, kSpriteSize / srcH);
      final dx = kCellPad + (kSpriteSize - srcW * scale) * 0.5;
      final dy = kCellPad + (kSpriteSize - srcH * scale) * 0.5;

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.translate(dx, dy);
      canvas.scale(scale, scale);
      canvas.drawPicture(info.picture);
      info.picture.dispose();

      final cellPicture = recorder.endRecording();
      final cellImage = await cellPicture.toImage(kCellSize, kCellSize);
      cellPicture.dispose();

      _AtlasPage page;
      if (_pages.isEmpty || _pages.last.cellImages.length >= kCellsPerPage) {
        page = _AtlasPage();
        _pages.add(page);
      } else {
        page = _pages.last;
      }
      page.cellImages.add(cellImage);
      page.keys.add(svgXml);
      page.dirty = true;

      await _schedulePageRebuild();
      return _slots[svgXml];
    } on Object {
      _failed.add(svgXml);
      return null;
    } finally {
      final _ = _inflight.remove(svgXml);
    }
  }

  Future<void> _schedulePageRebuild() {
    final existing = _rebuildCompleter;
    if (_rebuildScheduled && existing != null) return existing.future;
    _rebuildScheduled = true;
    final completer = Completer<void>();
    _rebuildCompleter = completer;

    scheduleMicrotask(() async {
      _rebuildScheduled = false;
      try {
        var updated = false;
        for (final page in _pages) {
          if (!page.dirty) continue;
          page.dirty = false;
          final recorder = ui.PictureRecorder();
          final canvas = ui.Canvas(recorder);
          final paint = ui.Paint();
          for (var i = 0; i < page.cellImages.length; i++) {
            final col = i % kCols;
            final row = i ~/ kCols;
            canvas.drawImage(
              page.cellImages[i],
              ui.Offset((col * kCellSize).toDouble(), (row * kCellSize).toDouble()),
              paint,
            );
          }
          final pic = recorder.endRecording();
          final atlas = await pic.toImage(kAtlasSize, kAtlasSize);
          pic.dispose();
          page.atlasImage = atlas;
          for (var i = 0; i < page.keys.length; i++) {
            final col = i % kCols;
            final row = i ~/ kCols;
            _slots[page.keys[i]] = SvgAtlasSlot(
              atlas: atlas,
              srcRect: ui.Rect.fromLTWH(
                col * kCellSize + kCellPad,
                row * kCellSize + kCellPad,
                kSpriteSize,
                kSpriteSize,
              ),
            );
          }
          updated = true;
        }
        if (updated) {
          revision.value++;
        }
        completer.complete();
      } on Object catch (e, st) {
        completer.completeError(e, st);
      }
    });

    return completer.future;
  }

  /// キャッシュを解放する（メモリ逼迫時や単体テスト用）
  void clear() {
    _slots.clear();
    _failed.clear();
    for (final page in _pages) {
      for (final img in page.cellImages) {
        img.dispose();
      }
      page.atlasImage?.dispose();
    }
    _pages.clear();
  }
}

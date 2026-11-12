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
// こかげマップ: フォルダ設定のレイヤスタイル定義（個別スタイル・フォルダ内スタイル一覧）

import 'package:flutter/material.dart';

import '../qgis_renderer.dart';
import '../qgis_symbol.dart';

export '../qgis_symbol.dart';

/// レイヤースタイル設定（個別レイヤー用）
class KMetaLayerStyle {
  final double? pointSize;
  final Color? pointColor;
  final double? pointOpacity;
  final String? pointShape;
  final bool? pointOutlineEnabled;
  final Color? pointOutlineColor;
  final double? pointOutlineWidth;
  final double? pointAngle;

  final double? lineWidth;
  final Color? lineColor;
  final double? lineOpacity;
  final String? lineDash;
  final bool? lineCasingEnabled;
  final Color? lineCasingColor;
  final double? lineCasingWidth;

  final double? polygonBorderWidth;
  final Color? polygonBorderColor;
  final Color? polygonFillColor;
  final double? polygonFillOpacity;
  final double? polygonBorderOpacity;
  final String? polygonFillPattern;
  final double? polygonPatternSpacing;
  final double? polygonPatternLineWidth;
  final String? polygonBorderDash;
  final bool? polygonBorderCasingEnabled;
  final Color? polygonBorderCasingColor;
  final double? polygonBorderCasingWidth;

  final bool? labelEnabled;
  final String? labelProperty;
  final double? labelFontSize;
  final Color? labelColor;
  final Color? labelHaloColor;
  final double? labelOpacity;
  final bool? labelHaloEnabled;
  final double? labelHaloSize;
  final String? labelWrapChar;
  final bool? labelBgEnabled;
  final String? labelBgShape;
  final Color? labelBgColor;
  final Color? labelBgBorderColor;
  final double? labelBgBorderWidth;

  /// 縮尺依存表示（QGIS の分母規則: `minScale` = 最縮小側の分母・例 100000、`maxScale` = 最拡大側の分母・例 1000）
  final double? minScale;
  final double? maxScale;

  /// QGIS 由来のマルチレイヤシンボル構造や反転ポリゴン・nullSymbol の完全保持用
  final ResolvedSymbolLayers? symbolLayers;

  /// QGIS のデータ定義プロパティ式（キー: `'pointSize'`, `'pointAngle'`, `'lineWidth'`, `'color'` 等 → QGIS 式文字列）
  final Map<String, String>? dataDefined;

  /// QGIS 側で単一シンボル以外（`categorizedSymbol` / `graduatedSymbol` / `RuleRenderer` …）に
  /// 設定されているときの種類。null なら単一シンボル（アプリで色や太さを編集できる）。
  ///
  /// 地物ごとの色は [qgisRendererDef] から決め（読めなければ代表の色）、`.qgs` のレンダラは触らない（不変条件4）。
  /// スタイル画面はこのとき色・太さを編集させない（変えても QGIS に届かず、見た目が食い違うため）
  final String? qgisRenderer;

  /// [qgisRenderer] の中身（分類の項目・段階の範囲・ルールとそれぞれのシンボル）。地物ごとの色はここから決める。
  /// `.qgs` のレンダラを読んだ写しで、QGIS で保存し直されるたびに読み戻しが差し替える
  final QgisRenderer? qgisRendererDef;

  const KMetaLayerStyle({
    this.pointSize,
    this.pointColor,
    this.pointOpacity,
    this.pointShape,
    this.pointOutlineEnabled,
    this.pointOutlineColor,
    this.pointOutlineWidth,
    this.pointAngle,
    this.lineWidth,
    this.lineColor,
    this.lineOpacity,
    this.lineDash,
    this.lineCasingEnabled,
    this.lineCasingColor,
    this.lineCasingWidth,
    this.polygonBorderWidth,
    this.polygonBorderColor,
    this.polygonFillColor,
    this.polygonFillOpacity,
    this.polygonBorderOpacity,
    this.polygonFillPattern,
    this.polygonPatternSpacing,
    this.polygonPatternLineWidth,
    this.polygonBorderDash,
    this.polygonBorderCasingEnabled,
    this.polygonBorderCasingColor,
    this.polygonBorderCasingWidth,
    this.labelEnabled,
    this.labelProperty,
    this.labelFontSize,
    this.labelColor,
    this.labelHaloColor,
    this.labelOpacity,
    this.labelHaloEnabled,
    this.labelHaloSize,
    this.labelWrapChar,
    this.labelBgEnabled,
    this.labelBgShape,
    this.labelBgColor,
    this.labelBgBorderColor,
    this.labelBgBorderWidth,
    this.minScale,
    this.maxScale,
    this.symbolLayers,
    this.dataDefined,
    this.qgisRenderer,
    this.qgisRendererDef,
  });

  KMetaLayerStyle copyWith({
    double? pointSize,
    Color? pointColor,
    double? pointOpacity,
    String? pointShape,
    bool? pointOutlineEnabled,
    Color? pointOutlineColor,
    double? pointOutlineWidth,
    double? pointAngle,
    double? lineWidth,
    Color? lineColor,
    double? lineOpacity,
    String? lineDash,
    bool? lineCasingEnabled,
    Color? lineCasingColor,
    double? lineCasingWidth,
    double? polygonBorderWidth,
    Color? polygonBorderColor,
    Color? polygonFillColor,
    double? polygonFillOpacity,
    double? polygonBorderOpacity,
    String? polygonFillPattern,
    double? polygonPatternSpacing,
    double? polygonPatternLineWidth,
    String? polygonBorderDash,
    bool? polygonBorderCasingEnabled,
    Color? polygonBorderCasingColor,
    double? polygonBorderCasingWidth,
    bool? labelEnabled,
    String? labelProperty,
    double? labelFontSize,
    Color? labelColor,
    Color? labelHaloColor,
    double? labelOpacity,
    bool? labelHaloEnabled,
    double? labelHaloSize,
    String? labelWrapChar,
    bool? labelBgEnabled,
    String? labelBgShape,
    Color? labelBgColor,
    Color? labelBgBorderColor,
    double? labelBgBorderWidth,
    double? minScale,
    double? maxScale,
    ResolvedSymbolLayers? symbolLayers,
    bool clearSymbolLayers = false,
    Map<String, String>? dataDefined,
    String? qgisRenderer,
    QgisRenderer? qgisRendererDef,
  }) =>
      KMetaLayerStyle(
        pointSize: pointSize ?? this.pointSize,
        pointColor: pointColor ?? this.pointColor,
        pointOpacity: pointOpacity ?? this.pointOpacity,
        pointShape: pointShape ?? this.pointShape,
        pointOutlineEnabled: pointOutlineEnabled ?? this.pointOutlineEnabled,
        pointOutlineColor: pointOutlineColor ?? this.pointOutlineColor,
        pointOutlineWidth: pointOutlineWidth ?? this.pointOutlineWidth,
        pointAngle: pointAngle ?? this.pointAngle,
        lineWidth: lineWidth ?? this.lineWidth,
        lineColor: lineColor ?? this.lineColor,
        lineOpacity: lineOpacity ?? this.lineOpacity,
        lineDash: lineDash ?? this.lineDash,
        lineCasingEnabled: lineCasingEnabled ?? this.lineCasingEnabled,
        lineCasingColor: lineCasingColor ?? this.lineCasingColor,
        lineCasingWidth: lineCasingWidth ?? this.lineCasingWidth,
        polygonBorderWidth: polygonBorderWidth ?? this.polygonBorderWidth,
        polygonBorderColor: polygonBorderColor ?? this.polygonBorderColor,
        polygonFillColor: polygonFillColor ?? this.polygonFillColor,
        polygonFillOpacity: polygonFillOpacity ?? this.polygonFillOpacity,
        polygonBorderOpacity: polygonBorderOpacity ?? this.polygonBorderOpacity,
        polygonFillPattern: polygonFillPattern ?? this.polygonFillPattern,
        polygonPatternSpacing: polygonPatternSpacing ?? this.polygonPatternSpacing,
        polygonPatternLineWidth: polygonPatternLineWidth ?? this.polygonPatternLineWidth,
        polygonBorderDash: polygonBorderDash ?? this.polygonBorderDash,
        polygonBorderCasingEnabled: polygonBorderCasingEnabled ?? this.polygonBorderCasingEnabled,
        polygonBorderCasingColor: polygonBorderCasingColor ?? this.polygonBorderCasingColor,
        polygonBorderCasingWidth: polygonBorderCasingWidth ?? this.polygonBorderCasingWidth,
        labelEnabled: labelEnabled ?? this.labelEnabled,
        labelProperty: labelProperty ?? this.labelProperty,
        labelFontSize: labelFontSize ?? this.labelFontSize,
        labelColor: labelColor ?? this.labelColor,
        labelHaloColor: labelHaloColor ?? this.labelHaloColor,
        labelOpacity: labelOpacity ?? this.labelOpacity,
        labelHaloEnabled: labelHaloEnabled ?? this.labelHaloEnabled,
        labelHaloSize: labelHaloSize ?? this.labelHaloSize,
        labelWrapChar: labelWrapChar ?? this.labelWrapChar,
        labelBgEnabled: labelBgEnabled ?? this.labelBgEnabled,
        labelBgShape: labelBgShape ?? this.labelBgShape,
        labelBgColor: labelBgColor ?? this.labelBgColor,
        labelBgBorderColor: labelBgBorderColor ?? this.labelBgBorderColor,
        labelBgBorderWidth: labelBgBorderWidth ?? this.labelBgBorderWidth,
        minScale: minScale ?? this.minScale,
        maxScale: maxScale ?? this.maxScale,
        symbolLayers: clearSymbolLayers ? null : (symbolLayers ?? this.symbolLayers),
        dataDefined: dataDefined ?? this.dataDefined,
        qgisRenderer: qgisRenderer ?? this.qgisRenderer,
        qgisRendererDef: qgisRendererDef ?? this.qgisRendererDef,
      );

  /// JSONからパース
  factory KMetaLayerStyle.fromJson(Map<String, dynamic> json) {
    final ddRaw = json['dataDefined'];
    Map<String, String>? dataDefined;
    if (ddRaw is Map) {
      final m = <String, String>{
        for (final e in ddRaw.entries)
          if (e.key is String && e.value is String && (e.value as String).isNotEmpty)
            e.key as String: e.value as String,
      };
      if (m.isNotEmpty) dataDefined = m;
    }
    return KMetaLayerStyle(
      pointSize: (json['pointSize'] as num?)?.toDouble(),
      pointColor: _parseColor(json['pointColor']),
      pointOpacity: (json['pointOpacity'] as num?)?.toDouble(),
      pointShape: json['pointShape'] as String?,
      pointOutlineEnabled: json['pointOutlineEnabled'] as bool?,
      pointOutlineColor: _parseColor(json['pointOutlineColor']),
      pointOutlineWidth: (json['pointOutlineWidth'] as num?)?.toDouble(),
      pointAngle: (json['pointAngle'] as num?)?.toDouble(),
      lineWidth: (json['lineWidth'] as num?)?.toDouble(),
      lineColor: _parseColor(json['lineColor']),
      lineOpacity: (json['lineOpacity'] as num?)?.toDouble(),
      lineDash: json['lineDash'] as String?,
      lineCasingEnabled: json['lineCasingEnabled'] as bool?,
      lineCasingColor: _parseColor(json['lineCasingColor']),
      lineCasingWidth: (json['lineCasingWidth'] as num?)?.toDouble(),
      polygonBorderWidth: (json['polygonBorderWidth'] as num?)?.toDouble(),
      polygonBorderColor: _parseColor(json['polygonBorderColor']),
      polygonFillColor: _parseColor(json['polygonFillColor']),
      polygonFillOpacity: (json['polygonFillOpacity'] as num?)?.toDouble(),
      polygonBorderOpacity: (json['polygonBorderOpacity'] as num?)?.toDouble(),
      polygonFillPattern: json['polygonFillPattern'] as String?,
      polygonPatternSpacing: (json['polygonPatternSpacing'] as num?)?.toDouble(),
      polygonPatternLineWidth: (json['polygonPatternLineWidth'] as num?)?.toDouble(),
      polygonBorderDash: json['polygonBorderDash'] as String?,
      polygonBorderCasingEnabled: json['polygonBorderCasingEnabled'] as bool?,
      polygonBorderCasingColor: _parseColor(json['polygonBorderCasingColor']),
      polygonBorderCasingWidth: (json['polygonBorderCasingWidth'] as num?)?.toDouble(),
      labelEnabled: json['labelEnabled'] as bool?,
      labelProperty: json['labelProperty'] as String?,
      labelFontSize: (json['labelFontSize'] as num?)?.toDouble(),
      labelColor: _parseColor(json['labelColor']),
      labelHaloColor: _parseColor(json['labelHaloColor']),
      labelOpacity: (json['labelOpacity'] as num?)?.toDouble(),
      labelHaloEnabled: json['labelHaloEnabled'] as bool?,
      labelHaloSize: (json['labelHaloSize'] as num?)?.toDouble(),
      labelWrapChar: json['labelWrapChar'] as String?,
      labelBgEnabled: json['labelBgEnabled'] as bool?,
      labelBgShape: json['labelBgShape'] as String?,
      labelBgColor: _parseColor(json['labelBgColor']),
      labelBgBorderColor: _parseColor(json['labelBgBorderColor']),
      labelBgBorderWidth: (json['labelBgBorderWidth'] as num?)?.toDouble(),
      minScale: (json['minScale'] as num?)?.toDouble(),
      maxScale: (json['maxScale'] as num?)?.toDouble(),
      symbolLayers: ResolvedSymbolLayers.tryFromJson(json['symbolLayers']),
      dataDefined: dataDefined,
      qgisRenderer: json['qgisRenderer'] as String?,
      qgisRendererDef: QgisRenderer.tryFromJson(json['qgisRendererDef']),
    );
  }

  /// JSONへシリアライズ（null の項目は書かない）
  Map<String, dynamic> toJson() => {
        if (pointSize != null) 'pointSize': pointSize,
        if (pointColor != null) 'pointColor': _colorToHex(pointColor!),
        if (pointOpacity != null) 'pointOpacity': pointOpacity,
        if (pointShape != null) 'pointShape': pointShape,
        if (pointOutlineEnabled != null) 'pointOutlineEnabled': pointOutlineEnabled,
        if (pointOutlineColor != null) 'pointOutlineColor': _colorToHex(pointOutlineColor!),
        if (pointOutlineWidth != null) 'pointOutlineWidth': pointOutlineWidth,
        if (pointAngle != null) 'pointAngle': pointAngle,
        if (lineWidth != null) 'lineWidth': lineWidth,
        if (lineColor != null) 'lineColor': _colorToHex(lineColor!),
        if (lineOpacity != null) 'lineOpacity': lineOpacity,
        if (lineDash != null) 'lineDash': lineDash,
        if (lineCasingEnabled != null) 'lineCasingEnabled': lineCasingEnabled,
        if (lineCasingColor != null) 'lineCasingColor': _colorToHex(lineCasingColor!),
        if (lineCasingWidth != null) 'lineCasingWidth': lineCasingWidth,
        if (polygonBorderWidth != null) 'polygonBorderWidth': polygonBorderWidth,
        if (polygonBorderColor != null) 'polygonBorderColor': _colorToHex(polygonBorderColor!),
        if (polygonFillColor != null) 'polygonFillColor': _colorToHex(polygonFillColor!),
        if (polygonFillOpacity != null) 'polygonFillOpacity': polygonFillOpacity,
        if (polygonBorderOpacity != null) 'polygonBorderOpacity': polygonBorderOpacity,
        if (polygonFillPattern != null) 'polygonFillPattern': polygonFillPattern,
        if (polygonPatternSpacing != null) 'polygonPatternSpacing': polygonPatternSpacing,
        if (polygonPatternLineWidth != null) 'polygonPatternLineWidth': polygonPatternLineWidth,
        if (polygonBorderDash != null) 'polygonBorderDash': polygonBorderDash,
        if (polygonBorderCasingEnabled != null) 'polygonBorderCasingEnabled': polygonBorderCasingEnabled,
        if (polygonBorderCasingColor != null) 'polygonBorderCasingColor': _colorToHex(polygonBorderCasingColor!),
        if (polygonBorderCasingWidth != null) 'polygonBorderCasingWidth': polygonBorderCasingWidth,
        if (labelEnabled != null) 'labelEnabled': labelEnabled,
        if (labelProperty != null) 'labelProperty': labelProperty,
        if (labelFontSize != null) 'labelFontSize': labelFontSize,
        if (labelColor != null) 'labelColor': _colorToHex(labelColor!),
        if (labelHaloColor != null) 'labelHaloColor': _colorToHex(labelHaloColor!),
        if (labelOpacity != null) 'labelOpacity': labelOpacity,
        if (labelHaloEnabled != null) 'labelHaloEnabled': labelHaloEnabled,
        if (labelHaloSize != null) 'labelHaloSize': labelHaloSize,
        if (labelWrapChar != null) 'labelWrapChar': labelWrapChar,
        if (labelBgEnabled != null) 'labelBgEnabled': labelBgEnabled,
        if (labelBgShape != null) 'labelBgShape': labelBgShape,
        if (labelBgColor != null) 'labelBgColor': _colorToHex(labelBgColor!),
        if (labelBgBorderColor != null) 'labelBgBorderColor': _colorToHex(labelBgBorderColor!),
        if (labelBgBorderWidth != null) 'labelBgBorderWidth': labelBgBorderWidth,
        if (minScale != null) 'minScale': minScale,
        if (maxScale != null) 'maxScale': maxScale,
        if (symbolLayers != null && !symbolLayers!.isEmpty) 'symbolLayers': symbolLayers!.toJson(),
        if (dataDefined != null && dataDefined!.isNotEmpty) 'dataDefined': dataDefined,
        if (qgisRenderer != null) 'qgisRenderer': qgisRenderer,
        if (qgisRendererDef != null) 'qgisRendererDef': qgisRendererDef!.toJson(),
      };

  /// 親スタイルとマージ（子の設定が優先）
  KMetaLayerStyle mergeWith(KMetaLayerStyle? parent) {
    if (parent == null) return this;
    // 子が独自の単一シンボル色・パターンを指定している場合、親の複合 symbolLayers をそのまま被せると
    // 子の変更が消えるため、子が独自のシンボル指定を持たないときだけ親の symbolLayers を引き継ぐ
    final childOverridesSymbol = lineColor != null ||
        lineWidth != null ||
        lineDash != null ||
        lineCasingEnabled != null ||
        polygonFillColor != null ||
        polygonFillPattern != null ||
        polygonBorderColor != null ||
        polygonBorderWidth != null ||
        polygonBorderDash != null ||
        pointColor != null ||
        pointSize != null ||
        pointShape != null ||
        pointOutlineEnabled != null;
    return KMetaLayerStyle(
      pointSize: pointSize ?? parent.pointSize,
      pointColor: pointColor ?? parent.pointColor,
      pointOpacity: pointOpacity ?? parent.pointOpacity,
      pointShape: pointShape ?? parent.pointShape,
      pointOutlineEnabled: pointOutlineEnabled ?? parent.pointOutlineEnabled,
      pointOutlineColor: pointOutlineColor ?? parent.pointOutlineColor,
      pointOutlineWidth: pointOutlineWidth ?? parent.pointOutlineWidth,
      pointAngle: pointAngle ?? parent.pointAngle,
      lineWidth: lineWidth ?? parent.lineWidth,
      lineColor: lineColor ?? parent.lineColor,
      lineOpacity: lineOpacity ?? parent.lineOpacity,
      lineDash: lineDash ?? parent.lineDash,
      lineCasingEnabled: lineCasingEnabled ?? parent.lineCasingEnabled,
      lineCasingColor: lineCasingColor ?? parent.lineCasingColor,
      lineCasingWidth: lineCasingWidth ?? parent.lineCasingWidth,
      polygonBorderWidth: polygonBorderWidth ?? parent.polygonBorderWidth,
      polygonBorderColor: polygonBorderColor ?? parent.polygonBorderColor,
      polygonFillColor: polygonFillColor ?? parent.polygonFillColor,
      polygonFillOpacity: polygonFillOpacity ?? parent.polygonFillOpacity,
      polygonBorderOpacity: polygonBorderOpacity ?? parent.polygonBorderOpacity,
      polygonFillPattern: polygonFillPattern ?? parent.polygonFillPattern,
      polygonPatternSpacing: polygonPatternSpacing ?? parent.polygonPatternSpacing,
      polygonPatternLineWidth: polygonPatternLineWidth ?? parent.polygonPatternLineWidth,
      polygonBorderDash: polygonBorderDash ?? parent.polygonBorderDash,
      polygonBorderCasingEnabled: polygonBorderCasingEnabled ?? parent.polygonBorderCasingEnabled,
      polygonBorderCasingColor: polygonBorderCasingColor ?? parent.polygonBorderCasingColor,
      polygonBorderCasingWidth: polygonBorderCasingWidth ?? parent.polygonBorderCasingWidth,
      labelEnabled: labelEnabled ?? parent.labelEnabled,
      labelProperty: labelProperty ?? parent.labelProperty,
      labelFontSize: labelFontSize ?? parent.labelFontSize,
      labelColor: labelColor ?? parent.labelColor,
      labelHaloColor: labelHaloColor ?? parent.labelHaloColor,
      labelOpacity: labelOpacity ?? parent.labelOpacity,
      labelHaloEnabled: labelHaloEnabled ?? parent.labelHaloEnabled,
      labelHaloSize: labelHaloSize ?? parent.labelHaloSize,
      labelWrapChar: labelWrapChar ?? parent.labelWrapChar,
      labelBgEnabled: labelBgEnabled ?? parent.labelBgEnabled,
      labelBgShape: labelBgShape ?? parent.labelBgShape,
      labelBgColor: labelBgColor ?? parent.labelBgColor,
      labelBgBorderColor: labelBgBorderColor ?? parent.labelBgBorderColor,
      labelBgBorderWidth: labelBgBorderWidth ?? parent.labelBgBorderWidth,
      minScale: minScale ?? parent.minScale,
      maxScale: maxScale ?? parent.maxScale,
      symbolLayers: symbolLayers ?? (childOverridesSymbol ? null : parent.symbolLayers),
      dataDefined: dataDefined ?? parent.dataDefined,
      qgisRenderer: qgisRenderer ?? parent.qgisRenderer,
      // 印と中身は組で持つ（子が印を持つなら子の中身。親の別のレンダラの中身を混ぜない）
      qgisRendererDef: qgisRenderer != null ? qgisRendererDef : parent.qgisRendererDef,
    );
  }

  /// 空かどうか
  bool get isEmpty =>
      pointSize == null &&
      pointColor == null &&
      pointOpacity == null &&
      pointShape == null &&
      pointOutlineEnabled == null &&
      pointOutlineColor == null &&
      pointOutlineWidth == null &&
      pointAngle == null &&
      lineWidth == null &&
      lineColor == null &&
      lineOpacity == null &&
      lineDash == null &&
      lineCasingEnabled == null &&
      lineCasingColor == null &&
      lineCasingWidth == null &&
      polygonBorderWidth == null &&
      polygonBorderColor == null &&
      polygonFillColor == null &&
      polygonFillOpacity == null &&
      polygonBorderOpacity == null &&
      polygonFillPattern == null &&
      polygonPatternSpacing == null &&
      polygonPatternLineWidth == null &&
      polygonBorderDash == null &&
      polygonBorderCasingEnabled == null &&
      polygonBorderCasingColor == null &&
      polygonBorderCasingWidth == null &&
      labelEnabled == null &&
      labelProperty == null &&
      labelFontSize == null &&
      labelColor == null &&
      labelHaloColor == null &&
      labelOpacity == null &&
      labelHaloEnabled == null &&
      labelHaloSize == null &&
      labelWrapChar == null &&
      labelBgEnabled == null &&
      labelBgShape == null &&
      labelBgColor == null &&
      labelBgBorderColor == null &&
      labelBgBorderWidth == null &&
      minScale == null &&
      maxScale == null &&
      (symbolLayers == null || symbolLayers!.isEmpty) &&
      (dataDefined == null || dataDefined!.isEmpty) &&
      qgisRenderer == null &&
      qgisRendererDef == null;

  /// 描き分けの印と中身を外したもの（QGIS で単一シンボルに戻されたとき）
  KMetaLayerStyle withoutQgisRenderer() {
    final json = toJson()
      ..remove('qgisRenderer')
      ..remove('qgisRendererDef');
    return KMetaLayerStyle.fromJson(json);
  }
}

/// スタイル設定（デフォルト＋レイヤー個別）
class KMetaStyles {
  /// デフォルトスタイル
  final KMetaLayerStyle? defaultStyle;

  /// レイヤー名 → スタイル
  final Map<String, KMetaLayerStyle> layers;

  const KMetaStyles({this.defaultStyle, this.layers = const {}});

  /// JSONからパース
  factory KMetaStyles.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const KMetaStyles();
    return KMetaStyles(
      defaultStyle: json['default'] != null
          ? KMetaLayerStyle.fromJson(json['default'] as Map<String, dynamic>)
          : null,
      layers: (json['layers'] as Map<String, dynamic>?)?.map(
                (k, v) => MapEntry(
                  k,
                  KMetaLayerStyle.fromJson(v as Map<String, dynamic>),
                ),
              ) ??
          {},
    );
  }

  /// JSONへシリアライズ
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (defaultStyle != null && !defaultStyle!.isEmpty) {
      json['default'] = defaultStyle!.toJson();
    }
    if (layers.isNotEmpty) {
      json['layers'] = layers.map((k, v) => MapEntry(k, v.toJson()));
    }
    return json;
  }

  /// 空かどうか
  bool get isEmpty => (defaultStyle == null || defaultStyle!.isEmpty) && layers.isEmpty;
}

/// 色文字列（#RRGGBB または #AARRGGBB）をColorに変換
Color? _parseColor(dynamic value) {
  if (value == null) return null;
  if (value is int) return Color(value);
  if (value is String) {
    final hex = value.replaceFirst('#', '');
    if (hex.length == 6) {
      return Color(int.parse('FF$hex', radix: 16));
    } else if (hex.length == 8) {
      return Color(int.parse(hex, radix: 16));
    }
  }
  return null;
}

/// Colorを#AARRGGBB形式の文字列に変換
String _colorToHex(Color color) {
  return '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';
}

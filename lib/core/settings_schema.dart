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
/// 宣言的設定フレームワーク
///
/// 設定項目をSettingDefで宣言するだけで、
/// SharedPreferences永続化・KMetaフォールバック・UI自動生成を提供。
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/kmeta.dart';

// ============================================================
// 設定定義（sealed class）
// ============================================================

/// 設定項目の基底クラス
sealed class SettingDef {
  final String key;
  final String title;
  final String? description;

  const SettingDef({
    required this.key,
    required this.title,
    this.description,
  });
}

/// double値スライダー設定
class DoubleDef extends SettingDef {
  final double defaultValue;
  final double min;
  final double max;
  final int divisions;
  final String Function(double)? formatter;
  final double? Function(KMetaLayerStyle)? kmetaGetter;

  const DoubleDef({
    required super.key,
    required super.title,
    super.description,
    required this.defaultValue,
    required this.min,
    required this.max,
    required this.divisions,
    this.formatter,
    this.kmetaGetter,
  });

  String formatValue(double v) => formatter?.call(v) ?? v.toStringAsFixed(1);
}

/// bool値スイッチ設定
class SwitchDef extends SettingDef {
  final bool defaultValue;
  final IconData? icon;
  final bool? Function(KMetaLayerStyle)? kmetaGetter;

  const SwitchDef({
    required super.key,
    required super.title,
    super.description,
    required this.defaultValue,
    this.icon,
    this.kmetaGetter,
  });
}

/// Color値設定（SharedPreferencesにはARGB32 intで保存）
class ColorDef extends SettingDef {
  final int defaultArgb;
  final Color? Function(KMetaLayerStyle)? kmetaGetter;

  const ColorDef({
    required super.key,
    required super.title,
    super.description,
    required this.defaultArgb,
    this.kmetaGetter,
  });

  Color get defaultColor => Color(defaultArgb);
}

/// int値スライダー設定
class IntDef extends SettingDef {
  final int defaultValue;
  final int min;
  final int max;
  final String Function(int)? formatter;

  const IntDef({
    required super.key,
    required super.title,
    super.description,
    required this.defaultValue,
    required this.min,
    required this.max,
    this.formatter,
  });

  int get divisions => max - min;
  String formatValue(int v) => formatter?.call(v) ?? v.toString();
}

/// String値設定
class StringDef extends SettingDef {
  final String defaultValue;
  final String? Function(KMetaLayerStyle)? kmetaGetter;

  const StringDef({
    required super.key,
    required super.title,
    super.description,
    required this.defaultValue,
    this.kmetaGetter,
  });
}

// ============================================================
// セクション定義
// ============================================================

/// 設定セクションの定義
class SettingSectionDef {
  final String title;
  final IconData? icon;
  final Color? iconColor;
  final String? description;
  final List<SettingDef> items;
  final bool collapsible;
  final bool initiallyExpanded;
  final bool globalOnly;

  const SettingSectionDef({
    required this.title,
    this.icon,
    this.iconColor,
    this.description,
    required this.items,
    this.collapsible = true,
    this.initiallyExpanded = false,
    this.globalOnly = false,
  });
}

// ============================================================
// 汎用ストア
// ============================================================

/// SharedPreferences + KMetaオーバーレイの二層設定ストア
///
/// 値の解決順: overlay(KMeta) > SharedPreferences > defaultValue
class SettingsStore extends ChangeNotifier {
  final List<SettingSectionDef> sections;
  SharedPreferences? _prefs;
  Map<String, dynamic>? _overlay;

  SettingsStore(this.sections);

  /// 全SettingDefのフラットリスト
  Iterable<SettingDef> get allDefs => sections.expand((s) => s.items);

  bool get hasOverlay => _overlay != null;

  // ---------- 読み込み ----------

  Future<void> load() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  // ---------- 値取得（overlay > prefs > default）----------

  double getDouble(DoubleDef def) {
    if (_overlay?.containsKey(def.key) == true) {
      return (_overlay![def.key] as num).toDouble();
    }
    return _prefs?.getDouble(def.key) ?? def.defaultValue;
  }

  bool getBool(SwitchDef def) {
    if (_overlay?.containsKey(def.key) == true) {
      return _overlay![def.key] as bool;
    }
    return _prefs?.getBool(def.key) ?? def.defaultValue;
  }

  Color getColor(ColorDef def) {
    if (_overlay?.containsKey(def.key) == true) {
      final v = _overlay![def.key];
      if (v is Color) return v;
      if (v is int) return Color(v);
    }
    final stored = _prefs?.getInt(def.key);
    return stored != null ? Color(stored) : def.defaultColor;
  }

  int getInt(IntDef def) {
    if (_overlay?.containsKey(def.key) == true) {
      return _overlay![def.key] as int;
    }
    return _prefs?.getInt(def.key) ?? def.defaultValue;
  }

  String getString(StringDef def) {
    if (_overlay?.containsKey(def.key) == true) {
      return _overlay![def.key] as String;
    }
    return _prefs?.getString(def.key) ?? def.defaultValue;
  }

  // ---------- KMetaフォールバック付き値取得（map_page.dart用）----------

  double resolveDouble(DoubleDef def, KMetaLayerStyle? kmeta) {
    if (kmeta != null && def.kmetaGetter != null) {
      final v = def.kmetaGetter!(kmeta);
      if (v != null) return v;
    }
    return _prefs?.getDouble(def.key) ?? def.defaultValue;
  }

  bool resolveBool(SwitchDef def, KMetaLayerStyle? kmeta) {
    if (kmeta != null && def.kmetaGetter != null) {
      final v = def.kmetaGetter!(kmeta);
      if (v != null) return v;
    }
    return _prefs?.getBool(def.key) ?? def.defaultValue;
  }

  Color resolveColor(ColorDef def, KMetaLayerStyle? kmeta) {
    if (kmeta != null && def.kmetaGetter != null) {
      final v = def.kmetaGetter!(kmeta);
      if (v != null) return v;
    }
    final stored = _prefs?.getInt(def.key);
    return stored != null ? Color(stored) : def.defaultColor;
  }

  String resolveString(StringDef def, KMetaLayerStyle? kmeta) {
    if (kmeta != null && def.kmetaGetter != null) {
      final v = def.kmetaGetter!(kmeta);
      if (v != null) return v;
    }
    return _prefs?.getString(def.key) ?? def.defaultValue;
  }

  // ---------- 値設定 ----------

  Future<void> setDouble(DoubleDef def, double value) async {
    if (_overlay != null) {
      _overlay![def.key] = value;
    } else {
      await _prefs?.setDouble(def.key, value);
    }
    notifyListeners();
  }

  Future<void> setBool(SwitchDef def, bool value) async {
    if (_overlay != null) {
      _overlay![def.key] = value;
    } else {
      await _prefs?.setBool(def.key, value);
    }
    notifyListeners();
  }

  Future<void> setColor(ColorDef def, Color value) async {
    if (_overlay != null) {
      _overlay![def.key] = value;
    } else {
      await _prefs?.setInt(def.key, value.toARGB32());
    }
    notifyListeners();
  }

  Future<void> setInt(IntDef def, int value) async {
    if (_overlay != null) {
      _overlay![def.key] = value;
    } else {
      await _prefs?.setInt(def.key, value);
    }
    notifyListeners();
  }

  Future<void> setString(StringDef def, String value) async {
    if (_overlay != null) {
      _overlay![def.key] = value;
    } else {
      await _prefs?.setString(def.key, value);
    }
    notifyListeners();
  }

  // ---------- リセット ----------

  Future<void> resetAll() async {
    for (final def in allDefs) {
      switch (def) {
        case final DoubleDef d:
          await setDouble(d, d.defaultValue);
        case final SwitchDef s:
          await setBool(s, s.defaultValue);
        case final ColorDef c:
          await setColor(c, c.defaultColor);
        case final IntDef i:
          await setInt(i, i.defaultValue);
        case final StringDef s:
          await setString(s, s.defaultValue);
      }
    }
  }

  // ---------- KMeta オーバーレイ ----------

  /// KMetaLayerStyleからoverlayに値を読み込み（個別レイヤーモード）
  void loadOverlay(KMetaLayerStyle? style) {
    _overlay = {};
    if (style == null) {
      _fillOverlayFromGlobal();
      return;
    }
    // KMeta値を読み込み、ない場合はグローバル値をフォールバック
    for (final def in allDefs) {
      final dynamic kmetaVal = switch (def) {
        final DoubleDef d => d.kmetaGetter?.call(style),
        final SwitchDef s => s.kmetaGetter?.call(style),
        final ColorDef c => c.kmetaGetter?.call(style),
        final StringDef s => s.kmetaGetter?.call(style),
        IntDef _ => null,
      };
      if (kmetaVal != null) {
        _overlay![def.key] = kmetaVal;
      } else {
        // グローバル値をフォールバック
        _overlay![def.key] = _getGlobalValue(def);
      }
    }
  }

  /// overlayをクリア（グローバルモードに戻る）
  void clearOverlay() {
    _overlay = null;
  }

  /// グローバル値を取得（prefsまたはdefault）
  dynamic _getGlobalValue(SettingDef def) => switch (def) {
    final DoubleDef d => _prefs?.getDouble(d.key) ?? d.defaultValue,
    final SwitchDef s => _prefs?.getBool(s.key) ?? s.defaultValue,
    final ColorDef c =>
        _prefs?.getInt(c.key) != null ? Color(_prefs!.getInt(c.key)!) : c.defaultColor,
    final IntDef i => _prefs?.getInt(i.key) ?? i.defaultValue,
    final StringDef s => _prefs?.getString(s.key) ?? s.defaultValue,
  };

  /// overlayにグローバル値を充填
  void _fillOverlayFromGlobal() {
    _overlay ??= {};
    for (final def in allDefs) {
      if (!_overlay!.containsKey(def.key)) {
        _overlay![def.key] = _getGlobalValue(def);
      }
    }
  }
}

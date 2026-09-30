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
/// チェンジログ関連のロジックを集約するサービス
///
/// 言語別のチェンジログファイル（assets/changelog/{locale}.md）を読み込み、
/// ハッシュ比較による未読判定・既読保存を行う。
library;

import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import '../i18n/strings.g.dart';

/// SharedPreferencesキー: 最後に閲覧したCHANGELOGのSHA-256ハッシュ
const _kLastReadHashKey = 'changelog_last_read_hash';

class ChangelogService {
  ChangelogService._();
  static final instance = ChangelogService._();

  /// 言語別キャッシュ
  final Map<String, String> _contentCache = {};
  final Map<String, String> _hashCache = {};

  /// 現在のロケールに基づいてチェンジログを読み込む
  ///
  /// assets/changelog/{locale}.md を探し、見つからなければ ja.md にフォールバック。
  Future<String> loadChangelog() async {
    final locale = LocaleSettings.currentLocale.languageCode;
    return _loadForLocale(locale);
  }

  /// 指定ロケールのチェンジログを読み込む（キャッシュ付き）
  Future<String> _loadForLocale(String locale) async {
    if (_contentCache.containsKey(locale)) return _contentCache[locale]!;

    try {
      final content = await rootBundle.loadString('assets/changelog/$locale.md');
      _contentCache[locale] = content;
      _hashCache[locale] = _computeHash(content);
      return content;
    } catch (_) {
      // フォールバック: ja.md
      if (locale != 'ja') {
        return _loadForLocale('ja');
      }
      return '';
    }
  }

  /// 未読のチェンジログがあるか判定
  ///
  /// 全言語ファイルの連結ハッシュと前回閲覧時のハッシュを比較する。
  /// 言語に依存しない判定にすることで、言語切替時に再通知しない。
  Future<bool> hasUnread() async {
    final hash = await _getMasterHash();
    final prefs = await SharedPreferences.getInstance();
    final lastReadHash = prefs.getString(_kLastReadHashKey);
    // 初回インストールは「更新」ではない。ハッシュが無いときは現在の内容を
    // 既読として記録し、新規ユーザーに「アプリが更新されました」を出さない
    if (lastReadHash == null) {
      await prefs.setString(_kLastReadHashKey, hash);
      return false;
    }
    return lastReadHash != hash;
  }

  /// 現在のチェンジログを既読としてマーク
  Future<void> markAsRead() async {
    final hash = await _getMasterHash();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastReadHashKey, hash);
  }

  /// マスターハッシュ: ja.mdのハッシュを基準とする（言語切替で未読が入れ替わらないように）
  Future<String> _getMasterHash() async {
    await _loadForLocale('ja');
    return _hashCache['ja'] ?? '';
  }

  /// SHA-256ハッシュを計算
  String _computeHash(String content) {
    return sha256.convert(utf8.encode(content)).toString();
  }

  // =============================================
  // 図解（Typst でビルド時に書き出した SVG。tool/changelog/build.py）
  // =============================================

  Set<String>? _assets;

  /// 版の見出し（`## 次のリリース`・`## v0.7.4 …`）に対応する図解の SVG。無ければ null（md で出す）。
  ///
  /// 表示中の言語のものだけ探す。別の言語の図を出すより、その言語の文章のほうがよい
  Future<String?> figureFor(String heading) async {
    final slug = figureSlug(heading);
    if (slug == null) return null;
    final path = 'assets/changelog/svg/$slug.${LocaleSettings.currentLocale.languageCode}.svg';
    _assets ??= (await AssetManifest.loadFromAssetBundle(rootBundle)).listAssets().toSet();
    return _assets!.contains(path) ? path : null;
  }

  /// 見出しから図解のファイル名の版の部分を取る（`次のリリース` → `next`、`v0.7.4 (2026-10-01)` → `v0.7.4`）
  static String? figureSlug(String heading) {
    final h = heading.trim();
    if (h == '次のリリース' || h.toLowerCase() == 'next release') return 'next';
    return RegExp(r'^v\d+\.\d+\.\d+').firstMatch(h)?.group(0);
  }
}

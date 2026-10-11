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
/// web で、Drive のアクセストークンを**タブの中だけ**リロードをまたいで持ち越す。
///
/// web の OAuth（GIS のトークンモデル）にはリフレッシュトークンが無く、トークンを取り直すには
/// 必ずポップアップが要る。ポップアップはクリックの直下でしか開けないので、リロード直後は
/// 何もできず「サインインが切れた」ように見えていた。
///
/// そこで、取れたトークンを失効時刻と一緒に `sessionStorage` に置き、リロード後はそれを使う。
///
/// - 置くのは**アクセストークンだけ**（約 1 時間で失効）。リフレッシュトークンは元から無い
/// - `sessionStorage` はタブごと。タブを閉じれば消え、他のタブからは見えない。
///   ⚠ `localStorage` には置かないこと（ブラウザを閉じても残り、全タブから読める）
/// - 失効時刻を過ぎたもの・使えなかったもの・サインアウトしたときは消す
///
/// native は何もしない（[WebSessionTokenStore.platform] の読み書きが空振りする）。
library;

import 'dart:convert';

import 'web_session_storage_io.dart'
    if (dart.library.js_interop) 'web_session_storage_web.dart' as storage;

/// 失効時刻つきのアクセストークン
class WebSessionToken {
  final String accessToken;
  final DateTime expiresAt;

  const WebSessionToken(this.accessToken, this.expiresAt);

  /// [now] の時点で、まだ [margin] 以上の残りがあるか
  bool isUsableAt(DateTime now, {Duration margin = WebSessionTokenStore.expiryMargin}) =>
      expiresAt.difference(now) > margin;

  String encode() => jsonEncode({'t': accessToken, 'exp': expiresAt.millisecondsSinceEpoch});

  /// 壊れていれば null（手で書き換えられた・形を変えた後の古いもの）
  static WebSessionToken? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final token = map['t'];
      final exp = map['exp'];
      if (token is! String || token.isEmpty || exp is! int) return null;
      return WebSessionToken(token, DateTime.fromMillisecondsSinceEpoch(exp));
    } catch (_) {
      return null;
    }
  }
}

/// [WebSessionToken] の置き場。読み書きの口を差し替えられる（テスト用）
class WebSessionTokenStore {
  /// `sessionStorage` のキー
  static const String key = 'kokage.drive.session_token';

  /// 失効の手前で「もう使えない」とみなす幅。
  /// リロード直後に採用したトークンが、最初の同期の途中で切れないように
  static const Duration expiryMargin = Duration(minutes: 2);

  /// 失効までの秒数が分からないとき（ライブラリ経由で取ったトークン）に仮に置く寿命。
  /// GIS のトークンは 3599 秒。短めに見ておき、外れても採用前の実呼び出しで弾かれる
  static const Duration assumedLifetime = Duration(minutes: 55);

  final String? Function() _read;
  final void Function(String value) _write;
  final void Function() _remove;
  final DateTime Function() _now;

  WebSessionTokenStore({
    required this._read,
    required this._write,
    required this._remove,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// web は `sessionStorage`、native は何も持たない
  factory WebSessionTokenStore.platform() => WebSessionTokenStore(
        read: () => storage.read(key),
        write: (v) => storage.write(key, v),
        remove: () => storage.remove(key),
      );

  /// [accessToken] を置く。[expiresIn] は GIS が返す `expires_in`（無ければ [assumedLifetime]）
  void save(String accessToken, {Duration? expiresIn}) {
    if (accessToken.isEmpty) return;
    final lifetime = (expiresIn == null || expiresIn <= Duration.zero) ? assumedLifetime : expiresIn;
    _write(WebSessionToken(accessToken, _now().add(lifetime)).encode());
  }

  /// まだ使えるトークン。失効間近・壊れたものは消して null
  String? load() {
    final saved = WebSessionToken.decode(_read());
    if (saved == null || !saved.isUsableAt(_now())) {
      clear();
      return null;
    }
    return saved.accessToken;
  }

  void clear() => _remove();
}

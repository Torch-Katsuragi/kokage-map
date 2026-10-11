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
/// web 側。`google.accounts.oauth2.initTokenClient` を直に叩く。
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'web_token_client.dart' show WebTokenGrant;

/// `google.accounts.oauth2`
@JS('google.accounts.oauth2')
external _GisOAuth2? get _oauth2;

extension type _GisOAuth2._(JSObject _) implements JSObject {
  external _TokenClient initTokenClient(JSObject config);
}

extension type _TokenClient._(JSObject _) implements JSObject {
  external void requestAccessToken();
}

extension type _TokenResponse._(JSObject _) implements JSObject {
  // GIS が返すキー名に合わせる（snake_case）
  @JS('access_token')
  external String? get accessToken;
  external String? get error;
  @JS('expires_in')
  external JSAny? get expiresIn;
}

/// `expires_in`（秒）。GIS は数値で返すが、念のため文字列も受ける
Duration? _lifetime(JSAny? raw) {
  final int? seconds;
  if (raw == null) {
    seconds = null;
  } else if (raw.isA<JSNumber>()) {
    seconds = (raw as JSNumber).toDartDouble.round();
  } else if (raw.isA<JSString>()) {
    seconds = int.tryParse((raw as JSString).toDart);
  } else {
    seconds = null;
  }
  return seconds == null || seconds <= 0 ? null : Duration(seconds: seconds);
}

Future<WebTokenGrant?> requestTokenSilently({
  required String clientId,
  required List<String> scopes,
  required String loginHint,
  Duration timeout = const Duration(seconds: 8),
}) async {
  // ⚠ GISのスクリプトは `google_sign_in_web` が**あとから**読み込む。
  // まだなら `google.accounts.oauth2` の参照そのものが例外を投げる
  // （null が返るのではない）。ここで受けないと呼び出し側まで飛ぶ。
  final _GisOAuth2? oauth2;
  try {
    oauth2 = _oauth2;
  } catch (_) {
    return null;
  }
  if (oauth2 == null) return null;

  final completer = Completer<WebTokenGrant?>();
  void finish(WebTokenGrant? grant) {
    if (!completer.isCompleted) completer.complete(grant);
  }

  final config = JSObject();
  config['client_id'] = clientId.toJS;
  config['scope'] = scopes.join(' ').toJS;
  // ⚠ この2つが揃って初めて無音になる。片方だけだと選択画面で止まる
  config['prompt'] = ''.toJS;
  config['login_hint'] = loginHint.toJS;
  config['callback'] = ((_TokenResponse res) {
    final token = res.accessToken;
    finish(res.error == null && token != null && token.isNotEmpty
        ? (token: token, expiresIn: _lifetime(res.expiresIn))
        : null);
  }).toJS;
  config['error_callback'] = ((JSAny? _) => finish(null)).toJS;

  try {
    oauth2.initTokenClient(config).requestAccessToken();
  } catch (_) {
    return null;
  }

  // ⚠ 無音で通らなかったときはポップアップが開いたまま返らない。
  // 待ち続けると画面が固まって見えるので、必ず打ち切る。
  return completer.future.timeout(timeout, onTimeout: () => null);
}

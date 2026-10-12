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
// google_sign_in v7 は設定系のエラーを code=canceled で返すことがある。
// それを「ユーザーが閉じただけ」と誤判定して黙って握り潰さないことを確かめる。

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'package:root_maps/services/google_drive/sign_in_failure.dart';

void main() {
  group('isUserCancellation', () {
    GoogleSignInException canceled(String? description) => GoogleSignInException(
          code: GoogleSignInExceptionCode.canceled,
          description: description,
        );

    test('description が無い canceled はユーザーキャンセル', () {
      expect(isUserCancellation(canceled(null)), isTrue);
    });

    test('ふつうのキャンセル文言はユーザーキャンセル', () {
      expect(
        isUserCancellation(
            canceled('activity is cancelled by the user.')),
        isTrue,
      );
    });

    test('Developer console 未設定は黙らせない', () {
      expect(
        isUserCancellation(
            canceled('[28444] Developer console is not set up correctly.')),
        isFalse,
      );
    });

    test('GMS のステータスコード付きは黙らせない', () {
      expect(
        isUserCancellation(
            canceled('16: Account reauth failed.')),
        isFalse,
      );
    });

    test('deleted_client は黙らせない', () {
      expect(
        isUserCancellation(
            canceled('OAuth client was deleted: deleted_client')),
        isFalse,
      );
    });

    test('認証情報なし系は黙らせない', () {
      expect(
        isUserCancellation(
            canceled('No credential available.')),
        isFalse,
      );
    });

    test('canceled 以外のコードはユーザーキャンセルにしない', () {
      expect(
        isUserCancellation(const GoogleSignInException(
          code: GoogleSignInExceptionCode.clientConfigurationError,
        )),
        isFalse,
      );
    });
  });

  group('formatSignInException', () {
    test('code と description の両方を残す', () {
      const e = GoogleSignInException(
        code: GoogleSignInExceptionCode.providerConfigurationError,
        description: 'auth SDK unavailable',
      );
      expect(
        formatSignInException(e),
        'providerConfigurationError: auth SDK unavailable',
      );
    });

    test('description が無ければ code だけ', () {
      const e = GoogleSignInException(
        code: GoogleSignInExceptionCode.canceled,
      );
      expect(formatSignInException(e), 'canceled');
    });
  });

  group('classifySignInFailure', () {
    const reauth = GoogleSignInException(
      code: GoogleSignInExceptionCode.canceled,
      description: '[16] Account reauth failed.',
    );
    const plainCancel = GoogleSignInException(code: GoogleSignInExceptionCode.canceled);

    test('圏外の [16] reauth は圏外（2026-10 の Pixel 9）', () {
      final f = classifySignInFailure(reauth, online: false);
      expect(f.kind, SignInFailureKind.offline);
      expect(f.detail, 'canceled: [16] Account reauth failed.');
    });

    test('圏外ならキャンセルでも圏外', () {
      expect(classifySignInFailure(plainCancel, online: false).kind, SignInFailureKind.offline);
    });

    test('繋がっていての [16] reauth はその他（コードを添える）', () {
      final f = classifySignInFailure(reauth, online: true);
      expect(f.kind, SignInFailureKind.other);
      expect(f.detail, 'canceled: [16] Account reauth failed.');
    });

    test('繋がっていての本当のキャンセルはキャンセル', () {
      expect(classifySignInFailure(plainCancel, online: true).kind, SignInFailureKind.cancelled);
      expect(
        classifySignInFailure(
          const GoogleSignInException(
            code: GoogleSignInExceptionCode.canceled,
            description: 'activity is cancelled by the user.',
          ),
          online: true,
        ).kind,
        SignInFailureKind.cancelled,
      );
    });

    test('network_error は接続の確認が通っても圏外', () {
      expect(
        classifySignInFailure(
          const GoogleSignInException(
            code: GoogleSignInExceptionCode.unknownError,
            description: 'network_error',
          ),
          online: true,
        ).kind,
        SignInFailureKind.offline,
      );
    });

    test('GMS の [7] NETWORK_ERROR は圏外', () {
      expect(
        classifySignInFailure(
          const GoogleSignInException(
            code: GoogleSignInExceptionCode.unknownError,
            description: '[7] A network error occurred.',
          ),
          online: true,
        ).kind,
        SignInFailureKind.offline,
      );
      expect(
        classifySignInFailure(
          const GoogleSignInException(
            code: GoogleSignInExceptionCode.unknownError,
            description: '7: ',
          ),
          online: true,
        ).kind,
        SignInFailureKind.offline,
      );
    });

    test('[17] や [28444] を [7] と取り違えない', () {
      expect(
        classifySignInFailure(
          const GoogleSignInException(
            code: GoogleSignInExceptionCode.canceled,
            description: '[28444] Developer console is not set up correctly.',
          ),
          online: true,
        ).kind,
        SignInFailureKind.other,
      );
      expect(
        classifySignInFailure(
          const GoogleSignInException(
            code: GoogleSignInExceptionCode.unknownError,
            description: '[17] API not connected',
          ),
          online: true,
        ).kind,
        SignInFailureKind.other,
      );
    });

    test('SocketException の文字列・TimeoutException は圏外', () {
      expect(
        classifySignInFailure(
          Exception('SocketException: Failed host lookup: www.googleapis.com'),
          online: true,
        ).kind,
        SignInFailureKind.offline,
      );
      expect(
        classifySignInFailure(TimeoutException('t'), online: true).kind,
        SignInFailureKind.offline,
      );
    });

    test('設定系のエラーはその他', () {
      final f = classifySignInFailure(
        const GoogleSignInException(
          code: GoogleSignInExceptionCode.clientConfigurationError,
          description: 'bad client',
        ),
        online: true,
      );
      expect(f.kind, SignInFailureKind.other);
      expect(f.detail, 'clientConfigurationError: bad client');
    });

    test('GoogleSignInException 以外のその他は toString を添える', () {
      final f = classifySignInFailure(StateError('boom'), online: true);
      expect(f.kind, SignInFailureKind.other);
      expect(f.detail, contains('boom'));
    });
  });
}

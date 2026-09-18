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

import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'package:root_maps/services/google_drive/google_drive_service.dart';

void main() {
  group('GoogleDriveService.isUserCancellation', () {
    GoogleSignInException canceled(String? description) => GoogleSignInException(
          code: GoogleSignInExceptionCode.canceled,
          description: description,
        );

    test('description が無い canceled はユーザーキャンセル', () {
      expect(GoogleDriveService.isUserCancellation(canceled(null)), isTrue);
    });

    test('ふつうのキャンセル文言はユーザーキャンセル', () {
      expect(
        GoogleDriveService.isUserCancellation(
            canceled('activity is cancelled by the user.')),
        isTrue,
      );
    });

    test('Developer console 未設定は黙らせない', () {
      expect(
        GoogleDriveService.isUserCancellation(
            canceled('[28444] Developer console is not set up correctly.')),
        isFalse,
      );
    });

    test('GMS のステータスコード付きは黙らせない', () {
      expect(
        GoogleDriveService.isUserCancellation(
            canceled('16: Account reauth failed.')),
        isFalse,
      );
    });

    test('deleted_client は黙らせない', () {
      expect(
        GoogleDriveService.isUserCancellation(
            canceled('OAuth client was deleted: deleted_client')),
        isFalse,
      );
    });

    test('認証情報なし系は黙らせない', () {
      expect(
        GoogleDriveService.isUserCancellation(
            canceled('No credential available.')),
        isFalse,
      );
    });

    test('canceled 以外のコードはユーザーキャンセルにしない', () {
      expect(
        GoogleDriveService.isUserCancellation(const GoogleSignInException(
          code: GoogleSignInExceptionCode.clientConfigurationError,
        )),
        isFalse,
      );
    });
  });

  group('GoogleDriveService.formatSignInError', () {
    test('code と description の両方を残す', () {
      const e = GoogleSignInException(
        code: GoogleSignInExceptionCode.providerConfigurationError,
        description: 'auth SDK unavailable',
      );
      expect(
        GoogleDriveService.formatSignInError(e),
        'providerConfigurationError: auth SDK unavailable',
      );
    });

    test('description が無ければ code だけ', () {
      const e = GoogleSignInException(
        code: GoogleSignInExceptionCode.canceled,
      );
      expect(GoogleDriveService.formatSignInError(e), 'canceled');
    });
  });
}

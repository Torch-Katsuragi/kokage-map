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
// Root Maps: Google Drive認証状態管理
// OAuth認証の状態と認証済みユーザー情報を管理

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Google Drive認証状態
enum DriveAuthStatus {
  /// 未認証
  unauthenticated,

  /// 認証中
  authenticating,

  /// 認証済み
  authenticated,

  /// 認証エラー
  error,
}

/// 認証済みユーザー情報
class DriveUser {
  /// ユーザーID
  final String id;

  /// メールアドレス
  final String email;

  /// 表示名
  final String? displayName;

  /// プロフィール画像URL
  final String? photoUrl;

  const DriveUser({
    required this.id,
    required this.email,
    this.displayName,
    this.photoUrl,
  });

  /// GoogleSignInAccountから作成
  factory DriveUser.fromGoogleAccount(GoogleSignInAccount account) {
    return DriveUser(
      id: account.id,
      email: account.email,
      displayName: account.displayName,
      photoUrl: account.photoUrl,
    );
  }

  @override
  String toString() => 'DriveUser(email: $email, displayName: $displayName)';
}

/// Google Drive認証状態を管理するクラス
/// ChangeNotifierを継承してUIに状態変更を通知
class DriveAuthState extends ChangeNotifier {
  DriveAuthStatus _status = DriveAuthStatus.unauthenticated;
  DriveUser? _user;
  String? _errorMessage;

  /// 現在の認証状態
  DriveAuthStatus get status => _status;

  /// 認証済みユーザー情報
  DriveUser? get user => _user;

  /// エラーメッセージ
  String? get errorMessage => _errorMessage;

  /// 認証済みかどうか
  bool get isAuthenticated => _status == DriveAuthStatus.authenticated;

  /// 認証開始
  void setAuthenticating() {
    _status = DriveAuthStatus.authenticating;
    _errorMessage = null;
    notifyListeners();
  }

  /// 認証成功
  void setAuthenticated(DriveUser user) {
    _status = DriveAuthStatus.authenticated;
    _user = user;
    _errorMessage = null;
    notifyListeners();
  }

  /// 認証解除（サインアウト）
  void setUnauthenticated() {
    _status = DriveAuthStatus.unauthenticated;
    _user = null;
    _errorMessage = null;
    notifyListeners();
  }

  /// 認証エラー
  void setError(String message) {
    _status = DriveAuthStatus.error;
    _errorMessage = message;
    notifyListeners();
  }

  /// 状態をリセット
  void reset() {
    _status = DriveAuthStatus.unauthenticated;
    _user = null;
    _errorMessage = null;
    notifyListeners();
  }
}

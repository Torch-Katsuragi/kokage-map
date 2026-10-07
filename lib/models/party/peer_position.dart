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
/// パーティ位置共有: ピア（他メンバー）の現在位置レコード
///
/// 揮発データ（GeoPackageには保存しない）。RTDBの `/rooms/{code}/live/{uid}`
/// 1件に対応する。時刻はサーバー時刻（epoch ms, ServerValue.timestamp由来）で
/// 持ち、端末時計のズレ・改ざんに影響されない鮮度判定を可能にする。
library;

/// 位置情報の鮮度
///
/// サーバー時刻からの経過時間で3段階に分類する。
/// 山中では stale / lost が常態となるため、lost でも消さず
/// 「最終既知地点」として残す方針（[PeerPosition] 側では状態のみ返す）。
enum PeerFreshness {
  /// 新鮮（実線表示）
  fresh,

  /// 古い（淡色＋「N分前」表示）
  stale,

  /// 喪失（最終既知地点ピンに降格）
  lost,
}

/// パーティメンバー1人の現在位置
class PeerPosition {
  /// 鮮度判定の既定しきい値: これ未満は fresh
  static const Duration defaultFreshThreshold = Duration(seconds: 30);

  /// 鮮度判定の既定しきい値: これ以上は lost
  static const Duration defaultLostThreshold = Duration(minutes: 15);

  /// メンバーのuid（Firebase匿名認証のuid）
  final String uid;

  /// 緯度
  final double latitude;

  /// 経度
  final double longitude;

  /// 高度（メートル）
  final double? altitude;

  /// 精度（メートル）
  final double? accuracy;

  /// 方位（度, 0-359）
  final double? bearing;

  /// 速度（m/s）
  final double? speed;

  /// サーバー時刻（epoch ms）。RTDBの ServerValue.timestamp 由来。
  final int serverTimeMs;

  /// バッテリー残量（%, 0-100）
  final int? battery;

  /// 接続状態。onDisconnect により false になる（落ちた＝最終既知地点扱い）。
  final bool connected;

  const PeerPosition({
    required this.uid,
    required this.latitude,
    required this.longitude,
    this.altitude,
    this.accuracy,
    this.bearing,
    this.speed,
    required this.serverTimeMs,
    this.battery,
    this.connected = true,
  });

  /// RTDBのMap（`/live/{uid}` の値）からの変換
  ///
  /// [uid] はキー側から渡す。欠損・型不正には寛容に（フィールド単位でnull化）。
  factory PeerPosition.fromMap(String uid, Map<dynamic, dynamic> map) {
    double req(String k) => (map[k] as num).toDouble();
    double? opt(String k) => (map[k] as num?)?.toDouble();
    return PeerPosition(
      uid: uid,
      latitude: req('lat'),
      longitude: req('lng'),
      altitude: opt('alt'),
      accuracy: opt('acc'),
      bearing: opt('bearing'),
      speed: opt('speed'),
      serverTimeMs: (map['ts'] as num?)?.toInt() ?? 0,
      battery: (map['battery'] as num?)?.toInt(),
      connected: map['connected'] as bool? ?? true,
    );
  }

  /// RTDBへ送る `/live/{uid}` のMap表現
  ///
  /// `ts` は含めない（送信側が `ServerValue.timestamp` を別途付与する）。
  /// セキュリティルールが `ts === now` を要求するため、クライアント時刻は載せない。
  Map<String, Object?> toLiveMap() {
    return {
      'lat': latitude,
      'lng': longitude,
      if (altitude != null) 'alt': altitude,
      if (accuracy != null) 'acc': accuracy,
      if (bearing != null) 'bearing': bearing,
      if (speed != null) 'speed': speed,
      if (battery != null) 'battery': battery,
      'connected': connected,
    };
  }

  /// [nowMs] 時点での経過時間
  Duration ageAt(int nowMs) =>
      Duration(milliseconds: (nowMs - serverTimeMs).clamp(0, 1 << 62));

  /// [nowMs] 時点での鮮度
  ///
  /// 接続断（connected=false）は経過時間に関わらず最低でも stale 扱い。
  PeerFreshness freshnessAt(
    int nowMs, {
    Duration freshThreshold = defaultFreshThreshold,
    Duration lostThreshold = defaultLostThreshold,
  }) {
    final age = ageAt(nowMs);
    if (age >= lostThreshold) return PeerFreshness.lost;
    if (age < freshThreshold) {
      return connected ? PeerFreshness.fresh : PeerFreshness.stale;
    }
    return PeerFreshness.stale;
  }

  @override
  bool operator ==(Object other) =>
      other is PeerPosition &&
      other.uid == uid &&
      other.latitude == latitude &&
      other.longitude == longitude &&
      other.altitude == altitude &&
      other.accuracy == accuracy &&
      other.bearing == bearing &&
      other.speed == speed &&
      other.serverTimeMs == serverTimeMs &&
      other.battery == battery &&
      other.connected == connected;

  @override
  int get hashCode => Object.hash(uid, latitude, longitude, altitude, accuracy,
      bearing, speed, serverTimeMs, battery, connected);

  @override
  String toString() =>
      'PeerPosition(uid: $uid, lat: ${latitude.toStringAsFixed(6)}, '
      'lng: ${longitude.toStringAsFixed(6)}, ts: $serverTimeMs, '
      'connected: $connected)';
}

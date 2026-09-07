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
/// 内蔵GPS位置情報ストア
///
/// 「常に1ストリーム」の原則でGPS位置を管理。
/// モードはプラットフォームで静的に決定:
///   Android → delegated (ForegroundService経由、常時稼働)
///   Windows → direct (自前Geolocator)
///
/// 全ての利用者（地図マーカー、GPS情報バー、追跡mixin等）は
/// このStoreの [positionStream] から座標を取得する。
library;

import 'dart:async';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';

import '../core/platform_capabilities.dart';
import '../i18n/strings.g.dart';
import '../models/gps_position_record.dart';
import '../utils/app_logger.dart';
import 'foreground_service.dart';

/// 内蔵GPS位置情報ストア（シングルトン）
class InternalGpsLocationStore {
  static final InternalGpsLocationStore _instance =
      InternalGpsLocationStore._internal();
  factory InternalGpsLocationStore() => _instance;
  InternalGpsLocationStore._internal();

  static const String _logTag = 'InternalGpsLocationStore';

  // 最新の座標レコード
  GpsPositionRecord? _latestRecord;

  // 前回リクエスト時刻（requestPosition用）
  DateTime? _lastRequestTime;

  // 動作状態
  bool _isActive = false;
  bool _isDelegated = false;

  // directモード用
  StreamSubscription<Position>? _geolocatorSubscription;

  // delegatedモード用
  StreamSubscription<Map<String, dynamic>?>? _serviceSubscription;

  // delegatedモード用: ハートビート応答サブスクリプション
  StreamSubscription<Map<String, dynamic>?>? _heartbeatSubscription;

  // 全モード共通の出力ストリーム
  final StreamController<GpsPositionRecord> _positionController =
      StreamController<GpsPositionRecord>.broadcast();

  // ==============================
  // Getters
  // ==============================

  /// Store が動作中か
  bool get isActive => _isActive;

  /// delegatedモード（ForegroundService経由）かどうか
  bool get isDelegated => _isDelegated;

  /// 最新の座標レコード（同期アクセス用）
  GpsPositionRecord? get latestPosition => _latestRecord;

  /// 位置更新ストリーム（UI、追跡mixin等が購読）
  Stream<GpsPositionRecord> get positionStream => _positionController.stream;

  // ==============================
  // 開始・停止
  // ==============================

  /// 開始（プラットフォームに応じてモード自動選択）
  ///
  /// Android → ForegroundService起動 + delegatedモード
  /// Windows → directモード（自前Geolocator）
  Future<void> start() async {
    if (_isActive) {
      AppLogger.debug('$_logTag: 既に動作中です');
      return;
    }

    try {
      if (PlatformCapabilities.supportsForegroundGpsService) {
        await _startDelegated();
      } else {
        // Windows等
        await _startDirect();
      }
      _isActive = true;
      AppLogger.debug(
        '$_logTag: 開始完了 (${_isDelegated ? "delegated" : "direct"}モード)',
      );
    } catch (e) {
      AppLogger.debug('$_logTag: 開始エラー: $e');
      _isActive = false;
      rethrow;
    }
  }

  /// 停止
  Future<void> stop() async {
    if (!_isActive) return;

    AppLogger.debug('$_logTag: 停止中...');

    // directモード停止
    await _geolocatorSubscription?.cancel();
    _geolocatorSubscription = null;

    // delegatedモード停止
    await _heartbeatSubscription?.cancel();
    _heartbeatSubscription = null;
    await _serviceSubscription?.cancel();
    _serviceSubscription = null;

    // ForegroundServiceが動作中なら停止
    if (_isDelegated) {
      try {
        await ForegroundServiceManager().stopService();
      } catch (e) {
        AppLogger.debug('$_logTag: ForegroundService停止エラー: $e');
      }
    }

    _isActive = false;
    _isDelegated = false;
    AppLogger.debug('$_logTag: 停止完了');
  }

  /// リソース解放
  Future<void> dispose() async {
    await stop();
    // StreamControllerは閉じない（シングルトンのため再利用する可能性あり）
  }

  // ==============================
  // directモード（Windows等）
  // ==============================

  /// directモード開始（自前Geolocatorストリーム）
  Future<void> _startDirect() async {
    _isDelegated = false;

    // 権限チェック（Windows・web以外。どちらもOS/ブラウザ側が面倒を見る）
    if (PlatformCapabilities.needsLocationPermissionCheck) {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception(t.gps.locationServiceDisabled);
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        await Future.delayed(const Duration(milliseconds: 500));
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          await Future.delayed(const Duration(milliseconds: 500));
          permission = await Geolocator.checkPermission();
          if (permission == LocationPermission.denied) {
            throw Exception(t.gps.locationPermissionDenied);
          }
        }
      }
      if (permission == LocationPermission.deniedForever) {
        throw Exception(t.gps.locationPermissionPermanentlyDenied);
      }
    }

    // Geolocatorストリーム開始
    final locationSettings = LocationSettings(
      accuracy: PlatformCapabilities.supportsHighAccuracyGps
          ? LocationAccuracy.high
          : LocationAccuracy.medium,
      distanceFilter: 0,
    );

    _geolocatorSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (position) {
        final record = GpsPositionRecord.fromPosition(position);
        _onPositionReceived(record);
      },
      onError: (error) {
        AppLogger.debug('$_logTag: Geolocatorストリームエラー: $error');
      },
    );

    // ストリームの初回フィックスを待たずに暫定位置を出す（awaitしない）
    unawaited(_seedInitialPosition(locationSettings));

    AppLogger.debug('$_logTag: directモード開始（Geolocatorストリーム）');
  }

  /// ストリームの初回フィックスより先に、単発取得で暫定位置を流す。
  ///
  /// `watchPosition` は本来「位置が**変わったら**通知する」APIなので、
  /// 据え置きのPCだと初回コールバックがいつ来るか保証がない。来るまでは
  /// 「取得中」のままで、**壊れているのと見分けがつかない**。
  /// 購読と並行して単発を一発撃ち、マーカーと初回ジャンプだけ先に成立させる。
  ///
  /// あくまで保険なので、失敗しても黙って諦める（本命はストリーム）。
  Future<void> _seedInitialPosition(LocationSettings settings) async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: settings,
      );

      // ⚠ ストリームが先に届いていたら上書きしない（座標を巻き戻さない）
      if (_latestRecord != null) return;
      // 取得を待っている間に stop() された
      if (!_isActive) return;

      _onPositionReceived(GpsPositionRecord.fromPosition(position));
      AppLogger.debug('$_logTag: 暫定位置を先出し（単発取得）');
    } catch (e) {
      AppLogger.debug('$_logTag: 暫定位置の先出しに失敗（ストリーム待ちに委ねる）: $e');
    }
  }

  // ==============================
  // delegatedモード（Android）
  // ==============================

  /// delegatedモード開始（ForegroundService経由）
  Future<void> _startDelegated() async {
    _isDelegated = true;

    // GPS権限チェック（ForegroundService起動前に確認）
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _isDelegated = false;
      throw Exception(t.gps.locationServiceDisabled);
    }

    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      _isDelegated = false;
      AppLogger.debug(
        '$_logTag: GPS権限が未付与のためdelegatedモードを開始できません (permission: $permission)',
      );
      throw Exception(t.gps.locationPermissionRequired);
    }

    // ForegroundServiceをconfigure → 起動
    final serviceManager = ForegroundServiceManager();
    await serviceManager.initializeService();
    await serviceManager.startService();

    final bgService = FlutterBackgroundService();

    // ハートビート応答: サービスからの heartbeatPing に heartbeatPong を返す
    // メインisolateが生きている限り応答し続けることで、
    // サービス側がアプリの生存を確認できる
    _heartbeatSubscription = bgService.on('heartbeatPing').listen((event) {
      bgService.invoke('heartbeatPong');
    });

    // ForegroundServiceからのpositionUpdateイベントを受信
    _serviceSubscription = bgService.on('positionUpdate').listen((event) {
      if (event != null) {
        try {
          final record = GpsPositionRecord.fromServiceEvent(
            Map<String, dynamic>.from(event),
          );
          _onPositionReceived(record);
        } catch (e) {
          AppLogger.debug('$_logTag: イベント変換エラー: $e');
        }
      }
    });

    AppLogger.debug('$_logTag: delegatedモード開始（ForegroundService経由）');
  }

  // ==============================
  // 共通処理
  // ==============================

  /// 位置更新の受信（どちらのモードでも同じ処理）
  void _onPositionReceived(GpsPositionRecord record) {
    _latestRecord = record;
    _positionController.add(record);
  }

  /// 座標をリクエスト（更新有無フラグ付き）
  ///
  /// 前回の [requestPosition] 呼び出し以降にGPS更新があったかを
  /// [GpsPositionResponse.hasNewUpdate] で判定可能。
  /// 呼び出すたびに内部タイムスタンプが更新される。
  GpsPositionResponse requestPosition() {
    final record = _latestRecord;
    final lastReq = _lastRequestTime;

    // 前回リクエスト以降に新しい座標があるか判定
    final hasNew = record != null &&
        (lastReq == null || record.receivedAt.isAfter(lastReq));

    // リクエスト時刻を更新
    _lastRequestTime = DateTime.now();

    return GpsPositionResponse(
      position: record,
      hasNewUpdate: hasNew,
      lastUpdateTime: record?.receivedAt,
    );
  }
}

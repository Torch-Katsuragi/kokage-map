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
// Root Maps: 初回起動オンボーディング画面
// 権限設定を順序立てて案内するフルスクリーンUI
// Google Play Prominent Disclosure準拠

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../i18n/strings.g.dart';
import '../core/platform_capabilities.dart';
import '../utils/app_logger.dart';

/// オンボーディング完了フラグのSharedPreferencesキー
const kOnboardingCompletedKey = 'onboarding_completed';

/// 初回起動オンボーディング画面
///
/// 4ページ構成のPageView:
/// 1. ウェルカム（説明のみ）
/// 2. ストレージ権限
/// 3. 位置情報権限（Prominent Disclosure）
/// 4. Bluetooth権限（オプション）+ 完了
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  /// オンボーディングが必要かどうかを判定
  static Future<bool> shouldShow() async {
    if (!PlatformCapabilities.showsOnboarding) {
      return false; // デスクトップ・web では不要
    }
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(kOnboardingCompletedKey) ?? false);
  }

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  static const _totalPages = 4;

  // 権限状態
  bool _storageGranted = false;
  bool _locationGranted = false;
  bool _bluetoothGranted = false;

  // ローディング状態
  bool _isRequestingPermission = false;

  @override
  void initState() {
    super.initState();
    _checkCurrentPermissions();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// 現在の権限状態をチェック
  Future<void> _checkCurrentPermissions() async {
    final storage = await Permission.manageExternalStorage.isGranted;
    final location = await Permission.location.isGranted;
    final btScan = await Permission.bluetoothScan.isGranted;
    final btConnect = await Permission.bluetoothConnect.isGranted;

    if (mounted) {
      setState(() {
        _storageGranted = storage;
        _locationGranted = location;
        _bluetoothGranted = btScan && btConnect;
      });
    }
  }

  /// 次のページへ遷移
  void _goToNextPage() {
    if (_currentPage < _totalPages - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    }
  }

  /// ストレージ権限をリクエスト
  Future<void> _requestStoragePermission() async {
    if (_isRequestingPermission) return;
    setState(() => _isRequestingPermission = true);

    try {
      final status = await Permission.manageExternalStorage.request();
      AppLogger.debug('[Onboarding] Storage permission result: $status');

      if (mounted) {
        setState(() {
          _storageGranted = status.isGranted;
          _isRequestingPermission = false;
        });
        if (status.isGranted) {
          await Future.delayed(const Duration(milliseconds: 500));
          _goToNextPage();
        }
      }
    } catch (e) {
      AppLogger.debug('[Onboarding] Storage permission error: $e');
      if (mounted) setState(() => _isRequestingPermission = false);
    }
  }

  /// 位置情報権限をリクエスト
  Future<void> _requestLocationPermission() async {
    if (_isRequestingPermission) return;
    setState(() => _isRequestingPermission = true);

    try {
      final status = await Permission.location.request();
      AppLogger.debug('[Onboarding] Location permission result: $status');

      // Android 13+ は通知権限が無いと前景サービスの常時通知が表示されない。
      // 位置情報が許可された流れで続けて要求する（GPS記録・位置共有の実行中表示）。
      if (status.isGranted) {
        final notif = await Permission.notification.request();
        AppLogger.debug('[Onboarding] Notification permission result: $notif');
      }

      if (mounted) {
        setState(() {
          _locationGranted = status.isGranted;
          _isRequestingPermission = false;
        });
        if (status.isGranted) {
          await Future.delayed(const Duration(milliseconds: 500));
          _goToNextPage();
        }
      }
    } catch (e) {
      AppLogger.debug('[Onboarding] Location permission error: $e');
      if (mounted) setState(() => _isRequestingPermission = false);
    }
  }

  /// Bluetooth権限をリクエスト
  Future<void> _requestBluetoothPermission() async {
    if (_isRequestingPermission) return;
    setState(() => _isRequestingPermission = true);

    try {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();

      final scanGranted =
          statuses[Permission.bluetoothScan]?.isGranted ?? false;
      final connectGranted =
          statuses[Permission.bluetoothConnect]?.isGranted ?? false;

      AppLogger.debug(
          '[Onboarding] Bluetooth permission result: scan=$scanGranted, connect=$connectGranted');

      if (mounted) {
        setState(() {
          _bluetoothGranted = scanGranted && connectGranted;
          _isRequestingPermission = false;
        });
      }
    } catch (e) {
      AppLogger.debug('[Onboarding] Bluetooth permission error: $e');
      if (mounted) setState(() => _isRequestingPermission = false);
    }
  }

  /// オンボーディング完了処理
  Future<void> _completeOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kOnboardingCompletedKey, true);
    AppLogger.debug('[Onboarding] Onboarding completed');

    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0D1B2A),
              Color(0xFF1B2838),
              Color(0xFF1A3A5C),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // ページインジケーター
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    _totalPages,
                    (index) => _buildDotIndicator(index),
                  ),
                ),
              ),

              // ページコンテンツ
              Expanded(
                child: PageView(
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (page) {
                    setState(() => _currentPage = page);
                  },
                  children: [
                    _buildWelcomePage(),
                    _buildStoragePage(),
                    _buildLocationPage(),
                    _buildBluetoothPage(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// ドットインジケーター（自前実装）
  Widget _buildDotIndicator(int index) {
    final isActive = index == _currentPage;
    final isPast = index < _currentPage;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.symmetric(horizontal: 4),
      width: isActive ? 28 : 10,
      height: 10,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        color: isActive
            ? Colors.white
            : isPast
                ? Colors.white.withValues(alpha: 0.6)
                : Colors.white.withValues(alpha: 0.25),
      ),
    );
  }

  // ================================================================
  // ページ1: ウェルカム
  // ================================================================
  Widget _buildWelcomePage() {
    return _OnboardingPage(
      icon: Icons.map_rounded,
      iconColor: const Color(0xFF4FC3F7),
      title: t.onboarding.welcome,
      description: t.onboarding.welcomeDesc,
      bottomWidget: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: _buildPrimaryButton(
          label: t.onboarding.next,
          icon: Icons.arrow_forward_rounded,
          onPressed: _goToNextPage,
        ),
      ),
    );
  }

  // ================================================================
  // ページ2: ストレージ権限
  // ================================================================
  Widget _buildStoragePage() {
    return _OnboardingPage(
      icon: Icons.folder_rounded,
      iconColor: const Color(0xFFFFB74D),
      title: t.onboarding.storageTitle,
      description: t.onboarding.storageDisclosure,
      bottomWidget: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_storageGranted)
              _buildGrantedBadge()
            else ...[
              _buildPrimaryButton(
                label: t.onboarding.storageButton,
                icon: Icons.check_circle_outline,
                onPressed: _requestStoragePermission,
                isLoading: _isRequestingPermission,
              ),
              const SizedBox(height: 12),
              _buildSecondaryButton(
                label: t.onboarding.laterSettings,
                onPressed: _goToNextPage,
              ),
            ],
            if (_storageGranted) ...[
              const SizedBox(height: 16),
              _buildPrimaryButton(
                label: t.onboarding.next,
                icon: Icons.arrow_forward_rounded,
                onPressed: _goToNextPage,
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ================================================================
  // ページ3: 位置情報権限（Prominent Disclosure）
  // ================================================================
  Widget _buildLocationPage() {
    return _OnboardingPage(
      icon: Icons.gps_fixed_rounded,
      iconColor: const Color(0xFF66BB6A),
      title: t.onboarding.locationTitle,
      description: t.onboarding.locationDisclosure,
      bottomWidget: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_locationGranted)
              _buildGrantedBadge()
            else ...[
              _buildPrimaryButton(
                label: t.onboarding.locationButton,
                icon: Icons.check_circle_outline,
                onPressed: _requestLocationPermission,
                isLoading: _isRequestingPermission,
              ),
              const SizedBox(height: 12),
              _buildSecondaryButton(
                label: t.onboarding.laterSettings,
                onPressed: _goToNextPage,
              ),
            ],
            if (_locationGranted) ...[
              const SizedBox(height: 16),
              _buildPrimaryButton(
                label: t.onboarding.next,
                icon: Icons.arrow_forward_rounded,
                onPressed: _goToNextPage,
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ================================================================
  // ページ4: Bluetooth権限 + 完了
  // ================================================================
  Widget _buildBluetoothPage() {
    return _OnboardingPage(
      icon: Icons.bluetooth_rounded,
      iconColor: const Color(0xFF42A5F5),
      title: t.onboarding.bluetoothTitle,
      description: t.onboarding.bluetoothDisclosure,
      bottomWidget: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_bluetoothGranted) ...[
              _buildPrimaryButton(
                label: t.onboarding.bluetoothButton,
                icon: Icons.check_circle_outline,
                onPressed: _requestBluetoothPermission,
                isLoading: _isRequestingPermission,
              ),
              const SizedBox(height: 12),
            ],
            if (_bluetoothGranted) _buildGrantedBadge(),
            const SizedBox(height: 16),
            // 「はじめる」ボタン（常に表示）
            _buildPrimaryButton(
              label: _bluetoothGranted
                  ? t.onboarding.getStarted
                  : t.onboarding.bluetoothSkip,
              icon: _bluetoothGranted
                  ? Icons.rocket_launch_rounded
                  : Icons.skip_next_rounded,
              onPressed: _completeOnboarding,
              color: _bluetoothGranted
                  ? const Color(0xFF66BB6A)
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  // ================================================================
  // 共通ウィジェット
  // ================================================================

  /// プライマリボタン
  Widget _buildPrimaryButton({
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
    bool isLoading = false,
    Color? color,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton.icon(
        onPressed: isLoading ? null : onPressed,
        icon: isLoading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Icon(icon),
        label: Text(label, style: const TextStyle(fontSize: 16)),
        style: ElevatedButton.styleFrom(
          backgroundColor: color ?? const Color(0xFF4FC3F7),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 4,
        ),
      ),
    );
  }

  /// セカンダリボタン（テキストのみ）
  Widget _buildSecondaryButton({
    required String label,
    required VoidCallback onPressed,
  }) {
    return TextButton(
      onPressed: onPressed,
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.6),
          fontSize: 14,
        ),
      ),
    );
  }

  /// 許可済みバッジ
  Widget _buildGrantedBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF66BB6A).withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF66BB6A).withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, color: Color(0xFF66BB6A), size: 20),
          const SizedBox(width: 8),
          Text(
            t.onboarding.permissionGranted,
            style: const TextStyle(
              color: Color(0xFF66BB6A),
              fontWeight: FontWeight.bold,
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }
}

// ================================================================
// オンボーディングページの共通レイアウト
// ================================================================

class _OnboardingPage extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String description;
  final Widget bottomWidget;

  const _OnboardingPage({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.description,
    required this.bottomWidget,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 40),

          // アイコン
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  iconColor.withValues(alpha: 0.3),
                  iconColor.withValues(alpha: 0.1),
                ],
              ),
              border: Border.all(
                color: iconColor.withValues(alpha: 0.3),
                width: 2,
              ),
            ),
            child: Icon(icon, size: 56, color: iconColor),
          ),

          const SizedBox(height: 32),

          // タイトル
          Text(
            title,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              letterSpacing: -0.5,
            ),
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: 20),

          // 説明文（Prominent Disclosure）
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              description,
              style: TextStyle(
                fontSize: 15,
                color: Colors.white.withValues(alpha: 0.8),
                height: 1.6,
              ),
              textAlign: TextAlign.center,
            ),
          ),

          const SizedBox(height: 40),

          // ボトムウィジェット（ボタン類）
          bottomWidget,

          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

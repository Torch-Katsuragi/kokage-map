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
/// ホーム画面のヘッダ帯と更新案内バナー群
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';
import '../../services/app_update_service.dart';

/// こかげの緑（ホームだけの色）
const kKokageGreen = Color(0xFF2E6B4F);
const _kKokageGreenLight = Color(0xFFE3F0E8);

/// 上の帯: 等高線を敷いた見出し
class HomeHeader extends StatelessWidget {
  const HomeHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: 132,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: _kKokageGreenLight),
            const CustomPaint(painter: _ContourPainter()),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.common.appName,
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: kKokageGreen),
                  ),
                  const SizedBox(height: 2),
                  Text(t.home.tagline, style: TextStyle(fontSize: 13, color: kKokageGreen.withValues(alpha: 0.8))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 山の等高線（決まった形。毎回同じに見えるように乱数は使わない）
class _ContourPainter extends CustomPainter {
  const _ContourPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = kKokageGreen.withValues(alpha: 0.22);
    // 右上に頂のある山。中心からの距離で輪を何本か描く
    final c = Offset(size.width * 0.78, size.height * 0.28);
    for (var i = 1; i <= 9; i++) {
      final r = i * 16.0;
      final path = Path();
      for (var a = 0; a <= 72; a++) {
        final th = a / 72 * 2 * math.pi;
        final wobble = 1 + 0.12 * math.sin(th * 3 + i * 0.7) + 0.06 * math.sin(th * 5 - i);
        final o = c + Offset(math.cos(th) * r * 1.6 * wobble, math.sin(th) * r * wobble);
        if (a == 0) {
          path.moveTo(o.dx, o.dy);
        } else {
          path.lineTo(o.dx, o.dy);
        }
      }
      path.close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_ContourPainter old) => false;
}

/// Play ストア更新通知バナー
///
/// 最新版が公開されたときに表示され、タップで Google Play ストアのページへ遷移する。
class PlayStoreUpdateBanner extends StatelessWidget {
  final AppUpdateInfo updateInfo;
  final VoidCallback onTap;

  const PlayStoreUpdateBanner({
    super.key,
    required this.updateInfo,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: const Color(0xFFE8F4FE),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF90CAF9)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Row(
            children: [
              const Icon(
                Icons.system_update,
                color: Color(0xFF0D47A1),
                size: 24,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.home.updateAvailableTitle(
                        latest: updateInfo.latestVersion,
                      ),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF0D47A1),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      t.home.updateAvailableSubtitle(
                        current: updateInfo.currentVersion,
                      ),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF1565C0),
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.open_in_new,
                color: Color(0xFF0D47A1),
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// チェンジログ更新通知バナー（アニメーション付き）
///
/// アイコン直下に表示され、タップでチェンジログ画面に遷移する。
class ChangelogUpdateBanner extends StatefulWidget {
  final VoidCallback onTap;
  const ChangelogUpdateBanner({super.key, required this.onTap});

  @override
  State<ChangelogUpdateBanner> createState() => _ChangelogUpdateBannerState();
}

class _ChangelogUpdateBannerState extends State<ChangelogUpdateBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _scaleAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.elasticOut,
    );
    _fadeAnimation = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    // 少し遅らせてアニメーション開始（画面描画完了後に注目させる）
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: Card(
          elevation: 0,
          color: const Color(0xFFFFF4D6), // ホームの緑に合う淡い黄
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.auto_awesome,
                    color: Color(0xFF6B4E00),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    t.changelog.updated,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF6B4E00),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.chevron_right,
                    color: Color(0xFF6B4E00),
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

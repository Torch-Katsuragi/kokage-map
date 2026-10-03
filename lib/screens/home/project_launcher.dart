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
// こかげマップ: ホームの入口（ゲームの「続きから」「はじめから」のように）
//
// 上に等高線の帯、その下に「続きから」（最後に開いたプロジェクト）、「新しく作る」「ほかの場所を開く」、
// 置き場所のプロジェクトの一覧、チュートリアル。置き場所は [ProjectsHome]（2026-10-03）。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../i18n/strings.g.dart';
import '../../services/projects_home.dart';

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

/// 「続きから」「新しく作る」「ほかの場所を開く」と一覧
class ProjectLauncher extends StatelessWidget {
  const ProjectLauncher({
    super.key,
    required this.last,
    required this.projects,
    required this.enabled,
    required this.onOpen,
    required this.onCreate,
    required this.onPickOther,
    this.onReceive,
  });

  /// 最後に開いたプロジェクト（無ければ null）
  final String? last;
  final List<ProjectEntry> projects;
  final bool enabled;
  final ValueChanged<String> onOpen;
  final VoidCallback onCreate;
  final VoidCallback onPickOther;

  /// 共有を受け取る（QR）。まだ無ければ null
  final VoidCallback? onReceive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lastPath = last;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (lastPath != null) ...[
          _ContinueCard(path: lastPath, enabled: enabled, onTap: () => onOpen(lastPath)),
          const SizedBox(height: 10),
        ],
        Row(
          children: [
            Expanded(child: _ActionTile(icon: Icons.add, label: t.home.newProject, enabled: enabled, onTap: onCreate)),
            const SizedBox(width: 10),
            if (onReceive != null) ...[
              Expanded(
                child: _ActionTile(icon: Icons.qr_code_scanner, label: t.home.receiveShared, enabled: enabled, onTap: onReceive!),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: _ActionTile(icon: Icons.folder_open, label: t.home.openOther, enabled: enabled, onTap: onPickOther),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(t.home.projects, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.outline)),
        const SizedBox(height: 4),
        if (projects.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(t.home.noProjects, style: TextStyle(color: theme.colorScheme.outline)),
          )
        else
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: theme.dividerColor)),
            ),
            child: Column(
              children: [
                for (final e in projects)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    enabled: enabled,
                    leading: const Icon(Icons.folder_outlined, color: kKokageGreen),
                    title: Text(e.name),
                    subtitle: Text(_ago(e.modified), style: const TextStyle(fontSize: 12)),
                    trailing: e.driveLinked ? Icon(Icons.cloud_outlined, size: 20, color: theme.colorScheme.outline) : null,
                    shape: Border(bottom: BorderSide(color: theme.dividerColor)),
                    onTap: () => onOpen(e.path),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// いちばん目立つ「続きから」
class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.path, required this.enabled, required this.onTap});
  final String path;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kKokageGreen,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          child: Row(
            children: [
              const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.home.continueLast, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      p.basename(path),
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.icon, required this.label, required this.enabled, required this.onTap});
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
          child: Column(
            children: [
              Icon(icon, color: kKokageGreen),
              const SizedBox(height: 4),
              Text(label, style: const TextStyle(fontSize: 13), textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「3 時間前」「昨日」など
String _ago(DateTime d) {
  if (d.millisecondsSinceEpoch == 0) return '';
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 1) return t.home.agoNow;
  if (diff.inHours < 1) return t.home.agoMinutes(n: '${diff.inMinutes}');
  if (diff.inDays < 1) return t.home.agoHours(n: '${diff.inHours}');
  if (diff.inDays < 2) return t.home.agoYesterday;
  if (diff.inDays < 30) return t.home.agoDays(n: '${diff.inDays}');
  return '${d.year}/${d.month}/${d.day}';
}

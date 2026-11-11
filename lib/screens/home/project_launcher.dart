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
// こかげマップ: ホームの入口カード群（native ランチャ・web フォルダ選択・プレビュー入口）
//
// 「続きから」（最後に開いたプロジェクト）、「いつもの地図を開く」「QR で受け取る」「ほかの場所を開く」、
// チュートリアル、および web ブラウザ向けのフォルダ選択・閲覧専用カードをまとめる。
// 置き場所は [ProjectsHome]（2026-10-03）。

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../i18n/strings.g.dart';
import 'home_header_banners.dart';

export 'home_header_banners.dart' show HomeHeader, kKokageGreen;

/// いちばん大きい「地図を開く」と、「続きから」「QR で受け取る」「ほかの場所を開く」
class ProjectLauncher extends StatelessWidget {
  const ProjectLauncher({
    super.key,
    required this.last,
    required this.enabled,
    required this.onOpenMyMap,
    required this.onOpenLast,
    required this.onPickOther,
    this.onReceive,
  });

  /// 最後に開いたのが「ほかの場所」ならそのパス（いつもの地図なら null）
  final String? last;
  final bool enabled;
  final VoidCallback onOpenMyMap;
  final ValueChanged<String> onOpenLast;
  final VoidCallback onPickOther;

  /// 共有を受け取る（QR）。まだ無ければ null
  final VoidCallback? onReceive;

  @override
  Widget build(BuildContext context) {
    final lastPath = last;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BigButton(
          icon: Icons.map_outlined,
          title: t.home.openMyMap,
          subtitle: t.home.openMyMapHint,
          enabled: enabled,
          onTap: onOpenMyMap,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
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
        if (lastPath != null) ...[
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: enabled ? () => onOpenLast(lastPath) : null,
              icon: const Icon(Icons.history, size: 18),
              label: Text(t.home.continueOther(name: p.basename(lastPath))),
              style: TextButton.styleFrom(foregroundColor: kKokageGreen),
            ),
          ),
        ],
      ],
    );
  }
}

/// 置き場所のホーム（native）。権限が無い間は案内とやり直しだけ
class NativeHomeLauncher extends StatelessWidget {
  const NativeHomeLauncher({
    super.key,
    required this.permissionsGranted,
    required this.isOpeningProject,
    required this.openingProjectStatus,
    required this.lastProject,
    required this.canTutorial,
    required this.onRecheckPermissions,
    required this.onOpenMyMap,
    required this.onOpenLast,
    required this.onPickOther,
    required this.onReceive,
    required this.onStartTutorial,
  });

  final bool permissionsGranted;
  final bool isOpeningProject;
  final String openingProjectStatus;
  final String? lastProject;
  final bool canTutorial;
  final VoidCallback onRecheckPermissions;
  final VoidCallback onOpenMyMap;
  final ValueChanged<String> onOpenLast;
  final VoidCallback onPickOther;
  final VoidCallback? onReceive;
  final VoidCallback onStartTutorial;

  @override
  Widget build(BuildContext context) {
    if (!permissionsGranted) {
      return Column(
        children: [
          const Icon(Icons.warning_amber, color: Colors.orange, size: 40),
          const SizedBox(height: 8),
          Text(t.home.permissionRequired, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: onRecheckPermissions,
            icon: const Icon(Icons.refresh),
            label: Text(t.home.recheckPermission),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ProjectLauncher(
          last: lastProject,
          enabled: !isOpeningProject,
          onOpenMyMap: onOpenMyMap,
          onOpenLast: onOpenLast,
          onPickOther: onPickOther,
          onReceive: onReceive,
        ),
        if (isOpeningProject) ...[
          const SizedBox(height: 16),
          Text(openingProjectStatus, style: const TextStyle(color: Colors.grey), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          const LinearProgressIndicator(color: kKokageGreen),
        ],
        if (canTutorial && !isOpeningProject) ...[
          const SizedBox(height: 12),
          Align(
            child: TextButton.icon(
              onPressed: onStartTutorial,
              icon: const Icon(Icons.school_outlined),
              label: Text(t.tutorial.homeButton),
              style: TextButton.styleFrom(foregroundColor: kKokageGreen),
            ),
          ),
        ],
      ],
    );
  }
}

/// フォルダを開けない環境向けの入口カード（地図だけ見る）
///
/// いま該当するのは **File System Access API を持たないブラウザ**
/// （Firefox / Safari）だけ。Chrome / Edge なら通常のフォルダ選択が出る。
class WebPreviewCard extends StatelessWidget {
  const WebPreviewCard({super.key, required this.onOpenMapWithoutProject});

  final VoidCallback onOpenMapWithoutProject;

  @override
  Widget build(BuildContext context) {
    return StartCard(
      icon: Icons.public,
      iconColor: Colors.blue,
      title: t.home.webUnsupportedBrowserTitle,
      description: t.home.webUnsupportedBrowserDesc,
      children: [
        ElevatedButton.icon(
          onPressed: onOpenMapWithoutProject,
          icon: const Icon(Icons.map),
          label: Text(t.home.openMap),
          style: StartCard.buttonStyle(Colors.blue),
        ),
      ],
    );
  }
}

/// フォルダを選んで開くカード（web の Chrome / Edge）
class WebFolderPickerCard extends StatelessWidget {
  const WebFolderPickerCard({
    super.key,
    required this.permissionsGranted,
    required this.isOpeningProject,
    required this.openingProjectStatus,
    required this.lastFolderName,
    required this.canTutorial,
    required this.onPickProjectDir,
    required this.onReopenLastFolder,
    required this.onStartTutorial,
    required this.onRecheckPermissions,
  });

  final bool permissionsGranted;
  final bool isOpeningProject;
  final String openingProjectStatus;
  final String? lastFolderName;
  final bool canTutorial;
  final VoidCallback onPickProjectDir;
  final VoidCallback onReopenLastFolder;
  final VoidCallback onStartTutorial;
  final VoidCallback onRecheckPermissions;

  @override
  Widget build(BuildContext context) {
    final ready = permissionsGranted && !isOpeningProject;
    return StartCard(
      icon: Icons.folder_open,
      iconColor: Colors.orange,
      title: t.home.startProject,
      description: t.home.selectProjectFolder,
      children: [
        ElevatedButton.icon(
          onPressed: ready ? onPickProjectDir : null,
          icon: Icon(
            isOpeningProject ? Icons.hourglass_top : (permissionsGranted ? Icons.folder : Icons.warning),
          ),
          label: Text(
            isOpeningProject
                ? t.home.launching
                : (permissionsGranted ? t.home.selectFolder : t.home.permissionRequired),
          ),
          style: StartCard.buttonStyle(ready ? Colors.blue : Colors.grey),
        ),
        if (lastFolderName != null && !isOpeningProject) ...[
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: permissionsGranted ? onReopenLastFolder : null,
            icon: const Icon(Icons.history),
            label: Text('${t.home.reopenLastFolder}（$lastFolderName）'),
            style: TextButton.styleFrom(foregroundColor: Colors.blue),
          ),
        ],
        if (canTutorial && !isOpeningProject) ...[
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: permissionsGranted ? onStartTutorial : null,
            icon: const Icon(Icons.school_outlined),
            label: Text(t.tutorial.homeButton),
          ),
        ],
        if (isOpeningProject) ...[
          const SizedBox(height: 12),
          Text(openingProjectStatus, style: const TextStyle(color: Colors.grey), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
        ],
        if (!permissionsGranted) ...[
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: onRecheckPermissions,
            icon: const Icon(Icons.refresh),
            label: Text(t.home.recheckPermission),
            style: TextButton.styleFrom(foregroundColor: Colors.blue),
          ),
        ],
      ],
    );
  }
}

/// 地図から戻ってきたときの導線。タップでピッカーを通さず同じフォルダを開き直す
class ReopenProjectCard extends StatelessWidget {
  const ReopenProjectCard({
    super.key,
    required this.dir,
    required this.isOpeningProject,
    required this.onReopen,
  });

  final String dir;
  final bool isOpeningProject;
  final ValueChanged<String> onReopen;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.green[50],
      child: InkWell(
        onTap: isOpeningProject ? null : () => onReopen(dir),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              const Icon(Icons.check_circle, color: Colors.green, size: 24),
              const SizedBox(height: 8),
              Text(t.common.selectedFolder, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(dir, style: const TextStyle(fontSize: 12, fontFamily: 'monospace'), textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(t.home.tapToOpenMap, style: TextStyle(color: Colors.green[800])),
            ],
          ),
        ),
      ),
    );
  }
}

/// 入口のカード（アイコン・見出し・説明の下にボタンを並べる）
class StartCard extends StatelessWidget {
  const StartCard({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.description,
    required this.children,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String description;
  final List<Widget> children;

  static ButtonStyle buttonStyle(Color background) => ElevatedButton.styleFrom(
        backgroundColor: background,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
        textStyle: const TextStyle(fontSize: 16),
      );

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            Icon(icon, size: 48, color: iconColor),
            const SizedBox(height: 16),
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(description, style: const TextStyle(color: Colors.grey), textAlign: TextAlign.center),
            const SizedBox(height: 24),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// いちばん目立つ「地図を開く」
class _BigButton extends StatelessWidget {
  const _BigButton({required this.icon, required this.title, required this.subtitle, required this.enabled, required this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kKokageGreen,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
          child: Row(
            children: [
              Icon(icon, color: Colors.white, size: 36),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 13)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white),
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

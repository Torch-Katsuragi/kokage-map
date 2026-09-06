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
/// 地図画面AppBarの「≡」メニュー: パーティ・水準器（コンパス）・設定を集約。
library;


import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../i18n/strings.g.dart';
import '../../../core/platform_capabilities.dart';
import '../../../providers/party_providers.dart';
import '../../level_screen.dart';
import '../../settings_screen.dart';
import 'party_controls.dart';

/// AppBarに置く展開メニュー（≡）。
///
/// パーティが参加中のときは ≡ アイコンに接続状態色のバッジ（人数）を出し、
/// 大きなFABを置かずに状態を一目で分かるようにする。
class MapMenuButton extends ConsumerWidget {
  const MapMenuButton({super.key});

  static const String _party = 'party';
  static const String _level = 'level';
  static const String _settings = 'settings';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(partySessionProvider);
    final partySupported = PlatformCapabilities.supportsPartySharing;
    final partyActive = partySupported && session.active;

    const menuIcon = Icon(Icons.menu);
    return PopupMenuButton<String>(
      tooltip: t.common.menu,
      icon: partyActive
          ? Badge(
              backgroundColor: partyConnectionColor(session.connection),
              label: session.peers.isNotEmpty
                  ? Text('${session.peers.length}')
                  : null,
              child: menuIcon,
            )
          : menuIcon,
      onSelected: (value) {
        switch (value) {
          case _party:
            showPartyEntry(context, ref);
          case _level:
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LevelScreen()),
            );
          case _settings:
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            );
        }
      },
      itemBuilder: (context) => [
        if (partySupported)
          PopupMenuItem<String>(
            value: _party,
            child: _MenuRow(
              icon: session.active ? Icons.groups : Icons.groups_outlined,
              iconColor: session.active
                  ? partyConnectionColor(session.connection)
                  : null,
              label: t.party.title,
              trailing: session.active
                  ? partyConnectionLabel(session.connection)
                  : null,
            ),
          ),
        PopupMenuItem<String>(
          value: _level,
          child: _MenuRow(icon: Icons.explore, label: t.level.tooltip),
        ),
        PopupMenuItem<String>(
          value: _settings,
          child: _MenuRow(icon: Icons.settings, label: t.common.settings),
        ),
      ],
    );
  }
}

/// メニュー1項目の行（アイコン＋ラベル＋任意の右側テキスト）。
class _MenuRow extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String label;
  final String? trailing;

  const _MenuRow({
    required this.icon,
    required this.label,
    this.iconColor,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 22, color: iconColor),
        const SizedBox(width: 12),
        Expanded(child: Text(label)),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          Text(
            trailing!,
            style: TextStyle(
              fontSize: 12,
              color: iconColor ?? Theme.of(context).hintColor,
            ),
          ),
        ],
      ],
    );
  }
}

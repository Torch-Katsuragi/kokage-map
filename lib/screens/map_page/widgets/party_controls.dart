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
/// パーティ位置共有: 地図画面のUI（入口ボタン・作成/参加ダイアログ・ステータス）
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/platform_capabilities.dart';
import '../../../i18n/strings.g.dart';
import '../../../models/app_notification.dart';
import '../../../models/party/party_room.dart';
import '../../../providers/notification_providers.dart';
import '../../../providers/party_providers.dart';
import '../../../services/party/party_connection_monitor.dart';
import '../../../services/party/party_invite.dart';

/// 接続状態の表示ラベル
String partyConnectionLabel(PartyConnectionState s) => switch (s) {
      PartyConnectionState.online => t.party.connSharing,
      PartyConnectionState.connecting => t.party.connConnecting,
      PartyConnectionState.offline => t.party.connOffline,
    };

Color partyConnectionColor(PartyConnectionState s) => switch (s) {
      PartyConnectionState.online => Colors.green,
      PartyConnectionState.connecting => Colors.orange,
      PartyConnectionState.offline => Colors.grey,
    };

/// パーティ機能の入口。参加中はステータスシート、未参加は作成/参加ダイアログを開く。
///
/// AppBarメニュー・FABなど、どこからでも同じ導線を開くための共通エントリ。
/// [initialCode] は招待URL（`?room=CODE`）経由の起動時に参加欄へ充填する。
void showPartyEntry(BuildContext context, WidgetRef ref,
    {String? initialCode}) {
  if (ref.read(partySessionProvider).active) {
    _showStatusSheet(context, ref);
  } else {
    _showJoinCreateDialog(context, ref, initialCode: initialCode);
  }
}

/// パーティ（位置共有）入口ボタン（現在は統合テスト用途。本番導線はAppBarメニュー）
class PartyButton extends ConsumerWidget {
  const PartyButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(partySessionProvider);
    final active = session.active;
    final color =
        active ? partyConnectionColor(session.connection) : Colors.white;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: () => showPartyEntry(context, ref),
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
            border: Border.all(
              color: active ? Colors.white : Colors.grey.shade300,
              width: 2,
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                active ? Icons.groups : Icons.groups_outlined,
                color: active ? Colors.white : Colors.blueGrey,
                size: 28,
              ),
              // 参加人数バッジ（自分を除くpeers数）
              if (active && session.peers.isNotEmpty)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 16,
                      minHeight: 16,
                    ),
                    child: Text(
                      '${session.peers.length}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 作成/参加ダイアログ
Future<void> _showJoinCreateDialog(
  BuildContext context,
  WidgetRef ref, {
  String? initialCode,
}) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _PartyJoinCreateDialog(initialCode: initialCode),
  );
}

class _PartyJoinCreateDialog extends ConsumerStatefulWidget {
  const _PartyJoinCreateDialog({this.initialCode});

  /// 招待URL経由で起動したときの充填コード
  final String? initialCode;

  @override
  ConsumerState<_PartyJoinCreateDialog> createState() =>
      _PartyJoinCreateDialogState();
}

class _PartyJoinCreateDialogState
    extends ConsumerState<_PartyJoinCreateDialog> {
  final _nameCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  String? _codeError;

  @override
  void initState() {
    super.initState();
    final code = widget.initialCode;
    if (code != null) _codeCtrl.text = code;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  /// 参加ボタン。コード欄は生コード・招待URLのどちらでも受ける。
  void _join() {
    final code = extractRoomCode(_codeCtrl.text);
    if (code == null) {
      setState(() => _codeError = t.party.invalidCode);
      return;
    }
    setState(() => _codeError = null);
    ref
        .read(partySessionProvider.notifier)
        .joinRoom(code: code, name: _nameCtrl.text);
  }

  /// クリップボードからコード/招待URLを貼り付け
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || !mounted) return;
    setState(() {
      _codeCtrl.text = text.trim();
      _codeError = null;
    });
  }

  /// 招待QRをスキャンしてコード欄に充填（カメラのある端末のみ）
  Future<void> _scan() async {
    final code = await _PartyInviteScanDialog.show(context);
    if (code == null || !mounted) return;
    setState(() {
      _codeCtrl.text = code;
      _codeError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(partySessionProvider);
    // 参加成立の「瞬間」だけダイアログを閉じる。
    // active中は members/connection ストリームが更新を流し続けるため、
    // 遷移(false→true)でガードしないと maybePop が連発し、地図ページまで
    // pop してしまう（＝作成後にホーム画面へ戻る不具合）。
    ref.listen(partySessionProvider, (prev, next) {
      final becameActive = next.active && !(prev?.active ?? false);
      if (becameActive && mounted) Navigator.of(context).maybePop();
    });

    return AlertDialog(
      title: Text(t.party.title),
      // 縦に積む要素が多く、ソフトキーボードが出ると高さが足りなくなる。
      // スクロールさせないと RenderFlex overflow でエラー表示になる。
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameCtrl,
              maxLength: 40,
              decoration: InputDecoration(
                labelText: t.party.displayName,
                hintText: t.party.displayNameHint,
              ),
            ),
            const SizedBox(height: 8),
            const Divider(),
            Text(t.party.joinPrompt, style: const TextStyle(fontSize: 12)),
            TextField(
              controller: _codeCtrl,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: t.party.roomCodeLabel,
                hintText: t.party.roomCodeHint,
                errorText: _codeError,
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.paste),
                      tooltip: t.party.paste,
                      onPressed: _paste,
                    ),
                    if (PlatformCapabilities.supportsQrScan)
                      IconButton(
                        icon: const Icon(Icons.qr_code_scanner),
                        tooltip: t.party.scanQr,
                        onPressed: _scan,
                      ),
                  ],
                ),
              ),
            ),
            if (session.error != null) ...[
              const SizedBox(height: 8),
              Text(session.error!, style: const TextStyle(color: Colors.red)),
            ],
            if (session.busy) ...[
              const SizedBox(height: 12),
              const Center(child: CircularProgressIndicator()),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: session.busy ? null : () => Navigator.of(context).pop(),
          child: Text(t.common.cancel),
        ),
        TextButton(
          onPressed: session.busy ? null : _join,
          child: Text(t.party.join),
        ),
        FilledButton(
          onPressed:
              session.busy
                  ? null
                  : () => ref
                      .read(partySessionProvider.notifier)
                      .createRoom(name: _nameCtrl.text),
          child: Text(t.party.createHost),
        ),
      ],
    );
  }
}

/// メンバーのバッテリー残量バッジ
class _BatteryBadge extends StatelessWidget {
  final int percent;
  const _BatteryBadge({required this.percent});

  @override
  Widget build(BuildContext context) {
    final low = percent <= 20;
    final color = low ? Colors.red : Colors.grey.shade600;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          low ? Icons.battery_alert : Icons.battery_full,
          size: 16,
          color: color,
        ),
        const SizedBox(width: 2),
        Text('$percent%', style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }
}

/// 参加中のステータスシート
Future<void> _showStatusSheet(BuildContext context, WidgetRef ref) async {
  await showModalBottomSheet<void>(
    context: context,
    builder: (_) => const _PartyStatusSheet(),
  );
}

class _PartyStatusSheet extends ConsumerWidget {
  const _PartyStatusSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(partySessionProvider);
    // 退出の「瞬間」(true→false)だけシートを閉じる。遷移でガードしないと
    // maybePop が連発して背後の地図ページまで pop する恐れがある。
    ref.listen(partySessionProvider, (prev, next) {
      final becameInactive = !next.active && (prev?.active ?? true);
      if (becameInactive) Navigator.of(context).maybePop();
    });

    if (!session.active) return const SizedBox.shrink();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildRoomHeader(session),
            const SizedBox(height: 4),
            _buildRoomCode(session),
            _buildInviteButtons(context, ref, session),
            const Divider(),
            _buildGhostSwitch(ref, session),
            const Divider(),
            Text(
              t.party.members(count: session.members.length),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            for (final m in session.members)
              _buildMemberTile(context, ref, session, m),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                icon: const Icon(Icons.logout),
                label: Text(
                  session.role == PartyRole.host
                      ? t.party.endHost
                      : t.party.leave,
                ),
                onPressed:
                    () => ref.read(partySessionProvider.notifier).leave(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 「ルームコード」見出しと接続状態のチップ
  Widget _buildRoomHeader(PartySessionState session) => Row(
        children: [
          Text(
            t.party.roomCode,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          Chip(
            backgroundColor: partyConnectionColor(
              session.connection,
            ).withValues(alpha: 0.15),
            label: Text(partyConnectionLabel(session.connection)),
          ),
        ],
      );

  /// ルームコードとコピーボタン
  Widget _buildRoomCode(PartySessionState session) => Row(
        children: [
          SelectableText(
            session.roomCode ?? '',
            style: const TextStyle(
              fontSize: 28,
              letterSpacing: 4,
              fontWeight: FontWeight.bold,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: t.party.copy,
            onPressed:
                () => Clipboard.setData(
                  ClipboardData(text: session.roomCode ?? ''),
                ),
          ),
        ],
      );

  /// 招待の出口: リンクコピーとQR。どちらも招待URL（web参加ページ）を渡す
  Widget _buildInviteButtons(
    BuildContext context,
    WidgetRef ref,
    PartySessionState session,
  ) => Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.link, size: 18),
              label: Text(t.party.copyInviteLink),
              onPressed: () async {
                final code = session.roomCode;
                if (code == null) return;
                await Clipboard.setData(
                  ClipboardData(text: buildInviteUrl(code)),
                );
                ref.read(notificationCenterProvider.notifier).add(
                      title: t.party.inviteLinkCopied,
                      level: NotificationLevel.info,
                    );
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.qr_code, size: 18),
              label: Text(t.party.showQr),
              onPressed: () {
                final code = session.roomCode;
                if (code == null) return;
                _PartyInviteQrDialog.show(context, roomCode: code);
              },
            ),
          ),
        ],
      );

  /// ゴーストモード: 自分の位置を一時的に隠す
  Widget _buildGhostSwitch(WidgetRef ref, PartySessionState session) =>
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        secondary: Icon(
          session.ghost ? Icons.visibility_off : Icons.visibility,
          color: session.ghost ? Colors.deepPurple : null,
        ),
        title: Text(t.party.ghostMode),
        subtitle: Text(
          session.ghost ? t.party.ghostOn : t.party.ghostOff,
          style: const TextStyle(fontSize: 12),
        ),
        value: session.ghost,
        onChanged: (v) => ref.read(partySessionProvider.notifier).setGhost(v),
      );

  /// メンバー1人の行（バッテリーと、host ならキック）
  Widget _buildMemberTile(
    BuildContext context,
    WidgetRef ref,
    PartySessionState session,
    PartyMember m,
  ) {
    final battery = session.peers[m.uid]?.battery;
    // host は他メンバーを退出させられる（RTDBルールが特権を担保）
    final canKick = session.role == PartyRole.host && m.uid != session.selfUid;
    // members の role は本人が書く値なので信じず、meta.hostUid で判定する
    final isHost = m.uid == session.hostUid;
    return ListTile(
      dense: true,
      leading: Icon(
        isHost ? Icons.star : Icons.person,
        color: isHost ? Colors.amber : null,
      ),
      title: Text(m.name),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (battery != null) _BatteryBadge(percent: battery),
          if (canKick)
            IconButton(
              icon: const Icon(Icons.person_remove_outlined, size: 20),
              tooltip: t.party.kick,
              onPressed: () => _confirmKick(context, ref, m),
            ),
        ],
      ),
    );
  }

  /// キックの確認 → 実行
  Future<void> _confirmKick(
    BuildContext context,
    WidgetRef ref,
    PartyMember member,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.party.kick),
        content: Text(t.party.kickConfirm(name: member.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.common.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.party.kick),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(partySessionProvider.notifier).kick(member.uid);
    }
  }
}

/// 招待QRダイアログ。招待URL（web参加ページ）をQRで見せる。
///
/// スマホカメラで読めばブラウザの参加ページが開き、アプリの参加画面の
/// スキャナで読めばコード欄に充填される。どちらの経路でも同じルームに入る。
class _PartyInviteQrDialog extends StatelessWidget {
  const _PartyInviteQrDialog({required this.roomCode});

  final String roomCode;

  static Future<void> show(BuildContext context, {required String roomCode}) {
    return showDialog<void>(
      context: context,
      builder: (_) => _PartyInviteQrDialog(roomCode: roomCode),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inviteUrl = buildInviteUrl(roomCode);
    final maxSide = MediaQuery.of(context).size.shortestSide;
    final qrSize = (maxSide - 120).clamp(160.0, 320.0);

    return AlertDialog(
      title: Text(t.party.inviteQrTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              roomCode,
              style: const TextStyle(
                fontSize: 24,
                letterSpacing: 4,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            // QRは常に白地・黒。端末のダークテーマでも読めるように固定する
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImageView(
                data: inviteUrl,
                size: qrSize,
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              t.party.inviteQrDesc,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            SelectableText(
              inviteUrl,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: inviteUrl));
            if (!context.mounted) return;
            Navigator.pop(context);
          },
          icon: const Icon(Icons.copy, size: 18),
          label: Text(t.party.copyInviteLink),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.common.close),
        ),
      ],
    );
  }
}

/// 招待QRのスキャンダイアログ（カメラのある端末のみ）。
///
/// 招待URL・生コードのどちらのQRでも受け、ルームコードを返す。
class _PartyInviteScanDialog extends StatefulWidget {
  const _PartyInviteScanDialog();

  static Future<String?> show(BuildContext context) {
    return showDialog<String>(
      context: context,
      builder: (_) => const _PartyInviteScanDialog(),
    );
  }

  @override
  State<_PartyInviteScanDialog> createState() =>
      _PartyInviteScanDialogState();
}

class _PartyInviteScanDialogState extends State<_PartyInviteScanDialog> {
  bool _done = false;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;
      final code = extractRoomCode(value);
      if (code != null) {
        _done = true;
        Navigator.pop(context, code);
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.party.scanQr),
      content: SizedBox(
        width: double.maxFinite,
        height: 300,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: MobileScanner(onDetect: _onDetect),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.common.cancel),
        ),
      ],
    );
  }
}

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
/// パーティの共有ピン: 見た目（種類ごとの記号と色）・立てる／書き換えるダイアログ・タップしたときのカード
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../i18n/strings.g.dart';
import '../../../models/party/room_pin.dart';
import '../../../providers/party_providers.dart';
import '../../../providers/room_pin_providers.dart';
import '../../../services/party/room_pin_store.dart';

/// 種類ごとの記号と色（地図の印・ダイアログ・カードで共通）
abstract final class RoomPinStyle {
  static IconData icon(RoomPinType type) => switch (type) {
        RoomPinType.meeting => Icons.flag,
        RoomPinType.hazard => Icons.warning_amber_rounded,
        RoomPinType.work => Icons.construction,
        RoomPinType.note => Icons.sticky_note_2_outlined,
      };

  static Color color(RoomPinType type) => switch (type) {
        RoomPinType.meeting => const Color(0xFF1E88E5),
        RoomPinType.hazard => const Color(0xFFE53935),
        RoomPinType.work => const Color(0xFF2E7D32),
        RoomPinType.note => const Color(0xFF6D4C41),
      };
}

/// 立てる（[initial] があれば書き換える）ダイアログ。キャンセルなら null
Future<(RoomPinType, String)?> showRoomPinDialog(BuildContext context, {RoomPin? initial}) {
  return showDialog<(RoomPinType, String)>(
    context: context,
    builder: (_) => _RoomPinDialog(initial: initial),
  );
}

class _RoomPinDialog extends StatefulWidget {
  const _RoomPinDialog({this.initial});
  final RoomPin? initial;

  @override
  State<_RoomPinDialog> createState() => _RoomPinDialogState();
}

class _RoomPinDialogState extends State<_RoomPinDialog> {
  late RoomPinType _type = widget.initial?.type ?? RoomPinType.meeting;
  late final _text = TextEditingController(text: widget.initial?.text ?? '');

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop((_type, _text.text.trim()));

  @override
  Widget build(BuildContext context) {
    final editing = widget.initial != null;
    return AlertDialog(
      title: Text(editing ? t.party.pins.editTitle : t.party.pins.place),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final type in RoomPinType.values)
                  ChoiceChip(
                    avatar: Icon(RoomPinStyle.icon(type), size: 18, color: RoomPinStyle.color(type)),
                    label: Text(RoomPins.typeLabel(type)),
                    selected: _type == type,
                    onSelected: (_) => setState(() => _type = type),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              maxLength: RoomPin.maxTextLength,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(hintText: t.party.pins.textHint),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.common.cancel)),
        FilledButton(onPressed: _submit, child: Text(editing ? t.party.pins.saveButton : t.party.pins.placeButton)),
      ],
    );
  }
}

/// ピンをタップしたときのカード（誰が・いつ・一言、「ここへ案内」「書き換える」「消す」）
Future<void> showRoomPinCard(BuildContext context, RoomPinView view) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => _RoomPinCard(id: view.pin.id),
  );
}

class _RoomPinCard extends ConsumerWidget {
  const _RoomPinCard({required this.id});
  final String id;

  static String _time(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.month}/${d.day} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(roomPinsProvider);
    // 開いている間に消された・書き換わったら追う
    final view = state.pins.where((v) => v.pin.id == id).firstOrNull;
    if (view == null) return const SizedBox(height: 80);
    final pin = view.pin;
    final members = ref.watch(partySessionProvider.select((s) => s.members));
    final author = pin.author == state.selfUid
        ? t.party.pins.self
        : (members.where((m) => m.uid == pin.author).map((m) => m.name).where((n) => n.isNotEmpty).firstOrNull ??
            t.party.pins.someone);
    final notifier = ref.read(roomPinsProvider.notifier);
    final color = RoomPinStyle.color(pin.type);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(RoomPinStyle.icon(pin.type), color: color),
                const SizedBox(width: 8),
                Text(RoomPins.typeLabel(pin.type), style: Theme.of(context).textTheme.titleMedium?.copyWith(color: color)),
                const Spacer(),
                Text(_time(pin.createdAtMs), style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 4),
            Text(t.party.pins.by(name: author), style: Theme.of(context).textTheme.bodySmall),
            if (pin.text.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(pin.text),
            ],
            if (view.pending) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.cloud_off, size: 16, color: Colors.grey),
                  const SizedBox(width: 4),
                  Expanded(child: Text(t.party.pins.pending, style: Theme.of(context).textTheme.bodySmall)),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.near_me),
                  label: Text(t.guidance.action),
                  onPressed: () {
                    notifier.guideTo(pin);
                    Navigator.of(context).pop();
                  },
                ),
                if (state.canEdit(pin)) ...[
                  OutlinedButton.icon(
                    icon: const Icon(Icons.edit),
                    label: Text(t.party.pins.edit),
                    onPressed: () async {
                      final r = await showRoomPinDialog(context, initial: pin);
                      if (r == null) return;
                      await notifier.edit(pin, type: r.$1, text: r.$2);
                    },
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.delete_outline),
                    label: Text(t.party.pins.delete),
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          content: Text(t.party.pins.deleteConfirm),
                          actions: [
                            TextButton(onPressed: () => Navigator.of(c).pop(false), child: Text(t.common.cancel)),
                            FilledButton(onPressed: () => Navigator.of(c).pop(true), child: Text(t.party.pins.delete)),
                          ],
                        ),
                      );
                      if (ok != true) return;
                      await notifier.delete(pin);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

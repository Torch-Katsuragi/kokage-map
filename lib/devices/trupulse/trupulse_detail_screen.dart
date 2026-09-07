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
/// TruPulse 詳細操作画面
///
/// デバイス情報表示、キャリブレーション手順ガイド、モード切替、リモート操作を提供。
/// シリアルコマンドは TruPulse 360R マニュアル Section 8 に基づく:
///   $GO, $ST, $DU, $AU, $MM, $ID のみ。
/// キャリブレーション・ターゲットモード・偏差は本体操作のみ（シリアル不可）。
library;

import 'dart:async';
import 'package:flutter/material.dart';
import '../../widgets/settings_widgets.dart';
import 'trupulse_calibration_guide.dart';
import 'trupulse_service.dart';

class TruPulseDetailScreen extends StatefulWidget {
  final TruPulseService service;
  const TruPulseDetailScreen({super.key, required this.service});

  @override
  State<TruPulseDetailScreen> createState() => _TruPulseDetailScreenState();
}

class _TruPulseDetailScreenState extends State<TruPulseDetailScreen> {
  TruPulseService get _svc => widget.service;

  String? _deviceId;
  bool _loadingInfo = false;
  int _measurementMode = 0; // HD default
  StreamSubscription<void>? _logSub;

  @override
  void initState() {
    super.initState();
    _fetchDeviceInfo();
    _logSub = _svc.logStream.listen((_) => _refreshLog());
  }

  @override
  void dispose() {
    _logSub?.cancel();
    super.dispose();
  }

  void _refreshLog() {
    if (mounted) setState(() {});
  }

  Future<void> _fetchDeviceInfo() async {
    setState(() => _loadingInfo = true);
    try {
      _deviceId = await _svc.queryId();
    } on TimeoutException {
      // device didn't respond
    }
    if (mounted) setState(() => _loadingInfo = false);
  }

  void _openCalGuide(CalibrationType type) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            TruPulseCalibrationGuide(service: _svc, type: type),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connected = _svc.isConnected;

    return SettingsScaffold(
      title: _svc.deviceTypeName,
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh Info',
          onPressed: connected ? _fetchDeviceInfo : null,
        ),
      ],
      isLoading: _loadingInfo,
      body: SettingsBody(
        sections: [
          _buildInfoSection(),
          _buildTerminalSection(),
          _buildCalibrationSection(connected),
          _buildMeasurementModeSection(connected),
          _buildRemoteSection(connected),
          _buildConnectionSection(connected),
        ],
      ),
    );
  }

  // ========== Device Info ==========

  Widget _buildInfoSection() {
    return SettingsSection(
      title: 'Device Info',
      icon: Icons.info_outline,
      iconColor: Colors.blue,
      collapsible: true,
      children: [
        _infoTile('Device', _svc.connectedDevice?.name ?? '-'),
        _infoTile('Address', _svc.connectedDevice?.address ?? '-'),
        _infoTile('ID', _deviceId ?? '-'),
        _infoTile('Measurements', '${_svc.measurementCount}'),
      ],
    );
  }

  // ========== Terminal (serial log) ==========

  final _cmdController = TextEditingController();

  Widget _buildTerminalSection() {
    final entries = _svc.log;
    final connected = _svc.isConnected;
    return SettingsSection(
      title: 'Terminal',
      icon: Icons.terminal,
      iconColor: Colors.grey,
      collapsible: true,
      trailing: entries.isEmpty
          ? null
          : IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: 'Clear',
              onPressed: () => setState(() => _svc.clearLog()),
              visualDensity: VisualDensity.compact,
            ),
      children: [
        Container(
          width: double.infinity,
          height: 200,
          decoration: const BoxDecoration(
            color: Color(0xFF1E1E1E),
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(8),
              topRight: Radius.circular(8),
            ),
          ),
          child: entries.isEmpty
              ? const Center(
                  child: Text('No data yet',
                      style: TextStyle(
                          color: Colors.grey,
                          fontFamily: 'monospace',
                          fontSize: 12)),
                )
              : _TerminalView(entries: entries),
        ),
        Container(
          decoration: const BoxDecoration(
            color: Color(0xFF252526),
            borderRadius: BorderRadius.only(
              bottomLeft: Radius.circular(8),
              bottomRight: Radius.circular(8),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              const Text('\$ ',
                  style: TextStyle(
                      color: Color(0xFF569CD6),
                      fontFamily: 'monospace',
                      fontSize: 13,
                      fontWeight: FontWeight.bold)),
              Expanded(
                child: TextField(
                  controller: _cmdController,
                  enabled: connected,
                  style: const TextStyle(
                      color: Color(0xFFD4D4D4),
                      fontFamily: 'monospace',
                      fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: 'GO, ID, MM,0 ...',
                    hintStyle: TextStyle(color: Color(0xFF555555)),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 8),
                  ),
                  onSubmitted: _sendRawCommand,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send, size: 18),
                color: const Color(0xFF569CD6),
                visualDensity: VisualDensity.compact,
                onPressed: connected
                    ? () => _sendRawCommand(_cmdController.text)
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _sendRawCommand(String text) {
    final cmd = text.trim();
    if (cmd.isEmpty) return;
    _svc.sendCommand(cmd);
    _cmdController.clear();
  }

  // ========== Calibration (guide only — no serial command) ==========

  Widget _buildCalibrationSection(bool connected) {
    return SettingsSection(
      title: 'Calibration',
      icon: Icons.tune,
      iconColor: Colors.orange,
      collapsible: true,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            'Calibration is performed on the device itself. '
            'These guides walk you through each step.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        _guideTile(
          icon: Icons.screen_rotation,
          title: 'Tilt Calibration',
          subtitle:
              'Corrects the tilt sensor. '
              'Menu: DOWN 4s → "inC" → FIRE → "YES CAL" → FIRE. '
              '8 positions on a flat surface.',
          onTap: () => _openCalGuide(CalibrationType.tilt),
        ),
        _guideTile(
          icon: Icons.explore,
          title: 'Compass Calibration',
          subtitle:
              'Aligns the compass sensor. '
              'Menu: DOWN 4s → "H_Ang" → FIRE → "HACAL" → FIRE → "YES CAL" → FIRE. '
              'Outdoors, 8 positions facing North.',
          onTap: () => _openCalGuide(CalibrationType.compass),
        ),
      ],
    );
  }

  // ========== Measurement Mode ($MM) ==========

  Widget _buildMeasurementModeSection(bool connected) {
    return SettingsSection(
      title: 'Measurement Mode',
      icon: Icons.straighten,
      iconColor: Colors.teal,
      collapsible: true,
      initiallyExpanded: false,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            'Choose what value the device displays and returns '
            'when you take a measurement.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        for (final mm in _MeasurementMode.values)
          _selectableTile(
            icon: mm.icon,
            title: mm.label,
            subtitle: mm.description,
            selected: _measurementMode == mm.index,
            onTap: connected
                ? () {
                    setState(() => _measurementMode = mm.index);
                    _svc.setMeasurementMode(mm.index);
                  }
                : null,
          ),
      ],
    );
  }

  // ========== Remote Control ($GO / $ST) ==========

  Widget _buildRemoteSection(bool connected) {
    return SettingsSection(
      title: 'Remote Control',
      icon: Icons.play_circle_outline,
      iconColor: Colors.green,
      collapsible: true,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            'Trigger measurement remotely from the app '
            'without pressing the device button.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: connected ? _svc.remoteFire : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Fire'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: connected ? _svc.stopMeasurement : null,
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ========== Connection ==========

  Widget _buildConnectionSection(bool connected) {
    return SettingsSection(
      title: 'Connection',
      icon: Icons.bluetooth,
      collapsible: true,
      initiallyExpanded: false,
      children: [
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: connected
                ? () async {
                    await _svc.disconnect();
                    if (mounted) Navigator.pop(context);
                  }
                : null,
            icon: const Icon(Icons.bluetooth_disabled),
            label: const Text('Disconnect'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
          ),
        ),
      ],
    );
  }

  // ========== Shared builders ==========

  Widget _infoTile(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label,
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _guideTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 4),
      child: ListTile(
        leading: Icon(icon, size: 22),
        title: Text(title, style: const TextStyle(fontSize: 14)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
        dense: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }

  Widget _selectableTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback? onTap,
  }) {
    return Card(
      elevation: selected ? 2 : 0,
      color: selected
          ? Theme.of(context).colorScheme.primaryContainer
          : null,
      margin: const EdgeInsets.only(bottom: 4),
      child: ListTile(
        leading: Icon(icon, size: 22),
        title: Text(title, style: const TextStyle(fontSize: 14)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        trailing: selected
            ? Icon(Icons.check_circle,
                color: Theme.of(context).colorScheme.primary)
            : null,
        onTap: onTap,
        dense: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}

// ========== Terminal view ==========

class _TerminalView extends StatefulWidget {
  final List<SerialLogEntry> entries;
  const _TerminalView({required this.entries});

  @override
  State<_TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<_TerminalView> {
  final _scrollController = ScrollController();

  @override
  void didUpdateWidget(_TerminalView old) {
    super.didUpdateWidget(old);
    if (widget.entries.length != old.entries.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(
              _scrollController.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(8),
      itemCount: widget.entries.length,
      itemBuilder: (_, i) {
        final e = widget.entries[i];
        final isTx = e.direction == SerialDirection.tx;
        final ts = '${e.timestamp.hour.toString().padLeft(2, '0')}:'
            '${e.timestamp.minute.toString().padLeft(2, '0')}:'
            '${e.timestamp.second.toString().padLeft(2, '0')}';
        return Text.rich(
          TextSpan(children: [
            TextSpan(
              text: '$ts ',
              style: const TextStyle(color: Color(0xFF666666)),
            ),
            TextSpan(
              text: isTx ? 'TX › ' : 'RX ‹ ',
              style: TextStyle(
                color: isTx ? const Color(0xFF569CD6) : const Color(0xFF4EC9B0),
                fontWeight: FontWeight.bold,
              ),
            ),
            TextSpan(
              text: e.text,
              style: TextStyle(
                color: isTx ? const Color(0xFF9CDCFE) : const Color(0xFFCE9178),
              ),
            ),
          ]),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
        );
      },
    );
  }
}

// ========== Measurement mode definitions ==========
// Index matches $MM,n values from TruPulse 360R manual Section 8

enum _MeasurementMode {
  hd(
    icon: Icons.straighten,
    label: 'Horizontal Distance (HD)',
    description: 'Flat map distance to the target, ignoring elevation. '
        'Most common for surveying.',
  ),
  vd(
    icon: Icons.height,
    label: 'Vertical Distance (VD)',
    description: 'Height difference between device and target. '
        'Positive = target is above, negative = below.',
  ),
  sd(
    icon: Icons.trending_up,
    label: 'Slope Distance (SD)',
    description: 'Direct line-of-sight distance from device to target. '
        'The raw distance the laser measures.',
  ),
  inc(
    icon: Icons.rotate_right,
    label: 'Inclination (INC)',
    description: 'Vertical angle to the target in degrees. '
        '0° = level, positive = uphill, negative = downhill.',
  ),
  ht(
    icon: Icons.swap_vert,
    label: 'Height (HT)',
    description: 'Measures height of an object by shooting its top and base. '
        'Requires two measurements.',
  ),
  az(
    icon: Icons.explore,
    label: 'Azimuth (AZ)',
    description: 'Compass bearing to the target (0°–360°). '
        'North = 0°, East = 90°, South = 180°, West = 270°.',
  ),
  ml(
    icon: Icons.linear_scale,
    label: 'Missing Line (ML)',
    description: 'Distance between two remote points. '
        'Shoot both points from the same position to calculate.',
  );

  final IconData icon;
  final String label;
  final String description;
  const _MeasurementMode({
    required this.icon,
    required this.label,
    required this.description,
  });
}

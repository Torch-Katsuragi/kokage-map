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
/// TruPulse キャリブレーション ガイド画面
///
/// デバイス本体で実行するキャリブレーション手順を
/// ステップバイステップで案内する（アプリからのコマンド送信なし）。
/// 手順は TruPulse 360R マニュアル Section 4 に基づく。
library;

import 'package:flutter/material.dart';
import '../../i18n/strings.g.dart';
import 'trupulse_service.dart';

enum CalibrationType { tilt, compass }

class TruPulseCalibrationGuide extends StatefulWidget {
  final TruPulseService service;
  final CalibrationType type;

  const TruPulseCalibrationGuide({
    super.key,
    required this.service,
    required this.type,
  });

  @override
  State<TruPulseCalibrationGuide> createState() =>
      _TruPulseCalibrationGuideState();
}

class _TruPulseCalibrationGuideState extends State<TruPulseCalibrationGuide> {
  bool get _isTilt => widget.type == CalibrationType.tilt;
  int _currentStep = 0;

  List<_Step> get _steps => _isTilt ? _tiltSteps : _compassSteps;

  // ======== Tilt Cal: マニュアル p.24-26 ========

  List<_Step> get _tiltSteps {
    final g = t.trupulse.guide.tilt;
    return [
      _Step(icon: Icons.settings, title: g.step1Title, detail: g.step1Detail),
      _Step(icon: Icons.phone_android, title: g.step2Title, detail: g.step2Detail),
      _Step(icon: Icons.looks_one, title: g.step3Title, detail: g.step3Detail),
      _Step(icon: Icons.looks_two, title: g.step4Title, detail: g.step4Detail),
      _Step(icon: Icons.looks_3, title: g.step5Title, detail: g.step5Detail),
      _Step(icon: Icons.looks_4, title: g.step6Title, detail: g.step6Detail),
      _Step(icon: Icons.looks_5, title: g.step7Title, detail: g.step7Detail),
      _Step(icon: Icons.check_circle_outline, title: g.step8Title, detail: g.step8Detail),
    ];
  }

  // ======== Compass Cal: マニュアル p.32-34 ========

  List<_Step> get _compassSteps {
    final g = t.trupulse.guide.compass;
    return [
      _Step(icon: Icons.warning_amber, title: g.step1Title, detail: g.step1Detail),
      _Step(icon: Icons.settings, title: g.step2Title, detail: g.step2Detail),
      _Step(icon: Icons.looks_one, title: g.step3Title, detail: g.step3Detail),
      _Step(icon: Icons.looks_two, title: g.step4Title, detail: g.step4Detail),
      _Step(icon: Icons.looks_3, title: g.step5Title, detail: g.step5Detail),
      _Step(icon: Icons.looks_4, title: g.step6Title, detail: g.step6Detail),
      _Step(icon: Icons.looks_5, title: g.step7Title, detail: g.step7Detail),
      _Step(icon: Icons.check_circle_outline, title: g.step8Title, detail: g.step8Detail),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _isTilt
        ? t.trupulse.detail.tiltCalibration
        : t.trupulse.detail.compassCalibration;
    final step = _steps[_currentStep];
    final isFirst = _currentStep == 0;
    final isLast = _currentStep == _steps.length - 1;

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
            value: (_currentStep + 1) / _steps.length,
          ),
        ),
      ),
      body: Column(
        children: [
          // Step indicator
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Text(
                    '${_currentStep + 1}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.trupulse.guide.stepOf(current: _currentStep + 1, total: _steps.length),
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        step.title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(step.icon, size: 32, color: theme.colorScheme.primary),
              ],
            ),
          ),

          const Divider(height: 1),

          // Step detail
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      step.detail,
                      style: const TextStyle(fontSize: 14, height: 1.6),
                    ),
                  ),
                  // Overview: all steps (mini list)
                  const SizedBox(height: 24),
                  Text(
                    t.trupulse.guide.allSteps,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (int i = 0; i < _steps.length; i++)
                    _miniStepRow(i, theme),
                ],
              ),
            ),
          ),

          // Navigation
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                if (!isFirst)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          setState(() => _currentStep--),
                      icon: const Icon(Icons.arrow_back),
                      label: Text(t.trupulse.guide.back),
                    ),
                  ),
                if (!isFirst && !isLast) const SizedBox(width: 12),
                if (!isLast)
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () =>
                          setState(() => _currentStep++),
                      icon: const Icon(Icons.arrow_forward),
                      label: Text(t.trupulse.guide.next),
                    ),
                  ),
                if (isLast)
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.check),
                      label: Text(t.trupulse.guide.done),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniStepRow(int index, ThemeData theme) {
    final isCurrent = index == _currentStep;
    final isPast = index < _currentStep;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: () => setState(() => _currentStep = index),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          child: Row(
            children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: isCurrent
                    ? theme.colorScheme.primary
                    : isPast
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.surfaceContainerHighest,
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isCurrent
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _steps[index].title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isCurrent ? FontWeight.w600 : null,
                    color: isCurrent
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (isPast)
                Icon(Icons.check, size: 16,
                    color: theme.colorScheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

class _Step {
  final IconData icon;
  final String title;
  final String detail;
  const _Step({required this.icon, required this.title, required this.detail});
}

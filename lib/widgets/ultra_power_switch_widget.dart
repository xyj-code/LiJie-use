import 'package:flutter/material.dart';

import '../services/power_saving_manager.dart';

class UltraPowerSwitchWidget extends StatefulWidget {
  const UltraPowerSwitchWidget({super.key, this.manager});

  final PowerSavingManager? manager;

  PowerSavingManager get effectiveManager => manager ?? powerSavingManager;

  @override
  State<UltraPowerSwitchWidget> createState() => _UltraPowerSwitchWidgetState();
}

class _UltraPowerSwitchWidgetState extends State<UltraPowerSwitchWidget> {
  bool _isToggling = false;

  Future<void> _handleToggle(bool value) async {
    if (_isToggling) {
      return;
    }

    final manager = widget.effectiveManager;

    setState(() {
      _isToggling = true;
    });

    try {
      await manager.setUltraPowerSavingMode(value);
      if (!mounted) {
        return;
      }

      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();

      if (value) {
        messenger.showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF1A0F0C),
            content: Text('☢️ 已进入极限求生模式：已关闭 AI，降低蓝牙频率，屏幕亮度锁定，预计续航延长 300%'),
          ),
        );
      } else {
        messenger.showSnackBar(
          const SnackBar(content: Text('已退出绝境省电模式，恢复标准搜救性能配置。')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isToggling = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final manager = widget.effectiveManager;

    return AnimatedBuilder(
      animation: manager,
      builder: (context, _) {
        final isActive = manager.isUltraPowerSavingMode;
        final gpsPolicy = manager.getGpsUpdatePolicy();
        final bleSeconds =
            manager.getBleAdvertiseInterval().inMilliseconds / 1000;
        final warningColor = isActive
            ? const Color(0xFFE85C4A)
            : const Color(0xFFC7921F);

        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isActive
                  ? const [Color(0xFF090909), Color(0xFF1B110F)]
                  : const [Color(0xFF111111), Color(0xFF1E1A14)],
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: warningColor, width: 1.3),
            boxShadow: [
              BoxShadow(
                color: warningColor.withValues(alpha: isActive ? 0.24 : 0.12),
                blurRadius: 22,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: warningColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      isActive
                          ? Icons.battery_alert_rounded
                          : Icons.offline_bolt_rounded,
                      color: warningColor,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '绝境省电模式',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isActive
                              ? '亮度锁死到 5%，蓝牙降频，GPS 改为 5 分钟单次缓存'
                              : '牺牲 AI 与定位实时性，尽可能换取更长生存续航',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: const Color(0xFFD6CDBF),
                                height: 1.35,
                              ),
                        ),
                      ],
                    ),
                  ),
                  Switch.adaptive(
                    value: isActive,
                    activeThumbColor: const Color(0xFF111111),
                    activeTrackColor: const Color(0xFFE85C4A),
                    inactiveThumbColor: const Color(0xFFF2C15A),
                    inactiveTrackColor: const Color(0xFF4C422E),
                    onChanged: _isToggling ? null : _handleToggle,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _MetricChip(
                    label: 'BLE',
                    value: '${bleSeconds.toStringAsFixed(0)}s 心跳',
                    tone: warningColor,
                  ),
                  _MetricChip(
                    label: 'GPS',
                    value: gpsPolicy.description,
                    tone: const Color(0xFFF2C15A),
                  ),
                  _MetricChip(
                    label: 'AI',
                    value: manager.shouldEnableLocalAi() ? '在线' : '关闭',
                    tone: manager.shouldEnableLocalAi()
                        ? const Color(0xFF8AC67D)
                        : const Color(0xFFE85C4A),
                  ),
                ],
              ),
              if (manager.lastBrightnessError != null) ...[
                const SizedBox(height: 12),
                Text(
                  '系统限制了亮度锁定：${manager.lastBrightnessError}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFFE6D8C6),
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.label,
    required this.value,
    required this.tone,
  });

  final String label;
  final String value;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tone.withValues(alpha: 0.45)),
      ),
      child: RichText(
        text: TextSpan(
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: Colors.white),
          children: [
            TextSpan(
              text: '$label ',
              style: TextStyle(color: tone, fontWeight: FontWeight.w900),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(color: Color(0xFFF6EFE4)),
            ),
          ],
        ),
      ),
    );
  }
}

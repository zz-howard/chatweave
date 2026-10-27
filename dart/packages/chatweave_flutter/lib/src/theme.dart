import 'package:flutter/material.dart';

@immutable
class ChatWeaveThemeData {
  const ChatWeaveThemeData({
    required this.brightness,
    required this.surface,
    required this.onSurface,
    required this.muted,
    required this.outline,
    required this.accent,
    required this.onAccent,
    required this.warning,
    required this.critical,
    required this.chartPalette,
    this.body = const TextStyle(fontSize: 16, height: 1.5),
    this.caption = const TextStyle(fontSize: 14, height: 1.4),
    this.title = const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
    this.numeric = const TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
    this.spacing = 12,
    this.radius = 12,
  });
  factory ChatWeaveThemeData.neutralLight() => const ChatWeaveThemeData(
        brightness: Brightness.light,
        surface: Color(0xFFFFFFFF),
        onSurface: Color(0xFF17191C),
        muted: Color(0xFF50545A),
        outline: Color(0xFF73777D),
        accent: Color(0xFF174EA6),
        onAccent: Color(0xFFFFFFFF),
        warning: Color(0xFF704600),
        critical: Color(0xFF9C2020),
        chartPalette: [
          Color(0xFF174EA6),
          Color(0xFF8B3300),
          Color(0xFF5D3296),
          Color(0xFF006354),
          Color(0xFF8C2259),
          Color(0xFF50545A),
        ],
      );
  factory ChatWeaveThemeData.neutralDark() => const ChatWeaveThemeData(
        brightness: Brightness.dark,
        surface: Color(0xFF17191C),
        onSurface: Color(0xFFF2F3F5),
        muted: Color(0xFFBBC0C7),
        outline: Color(0xFF91969D),
        accent: Color(0xFFA9C7FF),
        onAccent: Color(0xFF102544),
        warning: Color(0xFFFFCF88),
        critical: Color(0xFFFFB4B4),
        chartPalette: [
          Color(0xFFA9C7FF),
          Color(0xFFFFBE91),
          Color(0xFFD8B8FF),
          Color(0xFF8DDBCB),
          Color(0xFFFFB0D4),
          Color(0xFFBBC0C7),
        ],
      );
  final Brightness brightness;
  final Color surface;
  final Color onSurface;
  final Color muted;
  final Color outline;
  final Color accent;
  final Color onAccent;
  final Color warning;
  final Color critical;
  final List<Color> chartPalette;
  final TextStyle body;
  final TextStyle caption;
  final TextStyle title;
  final TextStyle numeric;
  final double spacing;
  final double radius;
}

class ChatWeaveTheme extends InheritedWidget {
  const ChatWeaveTheme({super.key, required this.data, required super.child});
  final ChatWeaveThemeData data;
  static ChatWeaveThemeData of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatWeaveTheme>()?.data ??
      ChatWeaveThemeData.neutralLight();
  @override
  bool updateShouldNotify(ChatWeaveTheme oldWidget) => data != oldWidget.data;
}

double contrastRatio(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  return (first > second ? first + 0.05 : second + 0.05) /
      (first > second ? second + 0.05 : first + 0.05);
}

/// Control colors are semantic tokens, including disabled readable labels.
class ChatWeaveTextButton extends StatelessWidget {
  const ChatWeaveTextButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.style,
  });
  final VoidCallback? onPressed;
  final Widget child;
  final ButtonStyle? style;
  @override
  Widget build(BuildContext context) {
    final theme = ChatWeaveTheme.of(context);
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: theme.accent,
        disabledForegroundColor: theme.muted,
        backgroundColor: theme.surface,
        minimumSize: const Size(48, 48),
        textStyle: theme.body,
      ).merge(style),
      child: child,
    );
  }
}

class ChatWeaveControlIcon extends StatelessWidget {
  const ChatWeaveControlIcon({super.key, this.close = false})
      : dropdown = false;

  /// Downward caret for select fields; painted, so it never needs an icon font.
  const ChatWeaveControlIcon.dropdown({super.key})
      : close = false,
        dropdown = true;
  final bool close;
  final bool dropdown;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CustomPaint(
            painter: _ControlIconPainter(
              close,
              ChatWeaveTheme.of(context).onSurface,
              dropdown: dropdown,
            ),
          ),
        ),
      );
}

class _ControlIconPainter extends CustomPainter {
  const _ControlIconPainter(this.close, this.color, {this.dropdown = false});
  final bool close;
  final Color color;
  final bool dropdown;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2;
    if (dropdown) {
      final path = Path()
        ..moveTo(7, 10)
        ..lineTo(17, 10)
        ..lineTo(12, 15)
        ..close();
      canvas.drawPath(path, paint);
    } else if (close) {
      canvas.drawLine(const Offset(6, 6), const Offset(18, 18), paint);
      canvas.drawLine(const Offset(18, 6), const Offset(6, 18), paint);
    } else {
      final path = Path()
        ..moveTo(3, 3)
        ..lineTo(22, 12)
        ..lineTo(3, 21)
        ..lineTo(7, 12)
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_ControlIconPainter oldDelegate) =>
      oldDelegate.close != close ||
      oldDelegate.dropdown != dropdown ||
      oldDelegate.color != color;
}

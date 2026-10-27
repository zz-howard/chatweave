import 'package:flutter/widgets.dart';

/// Defaults execute their own parsing, formatting and layout preparation here,
/// including later state/stream/layout builder invocations.
Widget guardedDefaultBuild(BuildContext context, Widget Function() builder,
    {Widget? emergencyFallback}) {
  try {
    return builder();
  } catch (error) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<DefaultBuildScope>();
    scope?.report(error);
    return emergencyFallback ?? scope?.fallback() ?? const Text('此内容无法显示');
  }
}

class DefaultBuildScope extends InheritedWidget {
  const DefaultBuildScope(
      {super.key,
      required this.report,
      required this.fallback,
      required super.child});
  final void Function(Object) report;
  final Widget Function() fallback;
  @override
  bool updateShouldNotify(DefaultBuildScope oldWidget) => true;
}

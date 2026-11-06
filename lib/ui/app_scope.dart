import 'package:flutter/widgets.dart';

import '../core_bridge.dart';

enum FormFactor { phone, pad, window, television }

const televisionInset = 58.0;

bool get desktopPlatform => false;

class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.repository,
    this.formFactor,
    this.systemColorAvailable = false,
    this.version = '',
    required super.child,
  });
  final AppRepository repository;
  final FormFactor? formFactor;
  final bool systemColorAvailable;
  final String version;

  bool get television => formFactor == FormFactor.television;

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  static FormFactor formFactorOf(BuildContext context) {
    if (of(context).formFactor case final form?) return form;
    final size = MediaQuery.sizeOf(context);
    return size.shortestSide >= 600 ? FormFactor.pad : FormFactor.phone;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      repository != oldWidget.repository ||
      formFactor != oldWidget.formFactor ||
      systemColorAvailable != oldWidget.systemColorAvailable ||
      version != oldWidget.version;
}

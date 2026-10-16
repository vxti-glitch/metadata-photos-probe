import 'package:flutter/material.dart';

import 'editor_app.dart';
import 'license_gate.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MetadataEditorApp(
      applicationBuilder: (context, child) => ZlarpLicenseGate(child: child!),
    ),
  );
}

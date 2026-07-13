import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves the linux libsplitcore.so built by splitcore/build/build_linux.sh,
/// relative to this package's location in the slice_pay monorepo.
String resolveLinuxLibPath() {
  final packageDir = Directory.current.path;
  final path = p.normalize(
    p.join(packageDir, '..', 'splitcore', 'build', 'out', 'linux', 'libsplitcore.so'),
  );
  if (!File(path).existsSync()) {
    throw StateError(
      'libsplitcore.so not found at $path — run splitcore/build/build_linux.sh first',
    );
  }
  return path;
}

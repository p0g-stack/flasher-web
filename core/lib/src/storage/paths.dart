/// Path rules shared by every [Workspace] implementation.
///
/// A workspace path is relative, `/`-separated and made of ordinary names.
/// This normalizer is deliberately strict: an absolute path, a backslash, a
/// drive letter or a `.`/`..` component is an error rather than something to
/// resolve, so a caller can never escape the workspace root by accident.
library;

const String workspaceSeparator = '/';

/// Returns [path] with empty trailing separators removed, or throws
/// [ArgumentError] when it is not a safe workspace-relative path.
///
/// [allowRoot] permits `''` and `'.'` for operations on the workspace root
/// itself (listing, existence checks).
String normalizeWorkspacePath(String path, {bool allowRoot = false}) {
  if (path.contains('\u0000')) {
    throw ArgumentError.value(path, 'path', 'must not contain NUL');
  }
  if (path.contains('\\')) {
    throw ArgumentError.value(
      path,
      'path',
      'must use / as the separator, not \\',
    );
  }
  if (path.startsWith(workspaceSeparator)) {
    throw ArgumentError.value(path, 'path', 'must be relative');
  }
  if (RegExp(r'^[A-Za-z]:').hasMatch(path)) {
    throw ArgumentError.value(path, 'path', 'must not start with a drive');
  }

  var trimmed = path;
  while (trimmed.endsWith(workspaceSeparator)) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  if (trimmed.isEmpty || trimmed == '.') {
    if (allowRoot) return '';
    throw ArgumentError.value(path, 'path', 'must name an entry');
  }

  final parts = trimmed.split(workspaceSeparator);
  for (final part in parts) {
    if (part.isEmpty) {
      throw ArgumentError.value(path, 'path', 'must not contain //');
    }
    if (part == '.' || part == '..') {
      throw ArgumentError.value(path, 'path', 'must not contain . or ..');
    }
  }
  return parts.join(workspaceSeparator);
}

/// Joins an already-normalized directory path (possibly `''`) and a name.
String joinWorkspacePath(String dir, String name) =>
    dir.isEmpty ? name : '$dir$workspaceSeparator$name';

/// The parent of a normalized path, or `''` for a top-level entry.
String parentWorkspacePath(String path) {
  final at = path.lastIndexOf(workspaceSeparator);
  return at < 0 ? '' : path.substring(0, at);
}

/// The final name of a normalized path.
String baseWorkspacePath(String path) {
  final at = path.lastIndexOf(workspaceSeparator);
  return at < 0 ? path : path.substring(at + 1);
}

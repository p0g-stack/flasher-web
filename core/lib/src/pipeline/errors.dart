/// Build failures, with upstream's wording.
///
/// Port of `BuildError` and `Cancelled` in `flasher_builder/backend.py`.
library;

/// A build cannot continue; [message] is shown to the user as upstream shows
/// its `BuildError` text.
final class BuildException implements Exception {
  const BuildException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The caller cancelled the build. The job folder is removed.
final class CancelledException extends BuildException {
  const CancelledException([super.message = 'Task cancelled.']);
}

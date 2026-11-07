/// Errors that leave the hosted server with a stable public code.
library;

final class HostedException implements Exception {
  const HostedException(
    this.code,
    this.message, {
    this.status = 400,
  });

  /// Stable machine code; never contains user input or paths.
  final String code;

  /// Public message. It must be safe to return to a caller.
  final String message;

  /// HTTP status the API maps this error to.
  final int status;

  @override
  String toString() => '$code: $message';
}

final class HostedInternalException extends HostedException {
  const HostedInternalException(super.code, super.message)
    : super(status: 500);
}

/// The catalog release id no longer names the same immutable release.
final class CatalogChangedException extends HostedException {
  const CatalogChangedException()
    : super(
        'catalog_entry_changed',
        'This catalog release changed upstream. Retry with a fresh catalog, '
        'or ask the operator to clear the cached OTA entry.',
        status: 409,
      );
}

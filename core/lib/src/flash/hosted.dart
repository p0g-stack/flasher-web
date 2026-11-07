/// Flashing a hosted, catalog-owned flasher ZIP without copying it locally.
///
/// A hosted build is opened through same-origin HTTP byte ranges. The service
/// never receives a URL: it receives a capability job id plus the immutable
/// digest and length the hosted result was published with. Those values, the
/// manifest hash and the ZIP central directory are bound into the confirmation
/// ticket, and every range is checked against a strong ETag equal to the
/// artifact SHA-256. A changed artifact is refused before a device write.
///
/// A retention lease pins the server-side job while it is being inspected and
/// flashed. Leases are renewed for a bounded period and released as soon as
/// the service stops reading; the full ZIP is never stored in OPFS or memory.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:device_link/device_link.dart';

import '../native/native.dart';
import '../rust/api/zip.dart' as rust_zip;
import '../storage/storage.dart';
import 'hosted_transport.dart';
import 'model.dart';
import 'package_index.dart';
import 'package_source.dart';

/// The exact, immutable identity of one hosted artifact.
final class HostedArtifact {
  const HostedArtifact({
    required this.jobId,
    required this.sha256,
    required this.bytes,
    this.etag,
  });

  /// Capability ids are opaque and URL-safe; 16–128 characters keeps every
  /// server path valid and rules out traversal, query and fragment syntax.
  static final RegExp jobIdPattern = RegExp(r'^[A-Za-z0-9_-]{16,128}$');
  static final RegExp _sha256Pattern = RegExp(r'^[0-9a-fA-F]{64}$');

  /// The largest ZIP the app will plan. It is a bound, not an expectation:
  /// only the ranges the plan reads are transferred.
  static const int maxBytes = 64 * 1024 * 1024 * 1024;

  static const Set<String> _allowedKeys = {'jobId', 'sha256', 'bytes'};

  /// Parses a service request's `hosted` map.
  ///
  /// Anything that could name an arbitrary location or an upload is refused:
  /// the only accepted fields are the capability id, digest and length.
  static HostedArtifact? tryParse(Object? value) {
    if (value == null) return null;
    if (value is! Map) {
      throw const FlashException('hosted must be a map.');
    }
    for (final key in value.keys) {
      if (!_allowedKeys.contains(key)) {
        throw FlashException(
          'Unrecognized hosted field "$key". Hosted flashes name a capability '
          'job id, sha256 and bytes only; URLs and uploads are refused.',
        );
      }
    }
    final jobId = value['jobId'];
    if (jobId is! String || !jobIdPattern.hasMatch(jobId)) {
      throw const FlashException(
        'hosted.jobId must be a URL-safe 16–128 character capability id.',
      );
    }
    final digest = value['sha256'];
    if (digest is! String || !_sha256Pattern.hasMatch(digest)) {
      throw const FlashException('hosted.sha256 must be a SHA-256 hex digest.');
    }
    final bytes = _positiveInt(value['bytes']);
    if (bytes == null || bytes > maxBytes) {
      throw FlashException(
        'hosted.bytes must be an artifact length between 1 and $maxBytes.',
      );
    }
    return HostedArtifact(
      jobId: jobId,
      sha256: digest.toLowerCase(),
      bytes: bytes,
    );
  }

  final String jobId;

  /// The artifact's SHA-256, which is also the strong ETag a hosted server
  /// must serve for every range.
  final String sha256;

  /// The exact ZIP length.
  final int bytes;

  /// Observed ETag, when a transport has one.
  final String? etag;

  String get strongEtag => '"$sha256"';

  bool sameIdentity(HostedArtifact other) =>
      jobId == other.jobId &&
      sha256 == other.sha256 &&
      bytes == other.bytes;

  Map<String, Object?> toMap() => {
    'jobId': jobId,
    'sha256': sha256,
    'bytes': bytes,
    if (etag != null) 'etag': etag,
  };

  @override
  String toString() => 'hosted:$jobId@$sha256($bytes bytes)';
}

int? _positiveInt(Object? value) {
  if (value is int) return value > 0 ? value : null;
  if (value is num && value == value.roundToDouble() && value > 0) {
    return value.toInt();
  }
  return null;
}

/// Facts the hosted service reports for a finished job.
final class HostedJobInfo {
  const HostedJobInfo({
    required this.status,
    required this.sha256,
    required this.bytes,
    this.manifestSha256,
  });

  final String status;
  final String sha256;
  final int bytes;
  final String? manifestSha256;
}

/// Parses and cross-checks the job metadata a hosted service returns.
///
/// A stale flash target is refused: the digest and length must equal the ones
/// captured when the result was published.
HostedJobInfo parseHostedJobInfo(
  Map<String, Object?> map,
  HostedArtifact artifact,
) {
  final status = map['status'];
  if (status != 'succeeded') {
    throw FlashException(
      'Hosted job ${artifact.jobId} is ${status ?? 'in an unknown state'}, '
      'not a finished build.',
    );
  }
  final digest = map['sha256'];
  if (digest is! String ||
      !HostedArtifact._sha256Pattern.hasMatch(digest) ||
      digest.toLowerCase() != artifact.sha256) {
    throw const FlashException(
      'The hosted job reports a different sha256 than this flash target. '
      'Load the job again.',
    );
  }
  final bytes = _positiveInt(map['bytes']);
  if (bytes == null || bytes != artifact.bytes) {
    throw const FlashException(
      'The hosted job reports a different artifact length than this flash '
      'target. Load the job again.',
    );
  }
  final manifest = map['manifestSha256'];
  final manifestSha256 = manifest is String && manifest.isNotEmpty
      ? manifest
      : null;
  return HostedJobInfo(
    status: status as String,
    sha256: artifact.sha256,
    bytes: artifact.bytes,
    manifestSha256: manifestSha256,
  );
}

/// Decodes the bounded `build.json` a hosted job serves.
Map<String, Object?> decodeHostedManifest(Uint8List bytes) {
  if (bytes.length > 1 << 20) {
    throw const FlashException('The hosted build.json is too large.');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException catch (error) {
    throw FlashException('The hosted build.json is not valid JSON: $error');
  }
  if (decoded is! Map) {
    throw const FlashException('The hosted build.json is not a JSON object.');
  }
  final manifest = Map<String, Object?>.from(decoded);
  if (manifest['output_format'] != 'zip') {
    throw FlashException(
      'A hosted flash must be a ZIP build, not '
      '${manifest['output_format'] ?? 'an unknown format'}.',
    );
  }
  final artifact = manifest['artifact'];
  if (artifact is! String || artifact.isEmpty) {
    throw const FlashException('The hosted build.json has no artifact name.');
  }
  return manifest;
}

/// A hosted ZIP package read through one pinned range source.
final class HostedFlashPackage implements FlashPackage {
  HostedFlashPackage._({
    required this.artifact,
    required this.buildJson,
    required this.index,
    required this.manifestSha256,
    required Map<String, rust_zip.ZipEntry> entries,
    required this._source,
    required this.leaseValid,
  }) : _entries = Map.unmodifiable(entries);

  /// Opens a package from a manifest and a pinned artifact source.
  ///
  /// [etag] is recorded for the confirmation snapshot; transports that can
  /// enforce it (the browser range source) also refuse any changed response.
  static Future<HostedFlashPackage> load({
    required HostedArtifact artifact,
    required Uint8List manifestBytes,
    required ByteSource source,
    String? etag,
    bool Function()? leaseValid,
  }) async {
    if (!await loadNative()) {
      throw const FlashException(
        "This place does not have flasher_web's native library.",
      );
    }
    if (source.length != artifact.bytes) {
      throw FlashException(
        'The hosted artifact is ${source.length} bytes, not '
        '${artifact.bytes}. Load the job again.',
      );
    }
    final buildJson = decodeHostedManifest(manifestBytes);
    final manifestSha256 = sha256.convert(manifestBytes).toString();
    final entries = await parseZipEntries(source);
    if (entries.isEmpty) {
      throw const FlashException('The hosted ZIP has no entries.');
    }
    final guarded = _GuardedSource(
      source,
      leaseValid ?? () => true,
      artifact.jobId,
    );
    return HostedFlashPackage._(
      artifact: HostedArtifact(
        jobId: artifact.jobId,
        sha256: artifact.sha256,
        bytes: artifact.bytes,
        etag: etag,
      ),
      buildJson: Map.unmodifiable(buildJson),
      index: PackageIndex.fromEntries(entries.keys, buildJson: buildJson),
      manifestSha256: manifestSha256,
      entries: entries,
      source: guarded,
      leaseValid: leaseValid ?? () => true,
    );
  }

  /// Identity plus observed ETag.
  final HostedArtifact artifact;
  final String manifestSha256;
  final bool Function() leaseValid;
  final Map<String, rust_zip.ZipEntry> _entries;
  final ByteSource _source;

  @override
  final Map<String, Object?> buildJson;

  @override
  final PackageIndex index;

  @override
  String get format => 'zip';

  rust_zip.ZipEntry _entry(String path) {
    final entry = _entries[path];
    if (entry == null) {
      throw FlashException('The package is missing $path.');
    }
    return entry;
  }

  @override
  Future<int> size(String path) async => _entry(path).uncompressedSize.toInt();

  @override
  Future<FlashSource> open(String path) async {
    final entry = _entry(path);
    final header = await _source.read(entry.localHeaderOffset.toInt(), 30);
    final dataOffset = rust_zip
        .zipDataOffset(
          localHeader30Bytes: header,
          localHeaderOffset: entry.localHeaderOffset,
        )
        .toInt();
    return ZipEntrySource(
      openArchive: () async => _source,
      closeArchive: false,
      dataOffset: dataOffset,
      compressedSize: entry.compressedSize.toInt(),
      length: entry.uncompressedSize.toInt(),
      crc32: entry.crc32,
      method: entry.method,
    );
  }

  @override
  Future<Map<String, Object?>> snapshot() async {
    return {
      'format': format,
      'hosted': artifact.toMap(),
      'etag': artifact.strongEtag,
      'manifestSha256': manifestSha256,
      'entries': {
        for (final entry in _entries.values)
          entry.name: {
            'bytes': entry.uncompressedSize.toString(),
            'compressed': entry.compressedSize.toString(),
            'crc32': entry.crc32,
            'method': entry.method,
          },
      },
      'buildJson': buildJson,
    };
  }
}

/// Refuses reads once the retention lease is lost.
final class _GuardedSource implements ByteSource {
  _GuardedSource(this._source, this._leaseValid, this._jobId);

  final ByteSource _source;
  final bool Function() _leaseValid;
  final String _jobId;

  @override
  int get length {
    _check();
    return _source.length;
  }

  @override
  Future<Uint8List> read(int offset, int length) async {
    _check();
    return _source.read(offset, length);
  }

  /// Closing never waits for the lease: a lost lease must still release the
  /// range source and any handle beneath it.
  Future<void> close() => closeByteSource(_source);

  void _check() {
    if (!_leaseValid()) {
      throw FlashException(
        'The retention lease for hosted job $_jobId was lost or expired. '
        'Nothing further was read; load the job and prepare again.',
      );
    }
  }
}

/// One retention lease held by a hosted session.
abstract interface class HostedLease {
  DateTime get expiresAt;

  /// Renews the lease and returns the new expiry. Throwing marks the session
  /// unusable before another artifact read.
  Future<DateTime> renew();

  Future<void> release();
}

/// Same-origin access to a hosted job. Implemented with `fetch` on the web and
/// refused natively, where there is no hosted origin.
abstract interface class HostedTransport {
  Future<HostedJobInfo> readJob(HostedArtifact artifact);

  Future<Uint8List> readManifest(HostedArtifact artifact);

  /// Opens the pinned artifact range source. It must enforce [artifact.bytes]
  /// and an ETag equal to [HostedArtifact.strongEtag].
  Future<ByteSource> openArtifact(HostedArtifact artifact);

  Future<HostedLease> acquireLease(HostedArtifact artifact);
}

/// A live hosted package plus its retention lease.
final class HostedFlashSession {
  HostedFlashSession._({
    required this.artifact,
    required this.package,
    required this._lease,
    required this._source,
    required this._maxLease,
    required this.info,
  }) : _leaseStarted = DateTime.now().toUtc();

  static Future<HostedFlashSession> open({
    required HostedArtifact artifact,
    HostedTransport? transport,
    Duration maxLease = const Duration(hours: 12),
  }) async {
    final backend = transport ?? createHostedTransport();
    final lease = await backend.acquireLease(artifact);
    bool leaseCurrent() =>
        DateTime.now().toUtc().isBefore(lease.expiresAt);
    void checkLease() {
      if (!leaseCurrent()) {
        throw FlashException(
          'The retention lease for hosted job ${artifact.jobId} expired '
          'before the artifact was opened.',
        );
      }
    }

    ByteSource? source;
    try {
      final info = await backend.readJob(artifact);
      checkLease();
      final manifestBytes = await backend.readManifest(artifact);
      checkLease();
      final manifestSha256 = sha256.convert(manifestBytes).toString();
      final expectedManifest = info.manifestSha256;
      if (expectedManifest != null &&
          expectedManifest.toLowerCase() != manifestSha256) {
        throw const FlashException(
          'The hosted build.json changed after the job finished. Load the job '
          'again.',
        );
      }
      source = _GuardedSource(
        await backend.openArtifact(artifact),
        leaseCurrent,
        artifact.jobId,
      );
      late final HostedFlashSession session;
      final package = await HostedFlashPackage.load(
        artifact: artifact,
        manifestBytes: manifestBytes,
        source: source,
        etag: artifact.strongEtag,
        leaseValid: () => session.leaseValid,
      );
      session = HostedFlashSession._(
        artifact: artifact,
        package: package,
        lease: lease,
        source: source,
        maxLease: maxLease,
        info: info,
      );
      session._startLease();
      return session;
    } on Object catch (error) {
      if (source != null) await closeByteSource(source);
      await _releaseQuietly(lease);
      if (error is RangeException) {
        throw FlashException(
          'The hosted artifact range check failed: ${error.message}',
        );
      }
      rethrow;
    }
  }

  final HostedArtifact artifact;
  final HostedFlashPackage package;
  final HostedJobInfo info;
  final HostedLease _lease;
  final ByteSource _source;
  final Duration _maxLease;
  final DateTime _leaseStarted;

  Timer? _renewTimer;
  Timer? _expiryTimer;
  bool _closed = false;
  bool _renewing = false;
  var _leaseLost = false;
  DateTime? _expiresAt;

  bool get leaseLost => _leaseLost;

  /// Whether the lease is still valid *now*.
  ///
  /// This checks the wall clock, not only a renewal flag: a hung renew request
  /// can leave `_renewing` true while the server-side pin has already expired.
  bool get leaseValid {
    if (_closed || _leaseLost) return false;
    final expires = _expiresAt;
    if (expires == null || !DateTime.now().toUtc().isBefore(expires)) {
      _leaseLost = true;
      _cancelLeaseTimers();
      return false;
    }
    return true;
  }

  /// Throws before any artifact read or device command after lease loss.
  void assertLease() {
    if (!leaseValid) {
      throw FlashException(
        'The retention lease for hosted job ${artifact.jobId} expired or was '
        'lost. No further device command or artifact read was sent. Load the '
        'job and prepare again; do not retry the write.',
      );
    }
  }

  /// Wraps a fastboot transport so every command, download piece, open and
  /// device listing checks the lease immediately before it is sent.
  FastbootTransport guardedTransport(FastbootTransport inner) =>
      _LeaseGuardedTransport(inner, assertLease);

  void _startLease() {
    final expiry = _lease.expiresAt;
    _expiresAt = expiry;
    final now = DateTime.now().toUtc();
    final ttl = expiry.difference(now);
    if (ttl <= Duration.zero) {
      _leaseLost = true;
      return;
    }
    _scheduleLease();
  }

  void _scheduleLease() {
    _cancelLeaseTimers();
    final expiry = _expiresAt;
    if (expiry == null || _closed || _leaseLost) return;
    final now = DateTime.now().toUtc();
    final ttl = expiry.difference(now);
    if (ttl <= Duration.zero) {
      _leaseLost = true;
      return;
    }
    // The one-shot expiry timer is driven by the event loop's monotonic clock;
    // every guard also compares the wall clock, so a late timer cannot allow
    // another read or command.
    _expiryTimer = Timer(ttl, () {
      _leaseLost = true;
      _cancelLeaseTimers();
    });
    final interval = clampRenewInterval(ttl);
    _renewTimer = Timer(interval, () => unawaited(_renew()));
  }

  Future<void> _renew() async {
    if (_closed || !leaseValid || _renewing) return;
    final now = DateTime.now().toUtc();
    if (now.isAfter(_leaseStarted.add(_maxLease))) {
      // Never hold a server-side pin forever.
      _leaseLost = true;
      _cancelLeaseTimers();
      return;
    }
    final ttl = _expiresAt!.difference(now);
    _renewing = true;
    try {
      // The request must resolve well before expiry; a hung request cannot
      // extend the pin or silently leave the session usable.
      final expiry = await _lease.renew().timeout(renewTimeout(ttl));
      if (_closed || _leaseLost) {
        await _releaseQuietly(_lease);
        return;
      }
      if (!expiry.isAfter(DateTime.now().toUtc())) {
        _leaseLost = true;
        _cancelLeaseTimers();
        return;
      }
      _expiresAt = expiry;
      _scheduleLease();
    } on Object {
      _leaseLost = true;
      _cancelLeaseTimers();
    } finally {
      _renewing = false;
    }
  }

  /// Stops renewal, releases the pin and closes the range source.
  ///
  /// A release failure is not fatal: the server expires the lease on its own,
  /// and masking a completed flash with a cleanup error would lose evidence.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cancelLeaseTimers();
    try {
      await _lease.release();
    } on Object {
      // The hard lease lifetime still bounds the server-side pin.
    } finally {
      await closeByteSource(_source);
    }
  }

  void _cancelLeaseTimers() {
    _renewTimer?.cancel();
    _renewTimer = null;
    _expiryTimer?.cancel();
    _expiryTimer = null;
  }

  /// A bounded wait used by tests and diagnostics.
  DateTime? get leaseExpiresAt => _expiresAt;

  static const Duration minimumRenewInterval = Duration(milliseconds: 250);
  static const Duration maximumRenewInterval = Duration(minutes: 5);

  /// A renewal interval strictly shorter than [ttl].
  ///
  /// A fifth of the lease (or half, for very short leases) leaves room for a
  /// slow renew response before the server-side expiry. It is never rounded up
  /// past the TTL; the previous 15 s floor could outlive a 5 s server lease.
  static Duration clampRenewInterval(Duration ttl) {
    if (ttl <= Duration.zero) return Duration.zero;
    final third = ttl ~/ 3;
    if (third >= minimumRenewInterval) {
      return third > maximumRenewInterval ? maximumRenewInterval : third;
    }
    final half = ttl ~/ 2;
    if (half > Duration.zero) return half;
    return const Duration(milliseconds: 1);
  }

  /// A renew request must finish before the current lease expires.
  static Duration renewTimeout(Duration ttl) {
    final half = ttl ~/ 2;
    if (half > Duration.zero) return half;
    return const Duration(milliseconds: 1);
  }

  static int boundedRenewalCount(Duration ttl, Duration maxLease) {
    final interval = clampRenewInterval(ttl);
    if (interval <= Duration.zero) return 1;
    return math.max(1, maxLease.inMilliseconds ~/ interval.inMilliseconds);
  }

  static Future<void> _releaseQuietly(HostedLease lease) async {
    try {
      await lease.release();
    } on Object {
      // The hard lease lifetime still bounds the server-side pin.
    }
  }
}

/// Checks the lease immediately before every fastboot interaction.
final class _LeaseGuardedTransport implements FastbootTransport {
  _LeaseGuardedTransport(this._inner, this._guard);

  final FastbootTransport _inner;
  final void Function() _guard;

  @override
  Future<List<FastbootDevice>> devices() async {
    _guard();
    return _inner.devices();
  }

  @override
  Future<FastbootSession> open(String serial) async {
    _guard();
    final session = await _inner.open(serial);
    try {
      _guard();
    } on Object {
      await session.close();
      rethrow;
    }
    return _LeaseGuardedSession(session, _guard);
  }
}

final class _LeaseGuardedSession implements FastbootSession {
  _LeaseGuardedSession(this._inner, this._guard);

  final FastbootSession _inner;
  final void Function() _guard;

  @override
  String get serial => _inner.serial;

  @override
  Future<String> command(String command, {bool write = false}) async {
    _guard();
    return _inner.command(command, write: write);
  }

  @override
  Future<void> beginDownload(int length) async {
    _guard();
    return _inner.beginDownload(length);
  }

  @override
  Future<void> writeDownload(Uint8List bytes) async {
    _guard();
    return _inner.writeDownload(bytes);
  }

  @override
  Future<void> endDownload() async {
    _guard();
    return _inner.endDownload();
  }

  /// Closing must always succeed, even after the lease is lost.
  @override
  Future<void> close() => _inner.close();
}

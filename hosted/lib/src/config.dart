import 'dart:io';

import 'util.dart';

/// Default OTA origins accepted in addition to the catalog download page.
const List<String> defaultOtaHostSuffixes = [
  'allawnofs.com',
  'allawnos.com',
  'oneplus.com',
  'oneplus.net',
  'oppo.com',
  'coloros.com',
  'realme.com',
  'heytapimage.com',
];

const String otaCatalogHost = 'roms.danielspringer.at';
const String otaCatalogPath = '/download.php';

/// Everything the hosted service reads from its operator environment.
final class HostedConfig {
  HostedConfig({
    required this.root,
    required this.token,
    required this.apiOrigin,
    required this.upstreamDir,
    this.builderRevision = '',
    this.bindAddress = '127.0.0.1',
    this.port = 8080,
    this.concurrency = 2,
    this.maxQueue = 32,
    this.cacheBudgetBytes = 200 * 1024 * 1024 * 1024,
    this.minFreeBytes = 8 * 1024 * 1024 * 1024,
    this.maxOtaBytes = 32 * 1024 * 1024 * 1024,
    this.maxArtifactBytes = 30 * 1024 * 1024 * 1024,
    this.jobDiskBytes = 48 * 1024 * 1024 * 1024,
    this.retentionDays = 150,
    this.otaRetentionDays = 150,
    this.leaseTtl = const Duration(seconds: 900),
    this.leaseMaxLifetime = const Duration(hours: 12),
    this.maxLeasesPerJob = 8,
    this.internalLeaseTtl = const Duration(minutes: 15),
    this.maxInternalLeasesPerJob = 4,
    this.maxInternalLeasesTotal = 32,
    this.artifactStreamTimeout = const Duration(minutes: 10),
    this.cacheHandoffTtl = const Duration(seconds: 60),
    this.maxActiveOperationsPerJob = 4,
    this.maxActiveOperationsTotal = 32,
    this.cpuSeconds = 7200,
    this.cpuPercent = 200,
    this.cpuPeriodMicros = 100000,
    this.cgroupRoot,
    this.jobTimeout = const Duration(hours: 6),
    this.catalogMaxStale = const Duration(hours: 6),
    this.catalogTtl = const Duration(minutes: 15),
    this.prlimit = 'prlimit',
    this.buildWorker,
    this.otaHostSuffixes = defaultOtaHostSuffixes,
  });

  factory HostedConfig.fromEnvironment(Map<String, String> environment) {
    String required(String name) {
      final value = envString(environment, name);
      if (value == null) {
        throw FormatException('$name is required');
      }
      return value;
    }

    final originText = required('HOSTED_API_ORIGIN');
    final origin = Uri.tryParse(originText);
    if (origin == null) throw const FormatException('HOSTED_API_ORIGIN is invalid');
    _checkApiOrigin(origin);

    final bind = envString(environment, 'HOSTED_BIND') ?? '127.0.0.1';
    final bindIp = InternetAddress.tryParse(bind);
    if (bindIp == null) {
      throw const FormatException(
        'HOSTED_BIND must be a loopback or private IP address',
      );
    }
    if (!isPrivateAddress(bindIp)) {
      throw const FormatException(
        'HOSTED_BIND must be loopback or a private interface',
      );
    }

    final builderRevision = required('HOSTED_BUILDER_REVISION');
    if (!RegExp(r'^[A-Za-z0-9._+-]{8,128}$').hasMatch(builderRevision)) {
      throw const FormatException(
        'HOSTED_BUILDER_REVISION must be an immutable 8-128 character build '
        'identity (commit or build id)',
      );
    }
    final token = required('HOSTED_TOKEN');
    if (token.length < 32) {
      throw const FormatException('HOSTED_TOKEN must be at least 32 characters');
    }

    final root = required('HOSTED_ROOT');
    final upstream = required('HOSTED_UPSTREAM_DIR');
    final suffixes = envString(environment, 'HOSTED_ALLOWED_OTA_HOSTS');
    final leaseTtl = envDuration(
      environment,
      'HOSTED_LEASE_TTL_SECONDS',
      fallback: const Duration(seconds: 900),
      minimum: const Duration(seconds: 5),
    );
    final leaseMax = envDuration(
      environment,
      'HOSTED_LEASE_MAX_SECONDS',
      fallback: const Duration(hours: 12),
      minimum: const Duration(seconds: 5),
    );
    if (leaseMax < leaseTtl) {
      throw const FormatException(
        'HOSTED_LEASE_MAX_SECONDS must not be shorter than '
        'HOSTED_LEASE_TTL_SECONDS',
      );
    }

    final config = HostedConfig(
      root: Directory(root),
      token: token,
      apiOrigin: origin,
      upstreamDir: Directory(upstream),
      builderRevision: builderRevision,
      bindAddress: bind,
      port: envInt(environment, 'HOSTED_PORT', fallback: 8080, minimum: 1, maximum: 65535),
      concurrency: envInt(
        environment,
        'HOSTED_CONCURRENCY',
        fallback: 2,
        minimum: 1,
        maximum: 8,
      ),
      maxQueue: envInt(
        environment,
        'HOSTED_MAX_QUEUE',
        fallback: 32,
        minimum: 1,
        maximum: 512,
      ),
      cacheBudgetBytes: envInt(
        environment,
        'HOSTED_CACHE_BYTES',
        fallback: 200 * 1024 * 1024 * 1024,
        minimum: 1024 * 1024 * 1024,
      ),
      minFreeBytes: envInt(
        environment,
        'HOSTED_MIN_FREE_BYTES',
        fallback: 8 * 1024 * 1024 * 1024,
        minimum: 0,
      ),
      maxOtaBytes: envInt(
        environment,
        'HOSTED_MAX_OTA_BYTES',
        fallback: 32 * 1024 * 1024 * 1024,
        minimum: 1024 * 1024,
      ),
      maxArtifactBytes: envInt(
        environment,
        'HOSTED_MAX_ARTIFACT_BYTES',
        fallback: 30 * 1024 * 1024 * 1024,
        minimum: 1024 * 1024,
      ),
      jobDiskBytes: envInt(
        environment,
        'HOSTED_JOB_DISK_BYTES',
        fallback: 48 * 1024 * 1024 * 1024,
        minimum: 16 * 1024 * 1024,
      ),
      retentionDays: envInt(
        environment,
        'HOSTED_RETENTION_DAYS',
        fallback: 150,
        minimum: 1,
      ),
      otaRetentionDays: envInt(
        environment,
        'HOSTED_OTA_RETENTION_DAYS',
        fallback: 150,
        minimum: 1,
      ),
      leaseTtl: leaseTtl,
      leaseMaxLifetime: leaseMax,
      maxLeasesPerJob: envInt(
        environment,
        'HOSTED_MAX_LEASES_PER_JOB',
        fallback: 8,
        minimum: 1,
        maximum: 64,
      ),
      cpuSeconds: envInt(
        environment,
        'HOSTED_CPU_SECONDS',
        fallback: 7200,
        minimum: 10,
      ),
      cpuPercent: envInt(
        environment,
        'HOSTED_CPU_PERCENT',
        fallback: 200,
        minimum: 1,
        maximum: 6400,
      ),
      cpuPeriodMicros: envInt(
        environment,
        'HOSTED_CPU_PERIOD_US',
        fallback: 100000,
        minimum: 1000,
        maximum: 1000000,
      ),
      cgroupRoot: envString(environment, 'HOSTED_CGROUP_ROOT'),
      jobTimeout: Duration(
        seconds: envInt(
          environment,
          'HOSTED_JOB_TIMEOUT_SECONDS',
          fallback: 21600,
          minimum: 30,
        ),
      ),
      catalogMaxStale: Duration(
        seconds: envInt(
          environment,
          'HOSTED_CATALOG_MAX_STALE_SECONDS',
          fallback: 21600,
          minimum: 0,
        ),
      ),
      prlimit: envString(environment, 'HOSTED_PRLIMIT') ?? 'prlimit',
      buildWorker: envString(environment, 'HOSTED_BUILD_WORKER'),
      otaHostSuffixes: suffixes == null
          ? defaultOtaHostSuffixes
          : [
              for (final value in suffixes.split(','))
                if (value.trim().isNotEmpty) value.trim().toLowerCase(),
            ],
    );
    if (config.minFreeBytes > config.cacheBudgetBytes) {
      throw const FormatException(
        'HOSTED_MIN_FREE_BYTES must not exceed HOSTED_CACHE_BYTES',
      );
    }
    return config;
  }

  final Directory root;
  final String token;
  final Uri apiOrigin;
  final Directory upstreamDir;
  final String builderRevision;
  final String bindAddress;
  final int port;
  final int concurrency;
  final int maxQueue;
  final int cacheBudgetBytes;
  final int minFreeBytes;
  final int maxOtaBytes;
  final int maxArtifactBytes;
  final int jobDiskBytes;
  final int retentionDays;
  final int otaRetentionDays;
  final Duration leaseTtl;
  final Duration leaseMaxLifetime;
  final int maxLeasesPerJob;
  final Duration internalLeaseTtl;
  final int maxInternalLeasesPerJob;
  final int maxInternalLeasesTotal;
  final Duration artifactStreamTimeout;
  final Duration cacheHandoffTtl;
  final int maxActiveOperationsPerJob;
  final int maxActiveOperationsTotal;
  final int cpuSeconds;
  final int cpuPercent;
  final int cpuPeriodMicros;
  final String? cgroupRoot;
  final Duration jobTimeout;
  final Duration catalogMaxStale;
  final Duration catalogTtl;
  final String prlimit;
  final String? buildWorker;
  final List<String> otaHostSuffixes;

  Duration get retention => Duration(days: retentionDays);
  Duration get otaRetention => Duration(days: otaRetentionDays);

  /// Verifies the operator directories and the approved origin.
  Future<void> checkForServer() async {
    if (internalLeaseTtl <= artifactStreamTimeout) {
      throw const HostedConfigException(
        'The internal lease TTL must exceed the artifact stream timeout so a '
        'stream can never outlive its eviction pin.',
      );
    }
    if (!RegExp(r'^[A-Za-z0-9._+-]{8,128}$').hasMatch(builderRevision)) {
      throw const HostedConfigException(
        'HOSTED_BUILDER_REVISION is required and must identify the deployed '
        'builder implementation; cached artifacts must never survive a '
        'builder upgrade under the same revision.',
      );
    }
    final rootAbsolute = root.absolute;
    await rootAbsolute.create(recursive: true);
    if (!await upstreamDir.exists()) {
      throw HostedConfigException(
        'HOSTED_UPSTREAM_DIR does not exist: ${upstreamDir.path}',
      );
    }
    for (final name in [
      'tables.json',
      'bloat-manifest.json',
      'platform-tools.zip',
    ]) {
      if (!await File(joinPath(upstreamDir.path, [name])).exists()) {
        throw HostedConfigException(
          'HOSTED_UPSTREAM_DIR is missing $name',
        );
      }
    }
    if (!await _isWritable(rootAbsolute)) {
      throw HostedConfigException('HOSTED_ROOT is not writable');
    }
    _checkApiOrigin(apiOrigin);
  }

  /// True when [host] is an allowlisted OTA origin.
  bool otaHostAllowed(String host) {
    final normalized = host.toLowerCase();
    if (normalized == otaCatalogHost) return true;
    return otaHostSuffixes.any(
      (suffix) => normalized == suffix || normalized.endsWith('.$suffix'),
    );
  }

  /// Validates a resolved OTA URL before it can be proxied or recorded.
  Uri checkOtaUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort) {
      throw const HostedConfigException(
        'The OTA server returned an unapproved URL',
      );
    }
    if (!otaHostAllowed(uri.host)) {
      throw const HostedConfigException(
        'The OTA server returned an unapproved host',
      );
    }
    if (uri.host.toLowerCase() == otaCatalogHost &&
        uri.path != otaCatalogPath) {
      throw const HostedConfigException(
        'The OTA server returned an unapproved catalog link',
      );
    }
    return uri;
  }
}

final class HostedConfigException implements Exception {
  const HostedConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

void _checkApiOrigin(Uri origin) {
  final local =
      origin.scheme == 'http' &&
      (origin.host == '127.0.0.1' ||
          origin.host == 'localhost' ||
          origin.host == '::1');
  if (origin.scheme != 'https' && !local) {
    throw const HostedConfigException(
      'HOSTED_API_ORIGIN must be an HTTPS origin (HTTP is allowed only on '
      'loopback)',
    );
  }
  if (origin.userInfo.isNotEmpty ||
      origin.query.isNotEmpty ||
      origin.fragment.isNotEmpty ||
      origin.path.isNotEmpty && origin.path != '/') {
    throw const HostedConfigException(
      'HOSTED_API_ORIGIN must be an origin with no userinfo, path or query',
    );
  }
}

bool isPrivateAddress(InternetAddress address) {
  if (address.isLoopback) return true;
  if (address.type == InternetAddressType.IPv4) {
    final bytes = address.rawAddress;
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 169 && bytes[1] == 254);
  }
  final bytes = address.rawAddress;
  // fc00::/7 unique-local and fe80::/10 link-local.
  return (bytes[0] & 0xfe) == 0xfc ||
      (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80);
}

Future<bool> _isWritable(Directory directory) async {
  final probe = File(
    joinPath(directory.path, [
      '.hosted-write-${DateTime.now().microsecondsSinceEpoch}.tmp',
    ]),
  );
  try {
    await probe.writeAsString('probe', flush: true);
    await probe.delete();
    return true;
  } on Object {
    return false;
  }
}

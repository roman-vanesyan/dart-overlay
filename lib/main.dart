import 'dart:io' show HttpClient, File;
import 'dart:convert' show utf8, json, JsonEncoder;
import 'dart:math' show min;
import 'package:pub_semver/pub_semver.dart' show Version;
import 'package:strlog/strlog.dart' as log;
import 'package:strlog/handlers.dart' show ConsoleHandler;
import 'package:strlog/formatters.dart' show TextFormatter;
import 'src/dao.dart';
import 'src/svn_versions.dart';

typedef SourceValue = Map<
    String, // $arch-$platform
    Source>;

Map<String, SourceValue> _parseSources(String content) {
  final parsedJsonMap = json.decode(content) as Map<String, dynamic>;
  return Map<String, SourceValue>.fromIterables(parsedJsonMap.keys,
      parsedJsonMap.keys.map((key) {
    final source = parsedJsonMap[key] as Map<String, dynamic>;

    return Map<String, Source>.fromIterables(
        source.keys,
        source.keys.map(
            (key) => Source.fromJson(source[key] as Map<String, dynamic>)));
  }));
}

// Supported channels.
enum Channel {
  dev,
  beta,
  stable;

  // Converts string to Channel, otherwise throws an error
  static Channel fromString(String str) {
    return switch (str) {
      "dev" => Channel.dev,
      "beta" => Channel.beta,
      "stable" => Channel.stable,
      _ => throw Exception('Unsupported channel $str')
    };
  }
}

// Supported platforms.
enum Platform {
  linux,
  macos;

  String toNix() =>
      switch (this) { Platform.linux => 'linux', Platform.macos => 'darwin' };
}

// Supported architectures.
enum Arch {
  x64,
  arm64;

  String toNix() =>
      switch (this) { Arch.arm64 => 'aarch64', Arch.x64 => 'x86_64' };
}

final _x64macOsMissingChecksum = [Version(1, 24, 0)];
final _x64LinuxMissingChecksum = [Version(1, 24, 0)];
final _arm64LinuxMissingChecksum = [
  Version(1, 23, 0, pre: "dev.9.2"),
  Version(1, 24, 0),
  Version(1, 25, 0, pre: "dev.10.0"),
  Version(1, 25, 0, pre: "dev.16.0"),
  Version(2, 0, 0, pre: "dev.1.0"),
  Version(2, 0, 0, pre: "dev.11.0"),
  Version(2, 0, 0, pre: "dev.25.0"),
  Version(2, 0, 0, pre: "dev.27.0"),
  Version(2, 0, 0, pre: "dev.33.0"),
  Version(2, 0, 0, pre: 'dev.49.0'),
  Version(2, 0, 0, pre: "dev.62.0"),
  Version(2, 0, 0, pre: "dev.63.0"),
  Version(2, 0, 0, pre: "dev.69.2"),
  Version(2, 1, 0, pre: "dev.9.0"),
];

final _platformToArch = {
  Platform.macos: [Arch.arm64, Arch.x64],
  Platform.linux: [Arch.arm64, Arch.x64],
};

final _domain = 'storage.googleapis.com';
final _alt = 'json';
final _delimiter = '/';
final _chunkSize = 4;

final _logger = log.Logger.detached("dart-overlay.main");

Future<Stream<String>> _getTextBase(HttpClient client, Uri url) async {
  final timer = _logger
      .withFields({log.Str.lazy("url", () => url.toString())}).startTimer(
          'sending request');

  final req = await client.getUrl(url);
  final res = await req.close();
  final stream = res.transform(utf8.decoder);

  timer.stop('finished request');

  return stream;
}

// [getText] makes GET request to the given [url] and parses returned bytes
// as UTF-8 string.
Future<String> _getText(HttpClient client, Uri url) async =>
    (await _getTextBase(client, url)).first;

// [getJson] makes GET request to the given [url] and parses returned bytes
// as JSON data.
Future<Object?> _getJson(HttpClient client, Uri url) async =>
    (await _getTextBase(client, url)).transform(json.decoder).first;

// [getVersions] returns a list of available versions for the channel.
// The returned list is sorted based on semver comparison in desc order.
Future<List<Version>> _fetchVersions(
    HttpClient client, final Channel channel) async {
  final commonPrefix = 'channels/${channel.name}/release/';
  final url = Uri.https(_domain, '/storage/v1/b/dart-archive/o',
      {'delimiter': _delimiter, 'alt': _alt, 'prefix': commonPrefix});
  final logctx = _logger.withFields({
    log.Str('common_prefix', commonPrefix),
    log.Str('channel', channel.name)
  });

  logctx.info('getting a list of sources');

  final resp = await _getJson(client, url);
  final result = GoogleStorageObjectList.fromJson(resp as Map<String, dynamic>);

  return result.prefixes.fold(
    <Version>[],
    (versions, e) {
      var versionStr = e.replaceFirst(commonPrefix, '').replaceAll('/', '');
      if (revisionToVersion.containsKey(versionStr)) {
        versionStr = revisionToVersion[versionStr]!;
      } else if (versionStr == "latest") {
        return versions;
      }
      final version = Version.parse(versionStr);
      if (_skipVersion(version)) {
        return versions;
      }

      return versions..add(version);
    },
  ).toList();
}

String _dartArchivePath(
    Channel channel, Platform platform, Arch arch, String version) {
  final ver = versionToRevision.containsKey(version)
      ? versionToRevision[version]!
      : version;

  return 'dart-archive/channels/${channel.name}/release/$ver/sdk/dartsdk-${platform.name}-${arch.name}-release.zip';
}

// [fetchSha256] returns a SHA-256 fetched from the storage.
Future<String> _fetchSha256(HttpClient client, Channel channel,
    Platform platform, Arch arch, String version) async {
  final text = await _getText(
      client,
      Uri.https(_domain,
          '${_dartArchivePath(channel, platform, arch, version)}.sha256sum'));

  return text.split(' ').first;
}

Future<MapEntry<String, Source>> fetchSource(HttpClient client, Channel channel,
    Platform platform, Arch arch, String version) async {
  final sha256 = await _fetchSha256(client, channel, platform, arch, version);
  final url =
      Uri.https(_domain, _dartArchivePath(channel, platform, arch, version))
          .toString();

  return MapEntry(
      "${arch.toNix()}-${platform.toNix()}", Source(version, url, sha256));
}

bool _skipVersion(Version version) {
  // No SHA-256 for builds before 1.6.0-dev.9.3
  return version < Version(1, 6, 0, pre: "dev.9.3");
}

bool _filterArch(Platform platform, Arch arch, Version version) {
  return switch (platform) {
    // No macOS ARM64 builds before 2.14.1
    Platform.macos => !(arch == Arch.arm64 && version < Version(2, 14, 1)) &&
        // missing checksum
        !(arch == Arch.x64 && _x64macOsMissingChecksum.contains(version)),
    Platform.linux =>
      // No linux ARM64 builds before 1.23.0-dev.5.0
      !(arch == Arch.arm64 &&
              (version < Version(1, 23, 0, pre: 'dev.5.0') ||
                  // missing checksum
                  _arm64LinuxMissingChecksum.contains(version))) &&
          // missing checksum
          !(arch == Arch.x64 && _x64LinuxMissingChecksum.contains(version)),
  };
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    throw Exception('Missing channel argument');
  }

  _logger.handler =
      ConsoleHandler(formatter: TextFormatter.withDefaults().call);
  _logger.level = log.Level.info;

  // using custom json encoder just for an indentation.
  final jsonEncoder = JsonEncoder.withIndent(' ' * 2);
  final client = HttpClient();
  final channel = Channel.fromString(args.first);
  final logCtx = _logger.withFields({log.Str('channel', channel.name)});

  // Read existing versions.
  var timer =
      logCtx.startTimer('reading existing versions', level: log.Level.info);
  final sourcesFile = File('./sources/${channel.name}/sources.json');
  final existingSources = switch (sourcesFile.existsSync()) {
    true => (_parseSources(sourcesFile.readAsStringSync())).entries,
    false => <MapEntry<String, SourceValue>>[]
  };
  timer.stop('finished reading existing versions',
      fields: [log.Int('total_existing_versions', existingSources.length)]);

  final existingVerions = existingSources.map((e) => e.key);

  timer =
      logCtx.startTimer('fetching a list of sources', level: log.Level.info);
  final versionsToDownload = (await _fetchVersions(client, channel))
      .where((version) => !existingVerions.contains(version.toString()))
      .toList();
  timer.stop('finished fetching a list of sources', fields: [
    log.Str('channel', channel.name),
    log.Int('total_fetched', versionsToDownload.length)
  ]);

  final List<MapEntry<String, SourceValue>> downloadedSources = [];

  timer = logCtx.startTimer('fetching source entities', level: log.Level.info);
  for (int i = 0; i < versionsToDownload.length; i += _chunkSize) {
    final versionsChunk = versionsToDownload.getRange(
        i, min(i + _chunkSize, versionsToDownload.length));
    final sources = await Future.wait(versionsChunk.map((version) async {
      final versionStr = version.toString();
      final sourceMap = Map.fromEntries(
          await Future.wait([Platform.linux, Platform.macos].expand((platform) {
        final archs = _platformToArch[platform];
        if (archs == null) {
          throw Exception('Cannot find arch for platform $platform');
        }

        // entry(nix-system-str, Source)
        return archs.where((arch) => _filterArch(platform, arch, version)).map(
            (arch) => fetchSource(client, channel, platform, arch, versionStr));
      })));

      return MapEntry(version.toString(), sourceMap);
    }));

    downloadedSources.addAll(sources);
  }
  timer.stop('finished fetching source entities',
      fields: [log.Int('total_fetched', downloadedSources.length)]);

  // Construct a new JSON map by merging downloaded sources with existing one.
  final sourcesMap = Map.fromEntries(([
    ...downloadedSources,
    ...existingSources
  ]).map((entry) => MapEntry(entry.key.toString(), entry.value)));

  // Write source file
  timer =
      logCtx.startTimer('writing source file to disk', level: log.Level.info);
  sourcesFile
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncoder.convert(sourcesMap), flush: true);
  timer.stop('finished writing source file to disk');

  client.close();
}

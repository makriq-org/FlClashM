import 'dart:convert';
import 'dart:io';

typedef ReadTextFile = Future<String> Function(String path);
typedef RunDnsCommand = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// Small, read-only system DNS boundary for StormDNS resolver rendering.
/// Platform helpers will own privileged DNS changes; this only observes the
/// resolver addresses that are already configured by the operating system.
class DesktopSystemDns {
  const DesktopSystemDns({
    this.target,
    this.readFile = _readFile,
    this.runCommand = Process.run,
  });

  static const _windowsDnsScript =
      r"$active = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and $_.Name -ne 'FlClashM' } | ForEach-Object { $_.ifIndex }); "
      r'$servers = @(Get-DnsClientServerAddress -ErrorAction Stop | Where-Object { $active -contains $_.InterfaceIndex } | ForEach-Object { $_.ServerAddresses }); '
      r'ConvertTo-Json -InputObject $servers -Compress';

  final String? target;
  final ReadTextFile readFile;
  final RunDnsCommand runCommand;

  Future<List<String>> read() async {
    final platform = target ?? Platform.operatingSystem;
    return switch (platform) {
      'linux' => _readLinux(),
      'macos' => _readMacos(),
      'windows' => _readWindows(),
      _ => const [],
    };
  }

  Future<List<String>> _readLinux() async {
    try {
      return _uniqueAddresses(await readFile('/etc/resolv.conf').then(_linux));
    } on FileSystemException {
      return const [];
    }
  }

  Future<List<String>> _readMacos() async {
    try {
      final result = await runCommand('scutil', const ['--dns']);
      if (result.exitCode != 0) return const [];
      return _uniqueAddresses(_macos('${result.stdout}'));
    } on ProcessException {
      return const [];
    }
  }

  Future<List<String>> _readWindows() async {
    try {
      final result = await runCommand('powershell.exe', const [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        _windowsDnsScript,
      ]);
      if (result.exitCode != 0) return const [];
      final decoded = jsonDecode('${result.stdout}');
      if (decoded is! List) return const [];
      return _uniqueAddresses(decoded.whereType<String>());
    } on ProcessException {
      return const [];
    } on FormatException {
      return const [];
    }
  }

  static Future<String> _readFile(String path) => File(path).readAsString();

  static Iterable<String> _linux(String value) sync* {
    for (final line in value.split('\n')) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length == 2 && fields.first == 'nameserver') {
        yield fields.last;
      }
    }
  }

  static Iterable<String> _macos(String value) sync* {
    final matcher = RegExp(r'^\s*nameserver\[\d+\]\s*:\s*(\S+)\s*$');
    for (final line in value.split('\n')) {
      final match = matcher.firstMatch(line);
      if (match != null) yield match.group(1)!;
    }
  }

  static List<String> _uniqueAddresses(Iterable<String> values) {
    final addresses = <String>[];
    for (final value in values) {
      final address = InternetAddress.tryParse(value.trim());
      if (address != null && !addresses.contains(address.address)) {
        addresses.add(address.address);
      }
    }
    return addresses;
  }
}

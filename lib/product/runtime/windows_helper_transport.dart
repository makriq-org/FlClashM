import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;
import 'package:win32/win32.dart';

import 'desktop_helper_protocol.dart';

// SERVICE_QUERY_CONFIG is absent from the win32 5 generated constants.
const _serviceQueryConfig = 0x0001;

/// Performs bounded overlapped pipe IO off the UI isolate. Both peers validate
/// the installed image; a user-created pipe cannot impersonate LocalSystem.
class WindowsHelperTransport implements DesktopHelperTransport {
  const WindowsHelperTransport();

  @override
  Future<DesktopHelperResponse> send(DesktopHelperRequest request) async {
    if (!Platform.isWindows) {
      return const DesktopHelperResponse(
        state: DesktopHelperState.unavailable,
        message: 'Windows helper is unavailable on this platform.',
      );
    }
    final bytes = WindowsDesktopHelperMessageCodec.encode(request);
    return WindowsDesktopHelperMessageCodec.decode(
      await Isolate.run(() => _exchange(bytes)),
    );
  }
}

List<int> _exchange(List<int> bytes) => using((arena) {
      final pipeName = r'\\.\pipe\app.flclashm.client.helper.v1'
          .toNativeUtf16(allocator: arena);
      final kernel = DynamicLibrary.open('kernel32.dll');
      final waitNamedPipe = kernel.lookupFunction<
          Int32 Function(Pointer<Utf16>, Uint32),
          int Function(Pointer<Utf16>, int)>('WaitNamedPipeW');
      if (waitNamedPipe(pipeName, 1500) == 0) {
        throw StateError(
            'Windows helper is not running. Reinstall FlClashM using its installer.');
      }
      final pipe = CreateFile(
        pipeName,
        GENERIC_READ | GENERIC_WRITE,
        0,
        nullptr,
        OPEN_EXISTING,
        FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
        0,
      );
      if (pipe == INVALID_HANDLE_VALUE) {
        throw StateError('Cannot open Windows helper pipe.');
      }
      try {
        final serverPid = arena<Uint32>();
        final getServerPid = kernel.lookupFunction<
            Int32 Function(IntPtr, Pointer<Uint32>),
            int Function(int, Pointer<Uint32>)>('GetNamedPipeServerProcessId');
        if (getServerPid(pipe, serverPid) == 0) {
          throw StateError('Cannot identify Windows helper.');
        }
        _verifyServer(serverPid.value, arena);
        final input = arena<Uint8>(bytes.length);
        input.asTypedList(bytes.length).setAll(0, bytes);
        final written = _transfer(pipe, input, bytes.length, true, arena);
        if (written != bytes.length) {
          throw StateError('Incomplete Windows helper request.');
        }
        final output = arena<Uint8>(16 * 1024);
        final read = _transfer(pipe, output, 16 * 1024, false, arena);
        return List<int>.from(output.asTypedList(read));
      } finally {
        CloseHandle(pipe);
      }
    });

int _transfer(
    int pipe, Pointer<Uint8> buffer, int length, bool write, Arena arena) {
  final overlapped = arena<OVERLAPPED>();
  final count = arena<Uint32>();
  final event = CreateEvent(nullptr, TRUE, FALSE, nullptr);
  if (event == 0) throw StateError('Cannot allocate helper IO event.');
  overlapped.ref.hEvent = event;
  try {
    final result = write
        ? WriteFile(pipe, buffer, length, nullptr, overlapped)
        : ReadFile(pipe, buffer, length, nullptr, overlapped);
    if (result == 0 && GetLastError() != ERROR_IO_PENDING) {
      throw StateError('Windows helper IO failed: ${GetLastError()}.');
    }
    if (WaitForSingleObject(event, 7000) != WAIT_OBJECT_0) {
      CancelIoEx(pipe, overlapped);
      // Cancellation must complete before the arena frees its buffers.
      GetOverlappedResult(pipe, overlapped, count, TRUE);
      throw StateError('Windows helper response timed out.');
    }
    if (GetOverlappedResult(pipe, overlapped, count, FALSE) == 0) {
      throw StateError('Windows helper IO did not complete.');
    }
    return count.value;
  } finally {
    CloseHandle(event);
  }
}

void _verifyServer(int pid, Arena arena) {
  // Querying a LocalSystem process token is forbidden to ordinary users. SCM
  // supplies the authoritative service PID, account and protected binary path.
  final manager = OpenSCManager(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (manager == 0) {
    throw StateError('Cannot query Windows Service Manager.');
  }
  try {
    final service = OpenService(
        manager,
        'app.flclashm.client.helper'.toNativeUtf16(allocator: arena),
        SERVICE_QUERY_STATUS | _serviceQueryConfig);
    if (service == 0) {
      throw StateError('Windows helper service is not installed.');
    }
    try {
      final status = arena<SERVICE_STATUS_PROCESS>();
      final required = arena<Uint32>();
      if (QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO, status.cast(),
                  sizeOf<SERVICE_STATUS_PROCESS>(), required) ==
              0 ||
          status.ref.dwCurrentState != SERVICE_RUNNING ||
          status.ref.dwProcessId != pid ||
          status.ref.dwServiceType != SERVICE_WIN32_OWN_PROCESS) {
        throw StateError(
            'Named pipe is not owned by the installed running service.');
      }
      QueryServiceConfig(service, nullptr, 0, required);
      if (required.value == 0 || required.value > 65536) {
        throw StateError('Invalid helper service configuration.');
      }
      final config = arena<Uint8>(required.value).cast<QUERY_SERVICE_CONFIG>();
      if (QueryServiceConfig(service, config, required.value, required) == 0) {
        throw StateError('Cannot read helper service configuration.');
      }
      final account =
          config.ref.lpServiceStartName.toDartString().toLowerCase();
      if (account != 'localsystem' && account != r'nt authority\system') {
        throw StateError('Windows helper must run as LocalSystem.');
      }
      final folder = arena<Pointer<Utf16>>();
      final id =
          Guid.parse(FOLDERID_ProgramFiles).toNativeGUID(allocator: arena);
      if (SHGetKnownFolderPath(id, 0, 0, folder) < 0) {
        throw StateError('Cannot locate Program Files.');
      }
      final String root;
      try {
        root = folder.value.toDartString();
      } finally {
        CoTaskMemFree(folder.value);
      }
      final expected = path.windows.join(root, 'FlClashM', 'runtimes',
          'windows', 'x86_64', 'app.flclashm.client.helper.exe');
      var actual = config.ref.lpBinaryPathName.toDartString().trim();
      if (actual.startsWith('"') && actual.endsWith('"')) {
        actual = actual.substring(1, actual.length - 1);
      }
      if (path.windows.normalize(actual).toLowerCase() !=
          path.windows.normalize(expected).toLowerCase()) {
        throw StateError('Windows service points to an unexpected executable.');
      }
    } finally {
      CloseServiceHandle(service);
    }
  } finally {
    CloseServiceHandle(manager);
  }
}

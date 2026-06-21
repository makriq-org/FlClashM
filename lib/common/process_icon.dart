import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart';
import 'package:win32/win32.dart';

/// connectionId -> originating process exe path, captured from the raw getConnections
/// JSON (mihomo sends `metadata.processPath`, which the Connection model drops). Used
/// to extract the app icon on desktop. Rebuilt on every getConnections poll.
final Map<String, String> connectionProcessPaths = {};

// exePath -> decoded icon, cached so the 2s re-poll doesn't re-extract via Win32.
final Map<String, Future<ImageProvider?>> _winIconCache = {};

/// Icon of the process that owns [connectionId] on Windows (its exe icon), or null
/// when the path is unknown / extraction fails. Cached per exe path.
Future<ImageProvider?>? windowsProcessIcon(String connectionId) {
  final path = connectionProcessPaths[connectionId];
  if (path == null || path.isEmpty) return null;
  return _winIconCache.putIfAbsent(path, () => _loadWindowsIcon(path));
}

// Win32 icon extraction runs synchronously on the UI thread; serialize it so a
// single list build can't fire a dozen extractions in one frame (which made the
// page feel heavy). Each extraction yields a frame, spreading the work out.
Future<void> _extractQueue = Future.value();

Future<ImageProvider?> _loadWindowsIcon(String exePath) {
  final completer = Completer<ImageProvider?>();
  _extractQueue = _extractQueue.then((_) async {
    try {
      final bytes = await _extractIconBytes(exePath);
      completer.complete(bytes == null ? null : MemoryImage(bytes));
    } catch (_) {
      completer.complete(null);
    }
    await Future<void>.delayed(Duration.zero);
  });
  return completer.future;
}

// SHGetFileInfo(exe) -> HICON -> GetIconInfo -> GetDIBits(32bpp) -> BGRA pixels ->
// ui.Image -> PNG bytes.
Future<Uint8List?> _extractIconBytes(String exePath) async {
  final pathPtr = exePath.toNativeUtf16();
  final shfi = calloc<SHFILEINFO>();
  var hIcon = 0;
  try {
    final res = SHGetFileInfo(
      pathPtr,
      0,
      shfi,
      sizeOf<SHFILEINFO>(),
      SHGFI_FLAGS.SHGFI_ICON | SHGFI_FLAGS.SHGFI_LARGEICON,
    );
    if (res == 0) return null;
    hIcon = shfi.ref.hIcon;
    if (hIcon == 0) return null;
    return await _hIconToPng(hIcon);
  } finally {
    if (hIcon != 0) DestroyIcon(hIcon);
    free(pathPtr);
    free(shfi);
  }
}

Future<Uint8List?> _hIconToPng(int hIcon) async {
  final iconInfo = calloc<ICONINFO>();
  final bmp = calloc<BITMAP>();
  final bi = calloc<BITMAPINFO>();
  var hbmColor = 0;
  var hbmMask = 0;
  var hdc = 0;
  Pointer<Uint8>? buffer;
  try {
    if (GetIconInfo(hIcon, iconInfo) == 0) return null;
    hbmColor = iconInfo.ref.hbmColor;
    hbmMask = iconInfo.ref.hbmMask;
    if (hbmColor == 0) return null;
    if (GetObject(hbmColor, sizeOf<BITMAP>(), bmp.cast()) == 0) return null;

    final w = bmp.ref.bmWidth;
    final h = bmp.ref.bmHeight;
    if (w <= 0 || h <= 0) return null;

    bi.ref.bmiHeader.biSize = sizeOf<BITMAPINFOHEADER>();
    bi.ref.bmiHeader.biWidth = w;
    bi.ref.bmiHeader.biHeight = -h; // top-down
    bi.ref.bmiHeader.biPlanes = 1;
    bi.ref.bmiHeader.biBitCount = 32;
    bi.ref.bmiHeader.biCompression = BI_COMPRESSION.BI_RGB;

    final count = w * h;
    buffer = calloc<Uint8>(count * 4);
    hdc = GetDC(NULL);
    final got = GetDIBits(
      hdc,
      hbmColor,
      0,
      h,
      buffer.cast(),
      bi,
      DIB_USAGE.DIB_RGB_COLORS,
    );
    if (got == 0) return null;

    final bgra = Uint8List.fromList(buffer.asTypedList(count * 4));
    // BI_RGB leaves alpha undefined; if the whole alpha channel came back zero the
    // image would be fully transparent — force it opaque so the icon shows.
    var hasAlpha = false;
    for (var i = 3; i < bgra.length; i += 4) {
      if (bgra[i] != 0) {
        hasAlpha = true;
        break;
      }
    }
    if (!hasAlpha) {
      for (var i = 3; i < bgra.length; i += 4) {
        bgra[i] = 0xFF;
      }
    }

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bgra,
      w,
      h,
      ui.PixelFormat.bgra8888,
      completer.complete,
    );
    final image = await completer.future;
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return png?.buffer.asUint8List();
  } finally {
    if (hdc != 0) ReleaseDC(NULL, hdc);
    if (hbmColor != 0) DeleteObject(hbmColor);
    if (hbmMask != 0) DeleteObject(hbmMask);
    if (buffer != null) free(buffer);
    free(iconInfo);
    free(bmp);
    free(bi);
  }
}

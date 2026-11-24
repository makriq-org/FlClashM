# qWDTT

Собран из форка [`makriq-org/qwdtt`](https://github.com/makriq-org/qwdtt) по
закреплённому коммиту из `lib/product/runtime/qwdtt_release.dart`.
Используется расширенный SOCKS5-режим qwdtt: `-config <файл>` без секретов в
аргументах процесса.

- `qwdtt.bin` — Android-исполняемый файл для соответствующего ABI;
- `release.txt` — пин коммита, версия Go/NDK и SHA-256 артефактов;
- сборка: `dart setup.dart android --out runtime-assets`.

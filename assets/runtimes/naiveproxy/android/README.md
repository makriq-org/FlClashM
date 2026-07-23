# Android-артефакты NaiveProxy

`dart setup.dart android --out runtime-assets` загружает закреплённые APK
NaiveProxy, извлекает `lib/<abi>/libnaive.so` и проверяет SHA-256 для
`armeabi-v7a`, `arm64-v8a` и `x86_64`.

Версия upstream, имена APK и digest каждого ABI зафиксированы в `release.txt` и
контракте `lib/product/runtime/naiveproxy_release.dart`. Не заменяйте binary без
одновременного обновления обоих источников истины и runtime tests.

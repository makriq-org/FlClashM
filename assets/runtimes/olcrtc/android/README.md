# Android-артефакты OlcRTC

Исполняемые файлы пересобираются из закреплённого commit командой:

```bash
dart setup.dart android --out runtime-assets
```

`lib/product/runtime/olcrtc_release.dart` закрепляет commit, версии Go/Android
NDK и SHA-256 каждого ABI. `release.txt` дублирует воспроизводимые build inputs.
Setup и тесты отклоняют изменённый или устаревший binary даже при совпадающем
текстовом stamp.

OlcRTC содержит штатные словари имён внутри executable. Сгенерированный config
сохраняет обязательное `data: data`, но отдельный runtime-каталог словарей не
поставляется: отсутствующие внешние файлы считаются необязательным override.

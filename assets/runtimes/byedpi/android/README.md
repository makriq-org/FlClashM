# Android-артефакты ByeDPI

`ciadpi` собирается из закреплённого commit
[hufrea/byedpi](https://github.com/hufrea/byedpi). Список
`byebyeedpi-strategies.list` берётся из закреплённого commit
[romanvht/ByeByeDPI](https://github.com/romanvht/ByeByeDPI) по GPL-3.0.

Источник, commit и отображение ABI зафиксированы в `release.txt`. Каждая
непустая строка списка — аргументы `ciadpi` без имени executable. Артефакты
обновляются командой:

```bash
dart setup.dart android --out runtime-assets
```

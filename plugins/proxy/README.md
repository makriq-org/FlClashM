# proxy

Внутренний legacy-плагин FlClashX для переключения системного proxy на desktop.
Windows использует MethodChannel, Linux и macOS — платформенные системные
команды из Dart.

Плагин сохраняется для совместимости с апстримной базой и не входит в
поддерживаемый Android-релиз FlClashM. Это не proxy engine приложения и не
обёртка над встроенными NaiveProxy, ByeDPI или OlcRTC.

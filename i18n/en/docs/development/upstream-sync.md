# Upstream sync

FlClashM is built on top of FlClashX. Product logic is separated to keep updates cheap.

## Principle

- Product logic lives in `lib/product/**`
- Code outside `lib/product/**` accesses it only through integration points

## Update process

1. Pull FlClashX into a separate branch
2. Resolve conflicts in `lib/product/**`
3. Outside `lib/product/**`, only touch files from `tool/product_touchpoints.json`
4. After merging, run checks:

```bash
dart tool/check_product_boundaries.dart
dart tool/check_upstream_drift.dart
dart tool/check_release_continuity.dart
flutter test test/product
```

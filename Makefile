.PHONY: deps dev install-dev test analyze boundaries release-contract drift check \
	fetch-upstream release clean cleanLocal android_arm64 android_app \
	android_stable android_arm64_core
.NOTPARALLEL: check

ANALYZE_PATHS := lib/product test/product test/tool \
	tool/check_product_boundaries.dart \
	tool/check_release_continuity.dart \
	tool/check_android_release_artifacts.dart \
	tool/check_android_release_signing.dart \
	tool/write_release_metadata.dart \
	tool/release_contract.dart \
	setup.dart lib/common/constant.dart lib/core_version.dart

deps:
	flutter pub get

dev: deps
	dart ./setup.dart android --arch arm64 --out core
	flutter build apk --debug --target-platform android-arm64

install-dev: dev
	adb install -r build/app/outputs/flutter-apk/app-debug.apk

test: deps
	flutter test test/product test/tool

analyze: deps
	flutter analyze --fatal-infos $(ANALYZE_PATHS)

boundaries:
	dart tool/check_product_boundaries.dart

release-contract:
	dart tool/check_release_continuity.dart

drift:
	dart tool/check_base_drift.dart

check: boundaries release-contract drift test analyze

fetch-upstream:
	git fetch upstream
	git fetch origin

release: deps
	@test -f android/app/keystore.jks || { \
		echo "Не найден android/app/keystore.jks" >&2; exit 1; \
	}
	@grep -q '^storePassword=' android/local.properties && \
		grep -q '^keyAlias=' android/local.properties && \
		grep -q '^keyPassword=' android/local.properties || { \
		echo "В android/local.properties не заданы параметры подписи" >&2; exit 1; \
	}
	dart ./setup.dart android --env stable
	dart tool/check_android_release_signing.dart dist/*.apk dist/*.aab

clean:
	rm -rf dist build

android_arm64: deps
	dart ./setup.dart android --arch arm64
android_app: deps
	dart ./setup.dart android
android_stable: deps
	dart ./setup.dart android --env stable
android_arm64_core: deps
	dart ./setup.dart android --arch arm64 --out core
cleanLocal: clean

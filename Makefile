.PHONY: deps dev install-dev test analyze analyze-app boundaries actions-pinning release-contract drift check go-check \
	fetch-upstream release clean cleanLocal android_arm64 android_app \
	android_stable android_arm64_core
.NOTPARALLEL: check

ANALYZE_PATHS := lib/product test/product test/tool \
	tool/check_product_boundaries.dart \
	tool/check_actions_pinning.dart \
	tool/check_release_continuity.dart \
	tool/check_android_release_artifacts.dart \
	tool/check_android_release_signing.dart \
	tool/write_release_metadata.dart \
	tool/write_app_update_manifest.dart \
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

analyze-app: deps
	flutter analyze --no-fatal-infos --no-fatal-warnings lib

boundaries:
	dart tool/check_product_boundaries.dart

actions-pinning:
	dart tool/check_actions_pinning.dart

release-contract:
	dart tool/check_release_continuity.dart

drift:
	dart tool/check_base_drift.dart

check: boundaries actions-pinning release-contract drift test analyze-app analyze

go-check:
	bash tool/prepare_core.sh
	cd core && test -z "$$(gofmt -l backend)"
	cd core && GOFLAGS=-mod=vendor go vet ./...
	cd core && GOFLAGS=-mod=vendor CGO_ENABLED=0 go test ./...
	cd core && GOFLAGS=-mod=vendor CGO_ENABLED=1 go test -race ./...

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

android_arm64:
	dart ./setup.dart android --arch arm64
android_app:
	dart ./setup.dart android
android_stable:
	dart ./setup.dart android --env stable
android_arm64_core:
	dart ./setup.dart android --arch arm64 --out core
cleanLocal:
	rm -rf dist
	rm -rf build

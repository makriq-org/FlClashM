pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        flutterSdkPath
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}



plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.4.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.21" apply false
    id("org.jetbrains.kotlin.plugin.parcelize") version "2.4.21" apply false
}


include(":app")
include(":core")
include(":common")
include(":service")

// Gradle 9 requires native plugin project directories to be writable. Flutter
// SDK plugins (notably integration_test) live in the immutable Nix store.
// Build a disposable source copy; never modify the SDK or its permissions.
rootProject.children.forEach { descriptor ->
    val source = descriptor.projectDir
    if (source.absolutePath.startsWith("/nix/store/")) {
        val identity = java.security.MessageDigest.getInstance("SHA-256")
            .digest(source.canonicalPath.toByteArray())
            .joinToString("") { "%02x".format(it) }
        val destination = file(".gradle/nix-sdk-plugins/${descriptor.name}-$identity")
        val complete = destination.resolve(".source-complete")
        if (!complete.isFile) {
            destination.deleteRecursively()
            check(source.copyRecursively(destination, overwrite = true)) {
                "Could not prepare writable SDK plugin ${descriptor.name}"
            }
            complete.writeText(source.canonicalPath)
        }
        descriptor.projectDir = destination
    }
}

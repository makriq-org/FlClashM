import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val localPropertiesFile = rootProject.file("local.properties")
val localProperties = Properties().apply {
    if (localPropertiesFile.exists()) {
        localPropertiesFile.inputStream().use { load(it) }
    }
}

val mStoreFile: File = file("keystore.jks")
val mStorePassword: String? = localProperties.getProperty("storePassword")
val mKeyAlias: String? = localProperties.getProperty("keyAlias")
val mKeyPassword: String? = localProperties.getProperty("keyPassword")
val mStoreType: String? = detectKeystoreType(mStoreFile)
val isRelease = mStoreFile.exists()
        && !mStorePassword.isNullOrBlank()
        && !mKeyAlias.isNullOrBlank()
        && !mKeyPassword.isNullOrBlank()
        && mStoreType != null
val isBackendTest = providers.gradleProperty("backendTest").orNull == "true"

android {
    namespace = "com.follow.clashx"
    compileSdk = 37
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.makriq.flclash"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        manifestPlaceholders["appLabel"] = if (isBackendTest) "FlClashM Backend Test" else "FlClashM"
    }

    signingConfigs {
        if (isRelease) {
            create("release") {
                storeFile = mStoreFile
                storePassword = mStorePassword
                keyAlias = mKeyAlias
                keyPassword = mKeyPassword
                storeType = mStoreType
            }
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
            applicationIdSuffix = if (isBackendTest) ".backendtest" else ".dev"
        }

        release {
            isMinifyEnabled = true
            isShrinkResources = true
            isDebuggable = false

            if (isBackendTest) {
                signingConfig = signingConfigs.getByName("debug")
                applicationIdSuffix = ".backendtest"
            } else if (isRelease) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                signingConfig = signingConfigs.getByName("debug")
                applicationIdSuffix = ".dev"
            }

            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation(project(":core"))
    implementation(project(":common"))
    implementation(project(":service"))
    implementation("androidx.core:core-splashscreen:1.2.0")
    implementation("androidx.appcompat:appcompat:1.8.0")
    implementation("com.google.code.gson:gson:2.14.0")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    testImplementation(kotlin("test"))
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
}

fun detectKeystoreType(file: File): String? {
    if (!file.exists()) return null
    val header = ByteArray(4)
    val bytesRead = file.inputStream().use { input ->
        input.read(header)
    }
    if (bytesRead != header.size) return null

    val jksMagic = byteArrayOf(
        0xFE.toByte(),
        0xED.toByte(),
        0xFE.toByte(),
        0xED.toByte(),
    )

    return if (header.contentEquals(jksMagic)) {
        "JKS"
    } else {
        "PKCS12"
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

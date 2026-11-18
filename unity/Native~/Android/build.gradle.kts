plugins {
    id("com.android.library") version "8.9.2"
    id("com.android.application") version "8.9.2" apply false
}

android {
    namespace = "com.gamepropel.unity"
    compileSdk = 35
    defaultConfig { minSdk = 24; consumerProguardFiles("consumer-rules.pro") }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
}

dependencies {
    compileOnly(files(providers.gradleProperty("nativeSdkAar").getOrElse("../../build/android/gamealgo-android-release.aar")))
}

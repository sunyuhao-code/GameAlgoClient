plugins { id("com.android.application") version "8.9.2" }

android {
    namespace = "com.gamepropel.makerprobe"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.gamepropel.makerprobe"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1"
        ndk { abiFilters += "arm64-v8a" }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
    sourceSets.getByName("main").assets.srcDir("build/probe-assets")
}

dependencies {
    implementation("party.iroiro.luajava:lua54:4.1.0")
    runtimeOnly("party.iroiro.luajava:android:4.1.0:lua54@aar")
}

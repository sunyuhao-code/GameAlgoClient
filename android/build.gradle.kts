plugins {
    id("com.android.library") version "8.9.2"
    id("com.android.application") version "8.9.2" apply false
}

group = "com.gamealgo"
version = providers.gradleProperty("sdkVersion").getOrElse("0.0.0-dev")

android {
    namespace = "com.gamealgo.sdk"
    compileSdk = 35

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
        buildConfigField("String", "VERSION_NAME", "\"${project.version}\"")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    buildFeatures {
        buildConfig = true
    }

}

tasks.withType<JavaCompile>().configureEach {
    exclude("com/gamealgo/sdk/JavaxScriptGameAlgoRuntime.java")
}

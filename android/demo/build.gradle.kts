plugins {
    id("com.android.application")
}

val gameAlgoAarPath = providers.gradleProperty("gameAlgoAar").getOrElse(
    rootProject.layout.buildDirectory.file("outputs/aar/gamealgo-android-release.aar").get().asFile.absolutePath
)

android {
    namespace = "com.gamealgo.demo"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.gamealgo.demo"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
}

dependencies {
    implementation(files(gameAlgoAarPath))
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}

val verifyGameAlgoAar by tasks.registering {
    doLast {
        check(file(gameAlgoAarPath).isFile) {
            "GameAlgo AAR not found at $gameAlgoAarPath. Run ./test-aar-integration.sh from android/."
        }
    }
}

tasks.named("preBuild").configure {
    dependsOn(verifyGameAlgoAar)
}

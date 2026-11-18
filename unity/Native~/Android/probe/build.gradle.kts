plugins { id("com.android.application") }
android {
    namespace = "com.gamepropel.unityprobe"
    compileSdk = 35
    defaultConfig { applicationId = "com.gamepropel.unityprobe"; minSdk = 24; targetSdk = 35; versionCode = 1; versionName = "1.0" }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_1_8; targetCompatibility = JavaVersion.VERSION_1_8 }
}
dependencies {
    implementation(project(":"))
    implementation(files(providers.gradleProperty("nativeSdkAar").getOrElse("../../../Runtime/Plugins/Android/gamealgo-android.aar")))
}

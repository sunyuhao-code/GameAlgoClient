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

    sourceSets {
        getByName("main").jniLibs.srcDir(layout.buildDirectory.dir("generated/jniLibs"))
    }

}

val rustRuntimeRawOutput = layout.buildDirectory.dir("generated/rustRuntimeRaw")
val rustRuntimeOutput = layout.buildDirectory.dir("generated/jniLibs")

val buildRustRuntime by tasks.registering(Exec::class) {
    group = "build"
    description = "Builds the packaged Rust strategy runtime for supported Android ABIs."
    workingDir = file("../runtime/rust")
    inputs.files(fileTree("../runtime/rust") {
        include("Cargo.toml", "Cargo.lock", "src/**")
    })
    outputs.dir(rustRuntimeRawOutput)
    environment(
        "RUSTFLAGS",
        listOfNotNull(
            System.getenv("RUSTFLAGS")?.takeIf { it.isNotBlank() },
            "-C link-arg=-Wl,-z,max-page-size=16384",
            "-C link-arg=-Wl,-z,common-page-size=16384",
        ).joinToString(" ")
    )
    commandLine(
        "cargo", "ndk",
        "-t", "armeabi-v7a",
        "-t", "arm64-v8a",
        "-t", "x86_64",
        "--platform", "24",
        "-o", rustRuntimeRawOutput.get().asFile.absolutePath,
        "build", "--release", "--locked",
    )
}

val sanitizeRustRuntime by tasks.registering(Exec::class) {
    dependsOn(buildRustRuntime)
    inputs.dir(rustRuntimeRawOutput)
    inputs.file(file("sanitize-native-runtime.sh"))
    outputs.dir(rustRuntimeOutput)
    commandLine(
        file("sanitize-native-runtime.sh").absolutePath,
        rustRuntimeRawOutput.get().asFile.absolutePath,
        rustRuntimeOutput.get().asFile.absolutePath,
    )
}

tasks.named("preBuild").configure {
    dependsOn(sanitizeRustRuntime)
}

tasks.withType<JavaCompile>().configureEach {
    exclude("com/gamealgo/sdk/JavaxScriptGameAlgoRuntime.java")
}

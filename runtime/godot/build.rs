fn main() {
    println!("cargo:rerun-if-changed=src/ios_lifecycle.m");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("ios") {
        cc::Build::new()
            .file("src/ios_lifecycle.m")
            .flag("-fobjc-arc")
            .flag("-fblocks")
            .warnings_into_errors(true)
            .compile("gamealgo_godot_lifecycle");
        println!("cargo:rustc-link-lib=framework=Foundation");
        println!("cargo:rustc-link-lib=framework=UIKit");
    }
}

use std::env;
use std::path::PathBuf;

fn main() {
    let crate_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    let out_dir = PathBuf::from(&crate_dir).join("include");
    std::fs::create_dir_all(&out_dir).unwrap();
    let out_file = out_dir.join("BBCore.h");

    let config =
        cbindgen::Config::from_file(PathBuf::from(&crate_dir).join("cbindgen.toml")).unwrap();

    cbindgen::Builder::new()
        .with_crate(&crate_dir)
        .with_config(config)
        .generate()
        .expect("cbindgen failed")
        .write_to_file(&out_file);

    println!("cargo:rerun-if-changed=build.rs");
    // `src/lib.rs` is the only rust source today, but watching `src/`
    // future-proofs the rerun trigger: a new file under src/ that
    // declares types consumed by cbindgen would otherwise not be
    // picked up until the next unrelated rebuild. Audit rust-build F3.
    println!("cargo:rerun-if-changed=src");
    println!("cargo:rerun-if-changed=src/lib.rs");
    println!("cargo:rerun-if-changed=cbindgen.toml");
}

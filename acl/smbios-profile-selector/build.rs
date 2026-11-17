// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use std::{env, fs, path::Path};

fn main() {
    let out_dir = env::var_os("OUT_DIR").expect("Cargo did not set OUT_DIR");
    let sbat = include_str!("sbat.csv.template").replace("<VERSION>", env!("CARGO_PKG_VERSION"));
    fs::write(Path::new(&out_dir).join("sbat.csv"), sbat).expect("Cannot write generated SBAT metadata");

    println!("cargo::rerun-if-changed=sbat.csv.template");
    println!("cargo::rerun-if-changed=Cargo.toml");
}

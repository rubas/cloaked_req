// Since rustler 0.39, the crate links the `enif_*` functions directly on Linux.
// The BEAM supplies them when it loads the NIF, but the `cargo test` binary
// runs without a BEAM. Let the linker leave them unresolved: the tests never
// call them, and a shared library already allows unresolved symbols.
fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        println!("cargo:rustc-link-arg=-Wl,--unresolved-symbols=ignore-in-object-files");
    }
}

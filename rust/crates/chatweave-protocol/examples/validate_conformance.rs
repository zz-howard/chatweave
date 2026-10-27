#[path = "../tests/support/mod.rs"]
mod support;

fn main() {
    let root = std::env::args_os().nth(1).map(std::path::PathBuf::from)
        .unwrap_or_else(support::repository);
    match support::run(&root) {
        Ok(count) => println!("validated {count} conformance cases (Schema, semantics, Limits)"),
        Err(error) => { eprintln!("{error}"); std::process::exit(1); }
    }
}

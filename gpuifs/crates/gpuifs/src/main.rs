//! The `gpuifs` binary. CLI and lifecycle are W4's (`cli.rs`, `lifecycle.rs`);
//! the GPUI side is `host::run` (W5b).

mod cli;
mod lifecycle;

fn main() {
    let args = cli::Args::from_env();
    std::process::exit(lifecycle::run(args));
}

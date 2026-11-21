//! W4: `gpuifs [-t title] [-k] [--root builtin|DIR] [--dir HOSTDIR[:DST]]... [h9 flags] cmd [arg...]`,
//! `gpuifs [-t title] -a addr [-insecure]`, and dev-only `--headless`.

#[allow(dead_code)]
#[derive(Debug, Clone, Default)]
pub struct Args {
    pub title: Option<String>,
    pub keep: bool,
    pub root: Option<String>,
    pub dirs: Vec<String>,
    pub policy_flags: Vec<String>,
    pub addr: Option<String>,
    pub insecure: bool,
    pub headless: bool,
    pub cmd: Vec<String>,
}

impl Args {
    pub fn from_env() -> Self {
        todo!("W4")
    }
}

//! W4: `gpuifs [-t title] [-k] [--root builtin|DIR] [--dir HOSTDIR[:DST]]... [h9 flags] cmd [arg...]`,
//! `gpuifs [-t title] -a addr [-insecure]`, and dev-only `--headless`.

pub const USAGE: &str = "\
usage: gpuifs [-t title] [-k] [--root builtin|DIR (default $H9ROOT, else builtin)] [--dir HOSTDIR[:DST]]...
              [--env name=value]... [h9 sandbox flags] cmd [arg...]
       gpuifs [-t title] [-k] -a unix!PATH|tcp!HOST!PORT [-insecure] [cmd [arg...]]
       gpuifs --headless ...   (no window: the tree alone, with a trace on stderr)

h9 sandbox flags, as h9 takes them:
  --profile default|tight  --sandbox DIR  --readable PATH  --writable PATH
  --read-deny PATH  --write none|scope|ephemeral|overlay
  --net disable|outbound|enable  --net-allow PATTERN  --memory SIZE
  --timeout DURATION  --pids N  --cpus N  --backend auto|hvf|kvm|whp|native|emu
  --arch arm64|amd64|386  --host-fs  --no-guest-tools
";

#[derive(Debug, Clone, Default, PartialEq, Eq)]
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
    /// `--env name=value`: extra guest environment variables.
    pub env: Vec<String>,
}

impl Args {
    pub fn from_env() -> Self {
        let argv: Vec<String> = std::env::args().skip(1).collect();
        match Args::parse(&argv) {
            Ok(a) => a,
            Err(e) if e.is_empty() => {
                print!("{USAGE}");
                std::process::exit(0);
            }
            Err(e) => {
                eprintln!("gpuifs: {e}\n{USAGE}");
                std::process::exit(2);
            }
        }
    }

    /// Parses the arguments after argv[0]. Flags stop at the first
    /// argument that isn't one (the command) or at `--`. An empty error
    /// means `-h`.
    pub fn parse(argv: &[String]) -> Result<Args, String> {
        let mut a = Args::default();
        let mut i = 0;
        // `--name=value` or `--name value`.
        let value = |i: &mut usize, name: &str| -> Result<Option<String>, String> {
            let arg = &argv[*i];
            if let Some(v) = arg.strip_prefix(name).and_then(|r| r.strip_prefix('=')) {
                return Ok(Some(v.to_string()));
            }
            if arg != name {
                return Ok(None);
            }
            *i += 1;
            argv.get(*i).cloned().map(Some).ok_or_else(|| format!("{name} needs a value"))
        };
        while i < argv.len() {
            let arg = argv[i].as_str();
            if arg == "--" {
                i += 1;
                break;
            }
            if !arg.starts_with('-') || arg == "-" {
                break;
            }
            match arg {
                "-h" | "--help" => return Err(String::new()),
                "-k" => a.keep = true,
                "-insecure" | "--insecure" => a.insecure = true,
                "--headless" => a.headless = true,
                _ if h9sys::POLICY_SWITCHES.contains(&arg) => a.policy_flags.push(arg.to_string()),
                _ => {
                    if let Some(v) = value(&mut i, "-t")? {
                        a.title = Some(v);
                    } else if let Some(v) = value(&mut i, "-a")? {
                        a.addr = Some(v);
                    } else if let Some(v) = value(&mut i, "--root")? {
                        a.root = Some(v);
                    } else if let Some(v) = value(&mut i, "--dir")? {
                        a.dirs.push(v);
                    } else if let Some(v) = value(&mut i, "--env")? {
                        if !v.contains('=') || v.starts_with('=') {
                            return Err(format!("--env {v}: want name=value"));
                        }
                        a.env.push(v);
                    } else if let Some(name) = h9sys::POLICY_FLAGS
                        .iter()
                        .find(|f| arg == **f || arg.strip_prefix(**f).is_some_and(|r| r.starts_with('=')))
                    {
                        let v = value(&mut i, name)?.unwrap();
                        a.policy_flags.push(name.to_string());
                        a.policy_flags.push(v);
                    } else {
                        return Err(format!("unknown flag {arg}"));
                    }
                }
            }
            i += 1;
        }
        a.cmd = argv[i..].to_vec();
        a.check()?;
        Ok(a)
    }

    fn check(&self) -> Result<(), String> {
        if self.cmd.is_empty() && self.addr.is_none() {
            return Err("no command, and no -a address to serve".into());
        }
        if let Some(addr) = &self.addr {
            match ninep::transport::parse_addr(addr)? {
                ninep::transport::Addr::Tcp(..) if !self.insecure => {
                    return Err("-a tcp!... serves the whole app to anyone who connects; add -insecure if you mean it".into());
                }
                ninep::transport::Addr::Stdio if !self.cmd.is_empty() => {
                    return Err("-a - serves on stdin and stdout, which the client's output would share".into());
                }
                _ => {}
            }
        }
        if let Some(r) = &self.root {
            if r != "builtin" && r.is_empty() {
                return Err("--root needs builtin or a directory".into());
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> Result<Args, String> {
        Args::parse(&s.split_whitespace().map(String::from).collect::<Vec<_>>())
    }

    #[test]
    fn basic() {
        let a = p("-t Notes rc ./notes.rc -x").unwrap();
        assert_eq!(a.title.as_deref(), Some("Notes"));
        assert_eq!(a.cmd, ["rc", "./notes.rc", "-x"]);
        assert!(!a.keep && !a.headless);
    }

    #[test]
    fn flags_stop_at_cmd() {
        let a = p("-k rc -k").unwrap();
        assert!(a.keep);
        assert_eq!(a.cmd, ["rc", "-k"]);
        let a = p("-- -weird").unwrap();
        assert_eq!(a.cmd, ["-weird"]);
    }

    #[test]
    fn root_dirs_env() {
        let a = p("--root=/r --dir ./alpine:#L --dir x:/n/x --env a=b rc").unwrap();
        assert_eq!(a.root.as_deref(), Some("/r"));
        assert_eq!(a.dirs, ["./alpine:#L", "x:/n/x"]);
        assert_eq!(a.env, ["a=b"]);
        assert!(p("--env nope rc").is_err());
    }

    #[test]
    fn policy_passthrough() {
        let a = p("--net disable --timeout=1m --host-fs --profile tight rc").unwrap();
        assert_eq!(a.policy_flags, ["--net", "disable", "--timeout", "1m", "--host-fs", "--profile", "tight"]);
        assert!(p("--net").is_err());
        // --net-allow isn't --net with a suffix.
        let a = p("--net-allow tcp!*!80 rc").unwrap();
        assert_eq!(a.policy_flags, ["--net-allow", "tcp!*!80"]);
    }

    #[test]
    fn addr() {
        let a = p("-a unix!/tmp/g.sock").unwrap();
        assert!(a.cmd.is_empty());
        assert_eq!(a.addr.as_deref(), Some("unix!/tmp/g.sock"));
        assert!(p("-a tcp!localhost!5640").is_err());
        let a = p("-a tcp!localhost!5640 -insecure").unwrap();
        assert!(a.insecure);
        assert!(p("-a tcp!x!port -insecure").is_err());
        assert!(p("-a nonsense").is_err());
        assert!(p("-a - rc x.rc").is_err());
        assert!(p("-a -").is_ok());
    }

    #[test]
    fn errors() {
        assert!(p("").is_err());
        assert!(p("-t").is_err());
        assert!(p("--bogus rc").is_err());
        assert_eq!(p("-h"), Err(String::new()));
        assert!(p("--headless rc x.rc").unwrap().headless);
    }
}

use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result, bail};

fn command(dir: &Path) -> Command {
    let mut c = Command::new("git");
    c.arg("-C")
        .arg(dir)
        .arg("--no-optional-locks")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("LC_ALL", "C")
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(std::process::Stdio::null());
    c
}

pub fn run(dir: &Path, args: &[&str]) -> Result<String> {
    let out = command(dir)
        .args(args)
        .output()
        .with_context(|| format!("run git {}", args.join(" ")))?;
    if !out.status.success() {
        bail!(
            "git {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

pub fn try_run(dir: &Path, args: &[&str]) -> Option<String> {
    run(dir, args).ok()
}

pub fn batch_ssh(existing: Option<&str>) -> String {
    match existing {
        Some(cmd) if !cmd.trim().is_empty() => format!("{cmd} -o BatchMode=yes"),
        _ => "ssh -o BatchMode=yes".to_string(),
    }
}

/// BatchMode keeps ssh from prompting on /dev/tty, which would draw over the TUI and
/// hang the fetch thread.
pub fn fetch(dir: &Path) -> Result<()> {
    let ssh = batch_ssh(std::env::var("GIT_SSH_COMMAND").ok().as_deref());
    let out = command(dir)
        .env("GIT_SSH_COMMAND", ssh)
        .args(["fetch", "--prune", "origin"])
        .output()
        .context("run git fetch")?;
    if !out.status.success() {
        bail!("git fetch: {}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fetch_never_prompts_through_ssh() {
        assert_eq!(batch_ssh(None), "ssh -o BatchMode=yes");
        assert_eq!(batch_ssh(Some("ssh -i k")), "ssh -i k -o BatchMode=yes");
    }
}

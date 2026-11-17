use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::Deserialize;

use crate::glob::{expand_tilde, wildcard};

#[derive(Clone, Debug)]
pub struct Config {
    pub roots: Vec<PathBuf>,
    pub plan_globs: Vec<String>,
    pub ignore_branches: Vec<String>,
    pub active_days: u64,
    pub stale_fetch_days: u64,
    pub removable_quiet_hours: u64,
    pub tie_window_minutes: u64,
    pub transcript_globs: Vec<String>,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            roots: Vec::new(),
            plan_globs: vec!["~/.cursor/tickets/*/*.plan.md".into()],
            ignore_branches: vec!["archive/*".into(), "backup/*".into()],
            active_days: 14,
            stale_fetch_days: 7,
            removable_quiet_hours: 24,
            tie_window_minutes: 60,
            transcript_globs: vec!["~/.claude*/projects/*/{id}.jsonl".into()],
        }
    }
}

#[derive(Deserialize, Default)]
#[serde(default, deny_unknown_fields)]
struct FileConfig {
    roots: Option<Vec<String>>,
    plan_globs: Option<Vec<String>>,
    ignore_branches: Option<Vec<String>>,
    active_days: Option<u64>,
    stale_fetch_days: Option<u64>,
    removable_quiet_hours: Option<u64>,
    tie_window_minutes: Option<u64>,
    transcript_globs: Option<Vec<String>>,
}

pub fn path() -> PathBuf {
    match std::env::var_os("WORKVIEW_CONFIG") {
        Some(p) => PathBuf::from(p),
        None => crate::glob::home().join(".config/harness/workview.toml"),
    }
}

pub fn load() -> Result<Config> {
    let p = path();
    match std::fs::read_to_string(&p) {
        Ok(text) => parse(&text).with_context(|| format!("read {}", p.display())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Config::default()),
        Err(e) => Err(e).with_context(|| format!("read {}", p.display())),
    }
}

pub fn parse(text: &str) -> Result<Config> {
    let f: FileConfig = toml::from_str(text)?;
    let d = Config::default();
    Ok(Config {
        roots: f
            .roots
            .unwrap_or_default()
            .iter()
            .map(|r| expand_tilde(r))
            .collect(),
        plan_globs: f.plan_globs.unwrap_or(d.plan_globs),
        ignore_branches: f.ignore_branches.unwrap_or(d.ignore_branches),
        active_days: f.active_days.unwrap_or(d.active_days),
        stale_fetch_days: f.stale_fetch_days.unwrap_or(d.stale_fetch_days),
        removable_quiet_hours: f.removable_quiet_hours.unwrap_or(d.removable_quiet_hours),
        tie_window_minutes: f.tie_window_minutes.unwrap_or(d.tie_window_minutes),
        transcript_globs: f.transcript_globs.unwrap_or(d.transcript_globs),
    })
}

impl Config {
    pub fn ignored(&self, branch: &str) -> bool {
        self.ignore_branches.iter().any(|p| wildcard(p, branch))
    }
}

pub fn repos_under(roots: &[PathBuf]) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for root in roots {
        if root.join(".git").exists() {
            out.push(root.clone());
            continue;
        }
        let Ok(entries) = std::fs::read_dir(root) else {
            continue;
        };
        let mut kids: Vec<PathBuf> = entries
            .filter_map(Result::ok)
            .map(|e| e.path())
            .filter(|p| p.join(".git").exists())
            .collect();
        kids.sort();
        out.extend(kids);
    }
    out
}

pub fn enclosing_repo(dir: &Path) -> Option<PathBuf> {
    dir.ancestors()
        .find(|d| d.join(".git").exists())
        .map(Path::to_path_buf)
}

pub fn common_dir(repo: &Path) -> Option<PathBuf> {
    let dotgit = repo.join(".git");
    let git_dir = if dotgit.is_dir() {
        dotgit
    } else {
        let text = std::fs::read_to_string(&dotgit).ok()?;
        let target = text.trim().strip_prefix("gitdir:")?.trim();
        repo.join(target)
    };
    let common = match std::fs::read_to_string(git_dir.join("commondir")) {
        Ok(c) => git_dir.join(c.trim()),
        Err(_) => git_dir,
    };
    common.canonicalize().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_apply_without_keys() {
        let c = parse("roots = [\"/x\"]\nactive_days = 3\n").unwrap();
        assert_eq!(c.roots, vec![PathBuf::from("/x")]);
        assert_eq!(c.active_days, 3);
        assert_eq!(c.removable_quiet_hours, 24);
        assert!(c.ignored("archive/AUS-1"));
        assert!(c.ignored("backup/sah-invoice-mvp-round2"));
        assert!(!c.ignored("subtask/AUS-1-x"));
    }

    #[test]
    fn unknown_keys_are_rejected() {
        assert!(parse("rooots = []").is_err());
    }

    #[test]
    fn monorepo_root_and_its_service_children_are_both_repos() {
        let t = tempfile::tempdir().unwrap();
        let mono = t.path().join("alayacare");
        std::fs::create_dir_all(mono.join(".git")).unwrap();
        for s in ["api.accounting", "webapp"] {
            std::fs::create_dir_all(mono.join("services").join(s).join(".git")).unwrap();
        }
        std::fs::create_dir_all(mono.join("services/_worktrees/x")).unwrap();
        std::fs::create_dir_all(mono.join("services/notes")).unwrap();
        let repos = repos_under(&[mono.clone(), mono.join("services")]);
        assert_eq!(
            repos,
            vec![
                mono.clone(),
                mono.join("services/api.accounting"),
                mono.join("services/webapp"),
            ]
        );
    }

    #[test]
    fn worktree_common_dir_follows_gitdir_and_commondir() {
        let t = tempfile::tempdir().unwrap();
        let main = t.path().join("main");
        let wt_git = main.join(".git/worktrees/wt");
        std::fs::create_dir_all(&wt_git).unwrap();
        std::fs::write(wt_git.join("commondir"), "../..\n").unwrap();
        let wt = t.path().join("wt");
        std::fs::create_dir_all(&wt).unwrap();
        std::fs::write(wt.join(".git"), format!("gitdir: {}\n", wt_git.display())).unwrap();
        let expect = main.join(".git").canonicalize().unwrap();
        assert_eq!(common_dir(&wt), Some(expect.clone()));
        assert_eq!(common_dir(&main), Some(expect));
    }
}

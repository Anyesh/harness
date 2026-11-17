use std::collections::{HashMap, HashSet};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::UNIX_EPOCH;

use crate::base::{self, Candidate, Graph, Subject};
use crate::config::Config;
use crate::git;
use crate::model::Base;
use crate::ticket;

const THREADS: usize = 8;
const HEAD_LOG_TAIL: u64 = 2 * 1024 * 1024;

pub fn par_map<T: Sync, R: Send>(items: &[T], f: impl Fn(&T) -> R + Sync) -> Vec<R> {
    let next = AtomicUsize::new(0);
    let out: Mutex<Vec<Option<R>>> = Mutex::new((0..items.len()).map(|_| None).collect());
    std::thread::scope(|s| {
        for _ in 0..THREADS.min(items.len()) {
            s.spawn(|| {
                loop {
                    let i = next.fetch_add(1, Ordering::Relaxed);
                    if i >= items.len() {
                        break;
                    }
                    let r = f(&items[i]);
                    out.lock().unwrap_or_else(|e| e.into_inner())[i] = Some(r);
                }
            });
        }
    });
    out.into_inner()
        .unwrap_or_else(|e| e.into_inner())
        .into_iter()
        .map(|r| r.expect("every item mapped"))
        .collect()
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BranchRef {
    pub name: String,
    pub tip: String,
    pub upstream: Option<String>,
    pub gone: bool,
    pub commit_time: i64,
    pub subject: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Status {
    pub dirty: bool,
    pub submodule: bool,
}

#[derive(Clone, Debug, Default)]
pub struct Worktree {
    pub path: PathBuf,
    pub git_dir: PathBuf,
    pub head: Option<String>,
    pub branch: Option<String>,
    pub is_main: bool,
    pub locked: bool,
    pub prunable: bool,
    pub status: Option<Status>,
    pub activity: Option<i64>,
    pub touched: Option<i64>,
    pub detached_reachable: Option<bool>,
    pub detached_time: Option<i64>,
    pub detached_subject: String,
}

impl Worktree {
    pub fn dir_name(&self) -> Option<&str> {
        self.path.file_name().and_then(|n| n.to_str())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Detail {
    pub unpushed: Option<u32>,
    pub base: Option<Base>,
    pub merged: bool,
}

#[derive(Clone, Debug, Default)]
pub struct RepoState {
    pub path: PathBuf,
    pub name: String,
    pub common_dir: PathBuf,
    pub remotes: Vec<String>,
    pub default_ref: Option<String>,
    pub default_branch: Option<String>,
    pub fetched: Option<i64>,
    pub branches: Vec<BranchRef>,
    pub remote_refs: HashMap<String, String>,
    pub vscode_bases: HashMap<String, String>,
    pub worktrees: Vec<Worktree>,
    pub errors: Vec<String>,
    pub details: HashMap<String, Detail>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RowSeed {
    pub id: String,
    pub branch: Option<String>,
    pub detached: Option<String>,
    pub tip: String,
    pub upstream: Option<String>,
    pub gone: bool,
    pub commit_time: i64,
    pub subject: String,
    pub worktree_dir: Option<String>,
    pub checkouts: Vec<PathBuf>,
    pub is_default: bool,
}

pub fn mtime(p: &Path) -> Option<i64> {
    let m = std::fs::metadata(p).ok()?.modified().ok()?;
    Some(m.duration_since(UNIX_EPOCH).ok()?.as_secs() as i64)
}

pub fn parse_refs(text: &str) -> (Vec<BranchRef>, HashMap<String, String>, Option<String>) {
    let mut branches = Vec::new();
    let mut remotes = HashMap::new();
    let mut origin_head = None;
    for line in text.lines() {
        let f: Vec<&str> = line.split('\0').collect();
        if f.len() < 7 {
            continue;
        }
        let (refname, tip, symref) = (f[0], f[1], f[2]);
        if let Some(name) = refname.strip_prefix("refs/heads/") {
            branches.push(BranchRef {
                name: name.to_string(),
                tip: tip.to_string(),
                upstream: (!f[3].is_empty()).then(|| f[3].to_string()),
                gone: f[4] == "[gone]",
                commit_time: f[5].parse().unwrap_or(0),
                subject: f[6].to_string(),
            });
        } else if let Some(name) = refname.strip_prefix("refs/remotes/") {
            if name.ends_with("/HEAD") {
                if name == "origin/HEAD" {
                    origin_head = symref.strip_prefix("refs/remotes/").map(str::to_string);
                }
                continue;
            }
            remotes.insert(name.to_string(), tip.to_string());
        }
    }
    (branches, remotes, origin_head)
}

pub fn parse_status(text: &str) -> Status {
    let mut s = Status::default();
    for line in text.lines() {
        let mut f = line.split(' ');
        match f.next() {
            Some("?") => s.dirty = true,
            Some("1" | "2" | "u") => {
                let sub = f.nth(1).unwrap_or("N...");
                if sub.starts_with('S') {
                    s.submodule = true;
                } else {
                    s.dirty = true;
                }
            }
            _ => {}
        }
    }
    s
}

pub fn parse_worktrees(text: &str) -> Vec<Worktree> {
    let mut out = Vec::new();
    for block in text.split("\n\n") {
        let mut wt = Worktree::default();
        let mut seen = false;
        for line in block.lines() {
            let (k, v) = line.split_once(' ').unwrap_or((line, ""));
            match k {
                "worktree" => {
                    wt.path = PathBuf::from(v);
                    seen = true;
                }
                "HEAD" => wt.head = Some(v.to_string()),
                "branch" => {
                    wt.branch = Some(v.strip_prefix("refs/heads/").unwrap_or(v).to_string())
                }
                "locked" => wt.locked = true,
                "prunable" => wt.prunable = true,
                _ => {}
            }
        }
        if seen {
            wt.is_main = out.is_empty();
            out.push(wt);
        }
    }
    out
}

fn parse_config(text: &str) -> (HashMap<String, String>, Vec<String>) {
    let mut bases = HashMap::new();
    let mut remotes = Vec::new();
    for line in text.lines() {
        let Some((k, v)) = line.split_once(' ') else {
            continue;
        };
        if let Some(b) = k
            .strip_prefix("branch.")
            .and_then(|r| r.strip_suffix(".vscode-merge-base"))
        {
            bases.insert(b.to_string(), v.to_string());
        } else if let Some(r) = k
            .strip_prefix("remote.")
            .and_then(|r| r.strip_suffix(".url"))
        {
            remotes.push(r.to_string());
        }
    }
    remotes.sort();
    remotes.dedup();
    (bases, remotes)
}

fn admin_dirs(common: &Path) -> HashMap<PathBuf, PathBuf> {
    let mut map = HashMap::new();
    let Ok(entries) = std::fs::read_dir(common.join("worktrees")) else {
        return map;
    };
    for e in entries.filter_map(Result::ok) {
        let admin = e.path();
        if let Ok(text) = std::fs::read_to_string(admin.join("gitdir")) {
            let dotgit = PathBuf::from(text.trim());
            if let Some(wt) = dotgit.parent() {
                map.insert(wt.to_path_buf(), admin);
            }
        }
    }
    map
}

fn newest(paths: &[PathBuf]) -> Option<i64> {
    paths.iter().filter_map(|p| mtime(p)).max()
}

pub fn scan_repo(path: &Path) -> RepoState {
    let mut repo = RepoState {
        path: path.to_path_buf(),
        name: path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default(),
        common_dir: crate::config::common_dir(path).unwrap_or_else(|| path.join(".git")),
        ..Default::default()
    };
    let fmt = "--format=%(refname)%00%(objectname)%00%(symref)%00%(upstream:short)%00%(upstream:track)%00%(committerdate:unix)%00%(subject)";
    match git::run(path, &["for-each-ref", fmt, "refs/heads", "refs/remotes"]) {
        Ok(text) => {
            let (b, r, head) = parse_refs(&text);
            repo.branches = b;
            repo.remote_refs = r;
            repo.default_ref = head
                .filter(|h| repo.remote_refs.contains_key(h))
                .or_else(|| {
                    ["origin/main", "origin/master", "origin/develop"]
                        .iter()
                        .find(|c| repo.remote_refs.contains_key(**c))
                        .map(|c| c.to_string())
                });
        }
        Err(e) => repo.errors.push(e.to_string()),
    }
    let cfg = git::try_run(
        path,
        &[
            "config",
            "--get-regexp",
            r"^(branch\..*\.vscode-merge-base|remote\..*\.url)$",
        ],
    )
    .unwrap_or_default();
    (repo.vscode_bases, repo.remotes) = parse_config(&cfg);
    if repo.default_ref.is_none() && repo.remotes.is_empty() {
        repo.default_ref = ["main", "master"]
            .iter()
            .find(|n| repo.branches.iter().any(|b| b.name == **n))
            .map(|n| n.to_string());
    }
    repo.default_branch = repo
        .default_ref
        .as_deref()
        .map(|d| base::strip_remote(d, &repo.remotes).to_string());

    match git::run(path, &["worktree", "list", "--porcelain"]) {
        Ok(text) => repo.worktrees = parse_worktrees(&text),
        Err(e) => repo.errors.push(e.to_string()),
    }
    let admins = admin_dirs(&repo.common_dir);
    let mut fetch_heads = vec![repo.common_dir.join("FETCH_HEAD")];
    for admin in admins.values() {
        fetch_heads.push(admin.join("FETCH_HEAD"));
    }
    repo.fetched = newest(&fetch_heads);
    let common = repo.common_dir.clone();
    for wt in &mut repo.worktrees {
        wt.git_dir = if wt.is_main {
            common.clone()
        } else {
            admins.get(&wt.path).cloned().unwrap_or_default()
        };
        if !wt.path.exists() {
            wt.prunable = true;
        }
        if !wt.git_dir.as_os_str().is_empty() {
            wt.activity = newest(&[wt.git_dir.join("HEAD"), wt.git_dir.join("logs/HEAD")]);
            wt.touched = newest(&[
                wt.git_dir.join("HEAD"),
                wt.git_dir.join("logs/HEAD"),
                wt.git_dir.join("index"),
            ]);
        }
        if wt.prunable {
            continue;
        }
        match git::run(&wt.path, &["status", "--porcelain=v2"]) {
            Ok(text) => wt.status = Some(parse_status(&text)),
            Err(e) => repo.errors.push(e.to_string()),
        }
        if wt.branch.is_none()
            && let Some(sha) = wt.head.clone()
        {
            let contains = git::try_run(
                path,
                &[
                    "for-each-ref",
                    "--contains",
                    &sha,
                    "--count=1",
                    "--format=x",
                ],
            );
            wt.detached_reachable = contains.map(|s| !s.trim().is_empty());
            if let Some(out) = git::try_run(path, &["log", "-1", "--format=%ct%x00%s", &sha])
                && let Some((t, s)) = out.trim_end().split_once('\0')
            {
                wt.detached_time = t.parse().ok();
                wt.detached_subject = s.to_string();
            }
        }
    }
    repo
}

impl RepoState {
    pub fn has_remote(&self) -> bool {
        !self.remotes.is_empty()
    }

    pub fn row_seeds(&self, cfg: &Config) -> Vec<RowSeed> {
        let mut out = Vec::new();
        for b in &self.branches {
            let is_default = self.default_branch.as_deref() == Some(b.name.as_str());
            if cfg.ignored(&b.name) || (is_default && !self.has_remote()) {
                continue;
            }
            let wts: Vec<&Worktree> = self
                .worktrees
                .iter()
                .filter(|w| w.branch.as_deref() == Some(b.name.as_str()))
                .collect();
            out.push(RowSeed {
                id: b.name.clone(),
                branch: Some(b.name.clone()),
                detached: None,
                tip: b.tip.clone(),
                upstream: b.upstream.clone(),
                gone: b.gone,
                commit_time: b.commit_time,
                subject: b.subject.clone(),
                worktree_dir: wts
                    .iter()
                    .find(|w| !w.is_main)
                    .and_then(|w| w.dir_name())
                    .map(str::to_string),
                checkouts: wts.iter().map(|w| w.path.clone()).collect(),
                is_default,
            });
        }
        for w in &self.worktrees {
            if w.branch.is_some() || w.prunable {
                continue;
            }
            let Some(sha) = &w.head else { continue };
            out.push(RowSeed {
                id: format!("@{}", w.path.display()),
                branch: None,
                detached: Some(sha.clone()),
                tip: sha.clone(),
                upstream: None,
                gone: false,
                commit_time: w.detached_time.unwrap_or(0),
                subject: w.detached_subject.clone(),
                worktree_dir: w.dir_name().map(str::to_string),
                checkouts: vec![w.path.clone()],
                is_default: false,
            });
        }
        out
    }

    fn resolve(&self, name: &str) -> Option<String> {
        self.branches
            .iter()
            .find(|b| b.name == name)
            .map(|b| b.tip.clone())
            .or_else(|| self.remote_refs.get(name).cloned())
    }

    fn head_logs(&self) -> Vec<String> {
        let mut paths = vec![self.common_dir.join("logs/HEAD")];
        if let Ok(entries) = std::fs::read_dir(self.common_dir.join("worktrees")) {
            paths.extend(
                entries
                    .filter_map(Result::ok)
                    .map(|e| e.path().join("logs/HEAD")),
            );
        }
        paths
            .iter()
            .filter_map(|p| read_tail(p, HEAD_LOG_TAIL))
            .collect()
    }

    fn hints(&self, seed: &RowSeed, head_logs: &[String]) -> Vec<String> {
        let mut names = Vec::new();
        let Some(b) = &seed.branch else {
            return names;
        };
        if let Some(v) = self.vscode_bases.get(b) {
            names.push(v.clone());
        }
        if let Some(u) = &seed.upstream {
            names.push(u.clone());
        }
        let reflog = self.common_dir.join("logs/refs/heads").join(b);
        if let Ok(text) = std::fs::read_to_string(&reflog)
            && let Some(first) = text.lines().next()
            && let Some(from) = base::hints_from_branch_reflog(first)
        {
            names.push(from);
        }
        for log in head_logs {
            for from in base::checkout_sources(log, b) {
                names.push(from.to_string());
                for r in &self.remotes {
                    names.push(format!("{r}/{from}"));
                }
            }
        }
        names
    }

    pub fn plan_details(&self, seeds: &[&RowSeed]) -> (Vec<DetailJob>, Graph) {
        let Some(default) = self.default_ref.clone() else {
            let jobs = seeds
                .iter()
                .map(|s| DetailJob::new(self, s, None, false))
                .collect();
            return (jobs, Graph::default());
        };
        let head_logs = self.head_logs();
        let mut pool: Vec<Candidate> = Vec::new();
        let push = |pool: &mut Vec<Candidate>, name: &str, hinted: bool| {
            if let Some(tip) = self.resolve(name) {
                match pool.iter_mut().find(|c| c.name == name) {
                    Some(c) => c.hinted |= hinted,
                    None => pool.push(Candidate {
                        name: name.to_string(),
                        tip,
                        hinted,
                    }),
                }
            }
        };
        push(&mut pool, &default, false);
        for s in seeds {
            if let Some(b) = &s.branch {
                push(&mut pool, b, false);
            }
            if let Some(u) = &s.upstream {
                push(&mut pool, u, false);
            }
        }
        let per_row_hints: Vec<Vec<String>> =
            seeds.iter().map(|s| self.hints(s, &head_logs)).collect();
        let mut tips: Vec<String> = pool.iter().map(|c| c.tip.clone()).collect();
        for hints in &per_row_hints {
            tips.extend(hints.iter().filter_map(|h| self.resolve(h)));
        }
        tips.extend(seeds.iter().map(|s| s.tip.clone()));
        tips.sort();
        tips.dedup();
        let mut args: Vec<&str> = vec!["rev-list", "--parents"];
        args.extend(tips.iter().map(String::as_str));
        args.extend(["--not", default.as_str()]);
        let graph = Graph::parse(&git::try_run(&self.path, &args).unwrap_or_default());
        let merged: HashSet<String> = git::try_run(
            &self.path,
            &["branch", "--merged", &default, "--format=%(refname:short)"],
        )
        .unwrap_or_default()
        .lines()
        .map(str::to_string)
        .collect();

        let mut jobs = Vec::new();
        for (seed, hints) in seeds.iter().zip(&per_row_hints) {
            let mut cands = pool.clone();
            for h in hints {
                push(&mut cands, h, true);
            }
            let key = ticket::row_key(seed.branch.as_deref(), seed.worktree_dir.as_deref());
            let subject = Subject {
                name: seed.branch.as_deref(),
                key: key.as_deref(),
                tip: &seed.tip,
            };
            let chosen = if seed.is_default {
                cands.iter().find(|c| c.name == default).cloned()
            } else {
                base::choose(&graph, &subject, &cands, &default, &self.remotes).cloned()
            };
            let is_merged = seed.branch.as_ref().is_some_and(|b| merged.contains(b));
            jobs.push(DetailJob::new(self, seed, chosen, is_merged));
        }
        (jobs, graph)
    }

    pub fn base_info(&self, name: &str, ahead: u32, level: Option<crate::model::Level>) -> Base {
        let is_default = self.default_ref.as_deref() == Some(name);
        Base {
            name: name.to_string(),
            branch: base::strip_remote(name, &self.remotes).to_string(),
            kind: base::kind(name, is_default, level, &self.remotes),
            key: ticket::extract_key(base::strip_remote(name, &self.remotes)),
            ahead,
        }
    }
}

#[derive(Clone, Debug)]
pub struct DetailJob {
    pub repo_path: PathBuf,
    pub row_id: String,
    pub tip: String,
    pub base: Option<Candidate>,
    pub merged: bool,
    pub has_remote: bool,
}

impl DetailJob {
    fn new(repo: &RepoState, seed: &RowSeed, base: Option<Candidate>, merged: bool) -> Self {
        DetailJob {
            repo_path: repo.path.clone(),
            row_id: seed.id.clone(),
            tip: seed.tip.clone(),
            base,
            merged,
            has_remote: repo.has_remote(),
        }
    }
}

pub struct Counts {
    pub unpushed: Option<u32>,
    pub ahead: Option<u32>,
}

pub fn count(job: &DetailJob) -> Counts {
    let n =
        |args: &[&str]| -> Option<u32> { git::try_run(&job.repo_path, args)?.trim().parse().ok() };
    let unpushed = if job.has_remote {
        n(&["rev-list", "--count", &job.tip, "--not", "--remotes"])
    } else {
        None
    };
    let ahead = job
        .base
        .as_ref()
        .and_then(|b| n(&["rev-list", "--count", &format!("{}..{}", b.tip, job.tip)]));
    Counts { unpushed, ahead }
}

pub fn unpushed_log(repo: &Path, tip: &str) -> Vec<String> {
    git::try_run(
        repo,
        &["log", "--oneline", "-20", tip, "--not", "--remotes"],
    )
    .unwrap_or_default()
    .lines()
    .map(str::to_string)
    .collect()
}

pub fn read_tail(path: &Path, max: u64) -> Option<String> {
    let mut f = std::fs::File::open(path).ok()?;
    let len = f.metadata().ok()?.len();
    let start = len.saturating_sub(max);
    f.seek(SeekFrom::Start(start)).ok()?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf).ok()?;
    let mut text = String::from_utf8_lossy(&buf).into_owned();
    if start > 0
        && let Some(nl) = text.find('\n')
    {
        text.drain(..=nl);
    }
    Some(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refs_parse_branches_remotes_and_origin_head() {
        let text = "refs/heads/subtask/AUS-1-x\x00aaa\x00\x00origin/subtask/AUS-1-x\x00[ahead 2]\x00100\x00fix it\n\
                    refs/heads/old\x00bbb\x00\x00origin/old\x00[gone]\x0050\x00old\n\
                    refs/remotes/origin/HEAD\x00ccc\x00refs/remotes/origin/develop\x00\x00\x000\x00x\n\
                    refs/remotes/origin/develop\x00ccc\x00\x00\x00\x00200\x00dev\n";
        let (b, r, head) = parse_refs(text);
        assert_eq!(b.len(), 2);
        assert_eq!(b[0].upstream.as_deref(), Some("origin/subtask/AUS-1-x"));
        assert!(!b[0].gone);
        assert!(b[1].gone);
        assert_eq!(r.get("origin/develop").map(String::as_str), Some("ccc"));
        assert!(!r.contains_key("origin/HEAD"));
        assert_eq!(head.as_deref(), Some("origin/develop"));
    }

    #[test]
    fn submodule_only_status_is_not_dirty() {
        let s = parse_status("1 .M S.M. 160000 160000 160000 a b api.common\n");
        assert_eq!(
            s,
            Status {
                dirty: false,
                submodule: true
            }
        );
        let s = parse_status("1 .M N... 100644 100644 100644 a b x.py\n");
        assert!(s.dirty);
        assert!(parse_status("? new.txt\n").dirty);
        assert_eq!(parse_status(""), Status::default());
    }

    #[test]
    fn worktree_blocks_parse() {
        let text = "worktree /r\nHEAD a\nbranch refs/heads/main\n\nworktree /w1\nHEAD b\ndetached\nlocked\n\nworktree /w2\nHEAD c\nbranch refs/heads/x\nprunable gitdir file points to non-existent location\n";
        let w = parse_worktrees(text);
        assert_eq!(w.len(), 3);
        assert!(w[0].is_main && !w[1].is_main);
        assert_eq!(w[0].branch.as_deref(), Some("main"));
        assert!(w[1].branch.is_none() && w[1].locked);
        assert!(w[2].prunable);
    }

    #[test]
    fn config_gives_vscode_bases_and_remotes() {
        let (bases, remotes) = parse_config(
            "branch.subtask/AUS-1.x.vscode-merge-base origin/develop\nremote.origin.url git@x:y\n",
        );
        assert_eq!(
            bases.get("subtask/AUS-1.x").map(String::as_str),
            Some("origin/develop")
        );
        assert_eq!(remotes, ["origin"]);
    }

    #[test]
    fn par_map_keeps_order() {
        let v: Vec<u32> = (0..100).collect();
        assert_eq!(
            par_map(&v, |x| x * 2),
            v.iter().map(|x| x * 2).collect::<Vec<_>>()
        );
    }
}

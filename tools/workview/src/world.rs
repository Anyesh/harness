use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::agents::{self, CheckoutKey, Ties};
use crate::assemble::{self, Ctx};
use crate::config::{self, Config};
use crate::glob::expand;
use crate::model::{AgentInfo, Model};
use crate::scan::{self, Detail, DetailJob, RepoState, par_map};
use crate::ticket::{self, Plan};

pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

pub struct World {
    pub cfg: Config,
    pub all: bool,
    pub repos: Vec<RepoState>,
    pub agents: Vec<AgentInfo>,
    pub ties: Ties,
    pub plans: Vec<Plan>,
}

fn main_path(path: &Path) -> Option<(PathBuf, PathBuf)> {
    let common = config::common_dir(path)?;
    let main = if common.file_name().is_some_and(|n| n == ".git") {
        common.parent()?.to_path_buf()
    } else {
        path.to_path_buf()
    };
    Some((common, main))
}

pub fn repo_paths(cfg: &Config, agents: &[AgentInfo]) -> Vec<PathBuf> {
    let candidates: Vec<PathBuf> = if cfg.roots.is_empty() {
        let mut dirs: Vec<PathBuf> = agents
            .iter()
            .filter_map(|a| a.foreground_cwd.clone().or_else(|| a.cwd.clone()))
            .collect();
        dirs.extend(std::env::current_dir().ok());
        dirs.iter()
            .filter_map(|d| config::enclosing_repo(d))
            .collect()
    } else {
        config::repos_under(&cfg.roots)
    };
    let mut seen = HashSet::new();
    candidates
        .iter()
        .filter_map(|p| main_path(p))
        .filter(|(common, _)| seen.insert(common.clone()))
        .map(|(_, main)| main)
        .collect()
}

fn checkout_keys(repos: &[RepoState]) -> Vec<CheckoutKey> {
    let mut out = Vec::new();
    for (i, r) in repos.iter().enumerate() {
        for w in r.worktrees.iter().filter(|w| !w.prunable) {
            out.push(CheckoutKey {
                path: w.path.clone(),
                repo: i,
                key: ticket::row_key(w.branch.as_deref(), w.dir_name()),
            });
        }
    }
    out
}

pub fn compute_ties(cfg: &Config, agents: &[AgentInfo], repos: &[RepoState], now: i64) -> Ties {
    let checkouts = checkout_keys(repos);
    let since = now - cfg.tie_window_minutes as i64 * 60;
    let activity = par_map(agents, |a| {
        let files = a
            .session_id
            .as_deref()
            .map(|id| agents::find_transcripts(&cfg.transcript_globs, id))
            .unwrap_or_default();
        let cwd = a.cwd.clone().unwrap_or_default();
        agents::read_activity(&files, &cwd, since)
    });
    let mut ties = Ties::default();
    for (a, act) in agents.iter().zip(&activity) {
        agents::tie(a, act, &checkouts, &mut ties);
    }
    ties
}

pub fn load_plans(cfg: &Config) -> Vec<Plan> {
    cfg.plan_globs
        .iter()
        .flat_map(|g| expand(g))
        .filter_map(|p| std::fs::read_to_string(p).ok())
        .filter_map(|t| ticket::parse_plan(&t))
        .collect()
}

impl World {
    pub fn load(cfg: Config, all: bool) -> World {
        let agents = agents::list();
        let paths = repo_paths(&cfg, &agents);
        let repos = par_map(&paths, |p| scan::scan_repo(p));
        let mut w = World {
            plans: load_plans(&cfg),
            ties: Ties::default(),
            cfg,
            all,
            repos,
            agents,
        };
        w.ties = compute_ties(&w.cfg, &w.agents, &w.repos, now());
        w.fill_details();
        w
    }

    pub fn ctx(&self) -> Ctx<'_> {
        Ctx {
            cfg: &self.cfg,
            ties: &self.ties,
            all: self.all,
            now: now(),
        }
    }

    pub fn model(&self) -> Model {
        assemble::model(&self.repos, &self.agents, &self.plans, &self.ctx())
    }

    pub fn fill_details(&mut self) {
        let ctx = self.ctx();
        let needs: Vec<usize> = (0..self.repos.len())
            .filter(|&i| {
                let r = &self.repos[i];
                let seeds = r.row_seeds(ctx.cfg);
                ctx.wanted(&seeds)
                    .iter()
                    .any(|s| !r.details.contains_key(&s.id))
            })
            .collect();
        let planned: Vec<Vec<DetailJob>> = par_map(&needs, |&i| {
            let r = &self.repos[i];
            let seeds = r.row_seeds(ctx.cfg);
            let wanted = ctx.wanted(&seeds);
            r.plan_details(&wanted).0
        });
        let jobs: Vec<DetailJob> = planned.into_iter().flatten().collect();
        let counts = par_map(&jobs, scan::count);
        for &i in &needs {
            self.repos[i].details.clear();
        }
        for (job, c) in jobs.iter().zip(counts) {
            let Some(repo) = self.repos.iter_mut().find(|r| r.path == job.repo_path) else {
                continue;
            };
            let level = repo
                .branches
                .iter()
                .find(|b| b.name == job.row_id)
                .and_then(|b| ticket::level(&b.name));
            let base = job
                .base
                .as_ref()
                .map(|b| repo.base_info(&b.name, c.ahead.unwrap_or(0), level));
            repo.details.insert(
                job.row_id.clone(),
                Detail {
                    unpushed: c.unpushed,
                    base,
                    merged: job.merged,
                },
            );
        }
    }

    pub fn rescan_repo(&mut self, path: &Path) {
        let Some(i) = self.repos.iter().position(|r| r.path == path) else {
            return;
        };
        self.repos[i] = scan::scan_repo(path);
        self.fill_details();
    }

    pub fn rescan_all(&mut self) {
        let paths = repo_paths(&self.cfg, &self.agents);
        self.repos = par_map(&paths, |p| scan::scan_repo(p));
        self.plans = load_plans(&self.cfg);
        self.refresh_agents();
    }

    pub fn refresh_agents(&mut self) {
        self.agents = agents::list();
        self.ties = compute_ties(&self.cfg, &self.agents, &self.repos, now());
        self.fill_details();
    }

    pub fn set_all(&mut self, all: bool) {
        self.all = all;
        for r in &mut self.repos {
            r.details.clear();
        }
        self.fill_details();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn toggling_all_drops_bases_chosen_from_the_other_pool() {
        let mut repo = RepoState {
            path: PathBuf::from("/nonexistent/workview-test"),
            ..Default::default()
        };
        repo.details.insert(
            "AUS-1-x".into(),
            Detail {
                unpushed: Some(1),
                base: None,
                merged: false,
            },
        );
        let mut w = World {
            cfg: Config::default(),
            all: true,
            repos: vec![repo],
            agents: Vec::new(),
            ties: Ties::default(),
            plans: Vec::new(),
        };
        w.set_all(false);
        assert!(w.repos[0].details.is_empty());
    }
}

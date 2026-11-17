use crate::agents::Ties;
use crate::config::Config;
use crate::flags::{self, CheckoutFacts};
use crate::model::{AgentInfo, Checkout, Dormant, Model, RepoInfo, Row, SCHEMA};
use crate::scan::{RepoState, RowSeed, Worktree};
use crate::ticket::{self, Plan};

pub struct Ctx<'a> {
    pub cfg: &'a Config,
    pub ties: &'a Ties,
    pub all: bool,
    pub now: i64,
}

impl Ctx<'_> {
    fn recent(&self, t: Option<i64>) -> bool {
        t.is_some_and(|t| self.now - t <= self.cfg.active_days as i64 * 86400)
    }

    pub fn checkout_active(&self, wt: &Worktree) -> bool {
        self.recent(wt.activity) || self.ties.works.contains_key(&wt.path)
    }

    pub fn seed_active(&self, seed: &RowSeed) -> bool {
        self.recent(Some(seed.commit_time))
    }

    pub fn wanted<'r>(&self, seeds: &'r [RowSeed]) -> Vec<&'r RowSeed> {
        seeds
            .iter()
            .filter(|s| self.all || self.seed_active(s))
            .collect()
    }
}

fn fetch_age_days(repo: &RepoState, now: i64) -> Option<u64> {
    repo.fetched.map(|t| ((now - t).max(0) / 86400) as u64)
}

fn stale_note(repo: &RepoState, ctx: &Ctx) -> Option<String> {
    if !repo.has_remote() {
        return None;
    }
    match fetch_age_days(repo, ctx.now) {
        None => Some("never fetched".into()),
        Some(d) if d > ctx.cfg.stale_fetch_days => Some(format!("fetched {d}d ago")),
        Some(_) => None,
    }
}

pub fn model(repos: &[RepoState], agents: &[AgentInfo], plans: &[Plan], ctx: &Ctx) -> Model {
    let mut rows: Vec<Row> = Vec::new();
    let mut checkouts: Vec<Checkout> = Vec::new();
    let mut dormant = Dormant::default();
    let mut infos = Vec::new();
    for repo in repos {
        infos.push(RepoInfo {
            name: repo.name.clone(),
            path: repo.path.clone(),
            default: repo.default_ref.clone(),
            has_remote: repo.has_remote(),
            fetch_age_days: fetch_age_days(repo, ctx.now),
            errors: repo.errors.clone(),
        });
        let stale = stale_note(repo, ctx);
        for seed in repo.row_seeds(ctx.cfg) {
            let active = ctx.seed_active(&seed);
            let detail = repo.details.get(&seed.id);
            let unpushed = detail.and_then(|d| d.unpushed);
            if seed.is_default && unpushed.unwrap_or(0) == 0 {
                continue;
            }
            if !active {
                dormant.rows += 1;
            }
            if !active && !ctx.all {
                continue;
            }
            let id = rows.len();
            if !active && unpushed.unwrap_or(0) > 0 {
                dormant.unpushed_rows.push(id);
            }
            rows.push(Row {
                id,
                repo: repo.name.clone(),
                repo_path: repo.path.clone(),
                key: ticket::row_key(seed.branch.as_deref(), seed.worktree_dir.as_deref()),
                level: seed.branch.as_deref().and_then(ticket::level),
                branch: seed.branch.clone(),
                detached: seed.detached.clone(),
                subject: seed.subject.clone(),
                commit_time: seed.commit_time,
                upstream: seed.upstream.clone(),
                upstream_gone: seed.gone,
                unpushed,
                base: detail.and_then(|d| d.base.clone()),
                checkouts: seed.checkouts.clone(),
                active,
                flags: flags::row_flags(
                    unpushed,
                    seed.upstream.as_deref(),
                    seed.gone,
                    repo.has_remote(),
                    detail.is_some_and(|d| d.merged),
                    active,
                ),
                stale_fetch: stale.clone(),
            });
        }
        for wt in &repo.worktrees {
            let busy = ctx.ties.works.get(&wt.path).cloned().unwrap_or_default();
            let looked = ctx.ties.looked.contains(&wt.path);
            let off_default = repo
                .default_branch
                .as_deref()
                .is_some_and(|d| wt.branch.as_deref() != Some(d));
            let facts = CheckoutFacts {
                is_main: wt.is_main,
                locked: wt.locked,
                prunable: wt.prunable,
                status: wt.status.as_ref(),
                touched: wt.touched,
                on_branch: wt.branch.is_some(),
                detached_reachable: wt.detached_reachable,
                busy: !busy.is_empty(),
                looked,
                off_default,
            };
            let active = ctx.checkout_active(wt);
            if !active {
                dormant.checkouts += 1;
            }
            checkouts.push(Checkout {
                repo: repo.name.clone(),
                path: wt.path.clone(),
                is_main: wt.is_main,
                branch: wt.branch.clone(),
                detached: if wt.branch.is_none() {
                    wt.head.clone()
                } else {
                    None
                },
                locked: wt.locked,
                activity: wt.activity,
                active,
                busy,
                looked_at: looked,
                flags: flags::checkout_flags(&facts, ctx.now, ctx.cfg.removable_quiet_hours),
            });
        }
    }
    let visible: Vec<usize> = (0..rows.len())
        .filter(|i| !dormant.unpushed_rows.contains(i))
        .collect();
    let tickets = ticket::build_tree(&rows, &visible, plans);
    Model {
        schema: SCHEMA,
        generated_at: ctx.now,
        all: ctx.all,
        summary: flags::summary(&rows, &checkouts),
        repos: infos,
        tickets,
        rows,
        checkouts,
        agents: agents.to_vec(),
        dormant,
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;
    use crate::scan::{BranchRef, Detail, Status};

    const NOW: i64 = 1_800_000_000;
    const DAY: i64 = 86400;

    fn repo() -> RepoState {
        let main = Worktree {
            path: PathBuf::from("/r"),
            branch: Some("subtask/AUS-1-parked".into()),
            is_main: true,
            status: Some(Status::default()),
            activity: Some(NOW - 200 * DAY),
            touched: Some(NOW - 60),
            ..Default::default()
        };
        let br = |name: &str, age: i64| BranchRef {
            name: name.into(),
            tip: format!("{name}-tip"),
            upstream: None,
            gone: false,
            commit_time: NOW - age * DAY,
            subject: String::new(),
        };
        let mut r = RepoState {
            path: PathBuf::from("/r"),
            name: "r".into(),
            remotes: vec!["origin".into()],
            default_ref: Some("origin/main".into()),
            default_branch: Some("main".into()),
            fetched: Some(NOW),
            branches: vec![
                br("main", 1),
                br("subtask/AUS-7509-old", 200),
                br("subtask/AUS-1-parked", 200),
                br("archive/AUS-2", 1),
                br("AUS-3-fresh", 1),
            ],
            worktrees: vec![main],
            ..Default::default()
        };
        for b in ["subtask/AUS-7509-old", "AUS-3-fresh"] {
            r.details.insert(
                b.into(),
                Detail {
                    unpushed: Some(21),
                    base: None,
                    merged: false,
                },
            );
        }
        r
    }

    fn build(r: &RepoState, all: bool) -> Model {
        let cfg = Config::default();
        let ties = Ties::default();
        let ctx = Ctx {
            cfg: &cfg,
            ties: &ties,
            all,
            now: NOW,
        };
        model(std::slice::from_ref(r), &[], &[], &ctx)
    }

    #[test]
    fn old_unpushed_and_parked_checkouts_are_dormant() {
        let m = build(&repo(), false);
        let names: Vec<_> = m.rows.iter().map(|r| r.label()).collect();
        assert_eq!(names, ["AUS-3-fresh"]);
        assert_eq!(m.summary.push, 1);
        assert_eq!(m.summary.stray, 0);
        assert!(m.checkouts[0].flags.off_default && !m.checkouts[0].active);
        assert_eq!(m.dormant.rows, 2);
        assert_eq!(m.dormant.checkouts, 1);
    }

    #[test]
    fn all_shows_dormant_rows_but_the_badge_still_ignores_them() {
        let m = build(&repo(), true);
        assert_eq!(m.rows.len(), 3);
        assert_eq!(m.summary.push, 1);
        let old = m
            .rows
            .iter()
            .find(|r| r.label() == "subtask/AUS-7509-old")
            .unwrap();
        assert!(!old.active);
        assert_eq!(old.flags.push, None);
        assert_eq!(old.unpushed, Some(21));
        assert_eq!(m.dormant.unpushed_rows, vec![old.id]);
    }

    #[test]
    fn recent_head_log_activates_the_checkout_but_not_its_old_branch() {
        let mut r = repo();
        r.worktrees[0].activity = Some(NOW - DAY);
        let m = build(&r, false);
        assert!(m.checkouts[0].active);
        assert_eq!(m.summary.stray, 1);
        assert!(!m.rows.iter().any(|r| r.label() == "subtask/AUS-1-parked"));
    }

    #[test]
    fn dormant_unpushed_rows_sit_only_in_their_own_section() {
        let m = build(&repo(), true);
        let old = m
            .rows
            .iter()
            .find(|r| r.label() == "subtask/AUS-7509-old")
            .unwrap();
        fn holds(nodes: &[crate::model::Node], id: usize) -> bool {
            nodes
                .iter()
                .any(|n| n.rows.contains(&id) || holds(&n.children, id))
        }
        assert!(!holds(&m.tickets, old.id));
        assert!(holds(
            &m.tickets,
            m.rows
                .iter()
                .find(|r| r.label() == "AUS-3-fresh")
                .unwrap()
                .id
        ));
    }

    #[test]
    fn default_branch_is_a_row_only_with_unpushed_commits() {
        let mut r = repo();
        assert!(!build(&r, true).rows.iter().any(|x| x.label() == "main"));
        r.details.insert(
            "main".into(),
            Detail {
                unpushed: Some(2),
                base: None,
                merged: true,
            },
        );
        assert!(build(&r, false).rows.iter().any(|x| x.label() == "main"));
    }

    #[test]
    fn on_default_with_submodule_drift_is_not_stray() {
        let mut r = repo();
        r.worktrees[0].branch = Some("main".into());
        r.worktrees[0].activity = Some(NOW - DAY);
        r.worktrees[0].status = Some(Status {
            dirty: false,
            submodule: true,
        });
        let m = build(&r, false);
        assert!(m.checkouts[0].flags.submodule && !m.checkouts[0].flags.dirty);
        assert_eq!(m.summary.stray, 0);
    }
}

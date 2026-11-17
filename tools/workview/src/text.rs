use std::collections::BTreeMap;
use std::path::Path;

use crate::flags;
use crate::model::{BaseKind, Checkout, Model, Node, NodeKind, Row};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum View {
    Tickets,
    Push,
    Worktrees,
}

impl View {
    pub fn parse(s: &str) -> Option<View> {
        match s {
            "tickets" => Some(View::Tickets),
            "push" => Some(View::Push),
            "worktrees" => Some(View::Worktrees),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Item {
    Heading(String),
    Node {
        kind: NodeKind,
        key: Option<String>,
        title: String,
    },
    Row(usize),
    Checkout(usize),
    Note(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Line {
    pub depth: usize,
    pub item: Item,
}

fn line(depth: usize, item: Item) -> Line {
    Line { depth, item }
}

pub fn matches(model: &Model, item: &Item, filter: &str) -> bool {
    if filter.is_empty() {
        return true;
    }
    let f = filter.to_lowercase();
    let text = match item {
        Item::Row(i) => row_text(model, &model.rows[*i]),
        Item::Checkout(i) => checkout_text(&model.checkouts[*i]),
        Item::Node { key, title, .. } => format!("{} {title}", key.as_deref().unwrap_or("")),
        _ => return false,
    };
    text.to_lowercase().contains(&f)
}

fn node_matches(model: &Model, n: &Node, filter: &str) -> bool {
    let item = Item::Node {
        kind: n.kind,
        key: n.key.clone(),
        title: n.title.clone(),
    };
    matches(model, &item, filter)
        || n.rows
            .iter()
            .any(|&r| matches(model, &Item::Row(r), filter))
        || n.children.iter().any(|c| node_matches(model, c, filter))
}

fn push_node(model: &Model, n: &Node, depth: usize, filter: &str, out: &mut Vec<Line>) {
    let whole = matches(
        model,
        &Item::Node {
            kind: n.kind,
            key: n.key.clone(),
            title: n.title.clone(),
        },
        filter,
    );
    let f = if whole { "" } else { filter };
    if !node_matches(model, n, f) {
        return;
    }
    out.push(line(
        depth,
        Item::Node {
            kind: n.kind,
            key: n.key.clone(),
            title: n.title.clone(),
        },
    ));
    for &r in &n.rows {
        if matches(model, &Item::Row(r), f) {
            out.push(line(depth + 1, Item::Row(r)));
        }
    }
    for c in &n.children {
        push_node(model, c, depth + 1, f, out);
    }
}

fn find_key<'a>(nodes: &'a [Node], key: &str) -> Option<&'a Node> {
    nodes.iter().find_map(|n| {
        if n.key.as_deref() == Some(key) {
            Some(n)
        } else {
            find_key(&n.children, key)
        }
    })
}

pub fn worktree_visible(c: &Checkout, all: bool) -> bool {
    if all {
        return true;
    }
    if c.is_main {
        c.active && (c.flags.off_default || c.flags.dirty || !c.busy.is_empty())
    } else {
        c.active || c.flags.removable || c.flags.prunable
    }
}

pub fn lines(model: &Model, view: View, key: Option<&str>, filter: &str) -> Vec<Line> {
    let mut out = Vec::new();
    match view {
        View::Tickets => {
            let nodes: Vec<&Node> = match key {
                Some(k) => find_key(&model.tickets, k).into_iter().collect(),
                None => model.tickets.iter().collect(),
            };
            for n in nodes {
                push_node(model, n, 0, filter, &mut out);
            }
            if model.all && !model.dormant.unpushed_rows.is_empty() && key.is_none() {
                out.push(line(
                    0,
                    Item::Heading("Dormant with unpushed commits".into()),
                ));
                for &r in &model.dormant.unpushed_rows {
                    if matches(model, &Item::Row(r), filter) {
                        out.push(line(1, Item::Row(r)));
                    }
                }
            }
        }
        View::Push => {
            let mut by_repo: BTreeMap<&str, Vec<&Row>> = BTreeMap::new();
            for r in &model.rows {
                if r.flags.push.is_some() && matches(model, &Item::Row(r.id), filter) {
                    by_repo.entry(&r.repo).or_default().push(r);
                }
            }
            let mut commits = 0;
            for (repo, rs) in by_repo {
                let n: u32 = rs.iter().filter_map(|r| r.flags.push).sum();
                out.push(line(
                    0,
                    Item::Heading(format!("{repo}  {} branches, {n} commits", rs.len())),
                ));
                for r in rs {
                    out.push(line(1, Item::Row(r.id)));
                }
                commits += n;
            }
            let total_rows = out
                .iter()
                .filter(|l| matches!(l.item, Item::Row(_)))
                .count();
            out.push(line(
                0,
                Item::Note(format!("total: {total_rows} branches, {commits} commits")),
            ));
        }
        View::Worktrees => {
            for (i, c) in model.checkouts.iter().enumerate() {
                if worktree_visible(c, model.all) && matches(model, &Item::Checkout(i), filter) {
                    out.push(line(0, Item::Checkout(i)));
                }
            }
        }
    }
    out
}

pub fn footer(model: &Model) -> String {
    let d = &model.dormant;
    if model.all {
        format!(
            "showing all: {} dormant branches, {} dormant checkouts",
            d.rows, d.checkouts
        )
    } else {
        format!(
            "{} dormant branches and {} dormant checkouts hidden (all shows them)",
            d.rows, d.checkouts
        )
    }
}

fn short_path(p: &Path) -> String {
    let home = crate::glob::home();
    match p.strip_prefix(&home) {
        Ok(rest) if !home.as_os_str().is_empty() => format!("~/{}", rest.display()),
        _ => p.display().to_string(),
    }
}

fn base_text(r: &Row) -> Option<String> {
    let b = r.base.as_ref()?;
    let target = match (b.kind, &b.key) {
        (BaseKind::Stacked, Some(k)) => k.clone(),
        _ => b.name.clone(),
    };
    Some(format!("+{} on {target}", b.ahead))
}

pub fn row_flag_words(r: &Row) -> Vec<String> {
    let mut w = Vec::new();
    if !r.active
        && let Some(n) = r.unpushed.filter(|n| *n > 0)
    {
        w.push(format!("unpushed {n}"));
    }
    if let Some(n) = r.flags.push {
        w.push(format!("PUSH {n}"));
        if r.flags.no_upstream {
            w.push("NO-UPSTREAM".into());
        }
    }
    if r.flags.gone {
        w.push("GONE (merged?)".into());
    }
    if r.flags.no_remote {
        w.push("NO-REMOTE".into());
    }
    if r.flags.merged {
        w.push("merged".into());
    }
    let upstreamish = r.flags.gone || r.flags.merged || r.upstream.is_some();
    if upstreamish && let Some(s) = &r.stale_fetch {
        w.push(format!("({s})"));
    }
    w
}

fn checkout_label(model: &Model, path: &Path) -> String {
    let c = model.checkouts.iter().find(|c| c.path == path);
    let mut s = match c {
        Some(c) if c.is_main => "base checkout".to_string(),
        _ => format!(
            "wt {}",
            path.file_name()
                .map(|n| n.to_string_lossy())
                .unwrap_or_default()
        ),
    };
    if let Some(c) = c {
        for w in checkout_flag_words(c) {
            s.push_str("  ");
            s.push_str(&w);
        }
    }
    s
}

pub fn checkout_flag_words(c: &Checkout) -> Vec<String> {
    let mut w = Vec::new();
    for t in &c.busy {
        w.push(format!(
            "BUSY {} {} · {}",
            trim(&t.name, 28),
            t.status,
            t.signal.label()
        ));
    }
    if c.flags.dirty {
        w.push("DIRTY".into());
    }
    if c.flags.submodule {
        w.push("submodule".into());
    }
    if c.flags.removable {
        w.push("REMOVABLE?".into());
    }
    if c.flags.prunable {
        w.push("PRUNABLE".into());
    }
    if c.flags.off_default {
        w.push("OFF-DEFAULT".into());
    }
    if c.locked {
        w.push("locked".into());
    }
    w
}

fn trim(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        s.to_string()
    } else {
        let t: String = s.chars().take(n.saturating_sub(1)).collect();
        format!("{t}…")
    }
}

pub fn row_text(model: &Model, r: &Row) -> String {
    let mut parts = vec![r.repo.clone(), r.label()];
    if let Some(b) = base_text(r) {
        parts.push(b);
    }
    parts.extend(row_flag_words(r));
    for p in &r.checkouts {
        parts.push(checkout_label(model, p));
    }
    parts.join("  ")
}

pub fn checkout_text(c: &Checkout) -> String {
    let head = match (&c.branch, &c.detached) {
        (Some(b), _) => b.clone(),
        (None, Some(sha)) => format!("(detached {})", &sha[..sha.len().min(8)]),
        _ => "(unknown)".into(),
    };
    let mut parts = vec![
        c.repo.clone(),
        if c.is_main {
            "base".into()
        } else {
            "wt".into()
        },
        short_path(&c.path),
        head,
    ];
    parts.extend(checkout_flag_words(c));
    parts.join("  ")
}

pub fn item_text(model: &Model, item: &Item) -> String {
    match item {
        Item::Heading(s) | Item::Note(s) => s.clone(),
        Item::Node { kind, key, title } => {
            let label = match kind {
                NodeKind::Epic => "EPIC ",
                NodeKind::Story => "STORY ",
                NodeKind::Ticket => "",
                NodeKind::Other => "other: ",
            };
            match key {
                Some(k) if title.is_empty() => format!("{label}{k}"),
                Some(k) => format!("{label}{k}  {title}"),
                None => format!("{label}{title}"),
            }
        }
        Item::Row(i) => row_text(model, &model.rows[*i]),
        Item::Checkout(i) => checkout_text(&model.checkouts[*i]),
    }
}

pub fn render(model: &Model, view: View, key: Option<&str>) -> String {
    let mut out = String::new();
    let badge = flags::badge(&model.summary);
    out.push_str(if badge.is_empty() {
        "nothing waits"
    } else {
        &badge
    });
    out.push('\n');
    for l in lines(model, view, key, "") {
        out.push_str(&"  ".repeat(l.depth));
        out.push_str(&item_text(model, &l.item));
        out.push('\n');
    }
    out.push_str(&footer(model));
    out.push('\n');
    out
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;
    use crate::model::{Base, CheckoutFlags, Dormant, RowFlags, Summary};

    fn model() -> Model {
        let row = Row {
            id: 0,
            repo: "api.accounting".into(),
            repo_path: PathBuf::from("/r"),
            branch: Some("subtask/AUS-8485-e".into()),
            detached: None,
            key: Some("AUS-8485".into()),
            level: None,
            subject: String::new(),
            commit_time: 1,
            upstream: Some("origin/subtask/AUS-8485-e".into()),
            upstream_gone: false,
            unpushed: Some(2),
            base: Some(Base {
                name: "subtask/AUS-8483-d".into(),
                branch: "subtask/AUS-8483-d".into(),
                kind: BaseKind::Stacked,
                key: Some("AUS-8483".into()),
                ahead: 1,
            }),
            checkouts: vec![PathBuf::from("/w/x")],
            active: true,
            flags: RowFlags {
                push: Some(2),
                ..Default::default()
            },
            stale_fetch: Some("fetched 12d ago".into()),
        };
        let co = Checkout {
            repo: "api.accounting".into(),
            path: PathBuf::from("/w/x"),
            is_main: false,
            branch: Some("subtask/AUS-8485-e".into()),
            detached: None,
            locked: false,
            activity: None,
            active: true,
            busy: Vec::new(),
            looked_at: false,
            flags: CheckoutFlags {
                dirty: true,
                ..Default::default()
            },
        };
        Model {
            schema: 1,
            generated_at: 0,
            all: false,
            summary: Summary {
                push: 1,
                stray: 0,
                rm: 0,
            },
            repos: Vec::new(),
            tickets: vec![Node {
                kind: NodeKind::Ticket,
                key: Some("AUS-8485".into()),
                title: "e".into(),
                rows: vec![0],
                children: Vec::new(),
                newest: 1,
            }],
            rows: vec![row],
            checkouts: vec![co],
            agents: Vec::new(),
            dormant: Dormant {
                rows: 3,
                checkouts: 2,
                unpushed_rows: Vec::new(),
            },
        }
    }

    #[test]
    fn stacked_row_shows_on_key_flags_and_stale_suffix() {
        let m = model();
        let t = row_text(&m, &m.rows[0]);
        assert_eq!(
            t,
            "api.accounting  subtask/AUS-8485-e  +1 on AUS-8483  PUSH 2  (fetched 12d ago)  wt x  DIRTY"
        );
    }

    #[test]
    fn dormant_rows_show_unpushed_without_push() {
        let mut m = model();
        m.rows[0].active = false;
        m.rows[0].flags.push = None;
        let w = row_flag_words(&m.rows[0]);
        assert!(w.contains(&"unpushed 2".to_string()));
        assert!(!w.iter().any(|x| x.starts_with("PUSH")));
    }

    #[test]
    fn merged_shows_even_at_zero_ahead() {
        let mut m = model();
        m.rows[0].flags = RowFlags {
            merged: true,
            ..Default::default()
        };
        m.rows[0].base = Some(Base {
            name: "origin/develop".into(),
            branch: "develop".into(),
            kind: BaseKind::Default,
            key: None,
            ahead: 0,
        });
        assert!(row_flag_words(&m.rows[0]).contains(&"merged".to_string()));
    }

    #[test]
    fn render_tickets_has_badge_tree_and_footer() {
        let out = render(&model(), View::Tickets, None);
        let lines: Vec<&str> = out.lines().collect();
        assert_eq!(lines[0], "push 1");
        assert_eq!(lines[1], "AUS-8485  e");
        assert!(lines[2].starts_with("  api.accounting"));
        assert!(lines[3].contains("3 dormant branches"));
    }

    #[test]
    fn push_view_totals() {
        let out = render(&model(), View::Push, None);
        assert!(out.contains("api.accounting  1 branches, 2 commits"));
        assert!(out.contains("total: 1 branches, 2 commits"));
    }

    #[test]
    fn filter_keeps_matching_rows_and_their_nodes() {
        let m = model();
        assert_eq!(lines(&m, View::Tickets, None, "8485").len(), 2);
        assert!(lines(&m, View::Tickets, None, "nomatch").is_empty());
    }
}

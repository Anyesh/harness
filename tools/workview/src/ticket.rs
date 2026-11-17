use std::collections::{BTreeMap, HashMap, HashSet};

use crate::model::{BaseKind, Level, Node, NodeKind, Row};

pub fn extract_key(s: &str) -> Option<String> {
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() {
        let starts = b[i].is_ascii_uppercase() && (i == 0 || !b[i - 1].is_ascii_alphanumeric());
        if starts {
            let mut j = i + 1;
            while j < b.len() && (b[j].is_ascii_uppercase() || b[j].is_ascii_digit()) {
                j += 1;
            }
            if j - i >= 2 && j < b.len() && b[j] == b'-' {
                let mut k = j + 1;
                while k < b.len() && b[k].is_ascii_digit() {
                    k += 1;
                }
                if k > j + 1 {
                    return Some(s[i..k].to_string());
                }
            }
        }
        i += 1;
    }
    None
}

pub fn row_key(branch: Option<&str>, worktree_dir: Option<&str>) -> Option<String> {
    branch
        .and_then(extract_key)
        .or_else(|| worktree_dir.and_then(extract_key))
}

pub fn level(branch: &str) -> Option<Level> {
    if branch.starts_with("subtask/") {
        Some(Level::Subtask)
    } else if branch.starts_with("story/") {
        Some(Level::Story)
    } else {
        None
    }
}

pub fn slug_title(name: &str) -> String {
    let mut rest = name;
    for prefix in ["subtask/", "story/"] {
        if let Some(r) = rest.strip_prefix(prefix) {
            rest = r;
        }
    }
    if let Some(key) = extract_key(rest)
        && let Some(pos) = rest.find(&key)
    {
        let after = &rest[pos + key.len()..];
        rest = after.trim_start_matches(['-', '_', '/']);
    }
    rest.replace(['-', '_'], " ")
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Plan {
    pub key: String,
    pub title: String,
    pub subtasks: Vec<PlanSubtask>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlanSubtask {
    pub key: String,
    pub title: String,
}

pub fn parse_plan(text: &str) -> Option<Plan> {
    let mut plan: Option<Plan> = None;
    let mut in_subtasks = false;
    let mut title_col: Option<usize> = None;
    for line in text.lines() {
        let trimmed = line.trim();
        if let Some(h) = trimmed.strip_prefix("# ") {
            if plan.is_none()
                && let Some(key) = extract_key(h)
            {
                let title = h
                    .split_once(':')
                    .map(|(_, t)| t.trim().to_string())
                    .unwrap_or_default();
                plan = Some(Plan {
                    key,
                    title,
                    subtasks: Vec::new(),
                });
            }
            in_subtasks = false;
            continue;
        }
        if trimmed.starts_with('#') {
            in_subtasks = trimmed
                .trim_start_matches('#')
                .trim()
                .eq_ignore_ascii_case("subtasks");
            title_col = None;
            continue;
        }
        if !in_subtasks || !trimmed.starts_with('|') {
            continue;
        }
        let cells: Vec<&str> = trimmed
            .trim_matches('|')
            .split('|')
            .map(str::trim)
            .collect();
        if cells
            .iter()
            .all(|c| c.chars().all(|ch| ch == '-' || ch == ':'))
        {
            continue;
        }
        let Some(key) = cells.first().and_then(|c| extract_key(c)) else {
            title_col = cells.iter().position(|c| c.eq_ignore_ascii_case("title"));
            continue;
        };
        let title = cells
            .get(title_col.unwrap_or(2))
            .map(|t| t.replace('`', ""))
            .unwrap_or_default();
        if let Some(p) = plan.as_mut() {
            p.subtasks.push(PlanSubtask { key, title });
        }
    }
    plan
}

struct Facts<'a> {
    rows: &'a [Row],
    by_key: BTreeMap<String, Vec<usize>>,
    plan_story: HashMap<String, String>,
}

impl Facts<'_> {
    fn row_epic(&self, idx: usize, seen: &mut HashSet<String>) -> Option<String> {
        let base = self.rows[idx].base.as_ref()?;
        match base.kind {
            BaseKind::Epic => base.key.clone(),
            BaseKind::Stacked => {
                let parent = base.key.clone()?;
                self.key_epic_direct(&parent, seen)
            }
            _ => None,
        }
    }

    fn key_epic_direct(&self, key: &str, seen: &mut HashSet<String>) -> Option<String> {
        if !seen.insert(key.to_string()) {
            return None;
        }
        let idxs = self.by_key.get(key)?;
        most_common(idxs.iter().filter_map(|&i| self.row_epic(i, seen)))
    }

    fn story_of(&self, key: &str) -> Option<String> {
        if let Some(s) = self.plan_story.get(key) {
            return Some(s.clone());
        }
        self.by_key.get(key)?.iter().find_map(|&i| {
            let base = self.rows[i].base.as_ref()?;
            (base.kind == BaseKind::Story)
                .then(|| base.key.clone())
                .flatten()
        })
    }
}

fn most_common(items: impl Iterator<Item = String>) -> Option<String> {
    let mut counts: Vec<(String, usize)> = Vec::new();
    for item in items {
        match counts.iter_mut().find(|(k, _)| *k == item) {
            Some((_, n)) => *n += 1,
            None => counts.push((item, 1)),
        }
    }
    let best = counts.iter().map(|(_, n)| *n).max()?;
    counts.into_iter().find(|(_, n)| *n == best).map(|(k, _)| k)
}

pub fn build_tree(rows: &[Row], visible: &[usize], plans: &[Plan]) -> Vec<Node> {
    let mut by_key: BTreeMap<String, Vec<usize>> = BTreeMap::new();
    let mut other: BTreeMap<String, Vec<usize>> = BTreeMap::new();
    for &i in visible {
        match &rows[i].key {
            Some(k) => by_key.entry(k.clone()).or_default().push(i),
            None => other.entry(rows[i].repo.clone()).or_default().push(i),
        }
    }
    let mut titles: HashMap<String, String> = HashMap::new();
    let mut plan_story = HashMap::new();
    for plan in plans {
        titles.insert(plan.key.clone(), plan.title.clone());
        for sub in &plan.subtasks {
            plan_story.insert(sub.key.clone(), plan.key.clone());
            titles
                .entry(sub.key.clone())
                .or_insert_with(|| sub.title.clone());
        }
    }
    let facts = Facts {
        rows,
        by_key,
        plan_story,
    };

    let mut epic: HashMap<String, String> = HashMap::new();
    let mut story: HashMap<String, String> = HashMap::new();
    let mut keys: Vec<String> = facts.by_key.keys().cloned().collect();
    for key in &keys {
        if let Some(e) = facts.key_epic_direct(key, &mut HashSet::new()) {
            epic.insert(key.clone(), e);
        }
        if let Some(s) = facts.story_of(key) {
            story.insert(key.clone(), s);
        }
        for &i in &facts.by_key[key] {
            if let Some(base) = &rows[i].base
                && let Some(bk) = &base.key
            {
                let t = slug_title(&base.branch);
                if !t.is_empty() {
                    titles.entry(bk.clone()).or_insert(t);
                }
            }
            if let Some(b) = &rows[i].branch {
                let t = slug_title(b);
                if !t.is_empty() {
                    titles.entry(key.clone()).or_insert(t);
                }
            }
        }
    }
    let stories: Vec<String> = {
        let mut s: Vec<String> = story.values().cloned().collect();
        for key in &keys {
            if facts.by_key[key]
                .iter()
                .any(|&i| rows[i].level == Some(Level::Story))
            {
                s.push(key.clone());
            }
        }
        s.sort();
        s.dedup();
        s
    };
    for s in &stories {
        if epic.contains_key(s) {
            continue;
        }
        let children = story
            .iter()
            .filter(|(_, st)| *st == s)
            .filter_map(|(k, _)| epic.get(k).cloned());
        let mut sorted: Vec<String> = children.collect();
        sorted.sort();
        if let Some(e) = most_common(sorted.into_iter()) {
            epic.insert(s.clone(), e);
        }
    }

    let mut parent: HashMap<String, String> = HashMap::new();
    for key in keys.iter().chain(stories.iter()) {
        let p = story
            .get(key)
            .filter(|s| *s != key)
            .or_else(|| epic.get(key).filter(|e| *e != key));
        if let Some(p) = p {
            parent.insert(key.clone(), p.clone());
        }
    }
    let mut all: Vec<String> = keys.clone();
    all.extend(parent.values().cloned());
    all.sort();
    all.dedup();
    for key in &all {
        let mut seen = HashSet::new();
        let mut cur = key.clone();
        seen.insert(cur.clone());
        while let Some(p) = parent.get(&cur).cloned() {
            if !seen.insert(p.clone()) {
                parent.remove(&cur);
                break;
            }
            cur = p;
        }
    }
    keys = all;

    let epics: HashSet<&String> = keys
        .iter()
        .filter_map(|k| parent.get(k).filter(|p| epic.get(k) == Some(*p)))
        .collect();
    let story_set: HashSet<&String> = stories.iter().collect();
    let kind_of = |k: &String| {
        if epics.contains(k) && !story_set.contains(k) {
            NodeKind::Epic
        } else if story_set.contains(k) {
            NodeKind::Story
        } else {
            NodeKind::Ticket
        }
    };

    let mut children: HashMap<String, Vec<String>> = HashMap::new();
    let mut roots = Vec::new();
    for k in &keys {
        match parent.get(k) {
            Some(p) => children.entry(p.clone()).or_default().push(k.clone()),
            None => roots.push(k.clone()),
        }
    }
    let build = |k: &String| -> Node {
        fn go(
            k: &String,
            children: &HashMap<String, Vec<String>>,
            facts: &Facts,
            titles: &HashMap<String, String>,
            kind_of: &dyn Fn(&String) -> NodeKind,
        ) -> Node {
            let rows_here = facts.by_key.get(k).cloned().unwrap_or_default();
            let mut kids: Vec<Node> = children
                .get(k)
                .map(|cs| {
                    cs.iter()
                        .map(|c| go(c, children, facts, titles, kind_of))
                        .collect()
                })
                .unwrap_or_default();
            sort_nodes(&mut kids);
            let own = rows_here
                .iter()
                .map(|&i| facts.rows[i].commit_time)
                .max()
                .unwrap_or(i64::MIN);
            let newest = kids.iter().map(|n| n.newest).fold(own, i64::max);
            let mut rows_sorted = rows_here;
            rows_sorted.sort_by_key(|&i| std::cmp::Reverse(facts.rows[i].commit_time));
            Node {
                kind: kind_of(k),
                key: Some(k.clone()),
                title: titles.get(k).cloned().unwrap_or_default(),
                rows: rows_sorted,
                children: kids,
                newest,
            }
        }
        go(k, &children, &facts, &titles, &kind_of)
    };
    let mut nodes: Vec<Node> = roots.iter().map(build).collect();
    sort_nodes(&mut nodes);
    let mut others: Vec<Node> = other
        .into_iter()
        .map(|(repo, mut idxs)| {
            idxs.sort_by_key(|&i| std::cmp::Reverse(rows[i].commit_time));
            Node {
                kind: NodeKind::Other,
                key: None,
                title: repo,
                newest: idxs
                    .iter()
                    .map(|&i| rows[i].commit_time)
                    .max()
                    .unwrap_or(i64::MIN),
                rows: idxs,
                children: Vec::new(),
            }
        })
        .collect();
    sort_nodes(&mut others);
    nodes.extend(others);
    nodes
}

fn sort_nodes(nodes: &mut [Node]) {
    nodes.sort_by(|a, b| b.newest.cmp(&a.newest).then_with(|| a.key.cmp(&b.key)));
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;
    use crate::model::{Base, RowFlags};

    #[test]
    fn key_is_first_match() {
        assert_eq!(
            extract_key("subtask/AUS-8475-column").as_deref(),
            Some("AUS-8475")
        );
        assert_eq!(
            extract_key("AUS-8496/flag-cleanup").as_deref(),
            Some("AUS-8496")
        );
        assert_eq!(extract_key("feature-x"), None);
        assert_eq!(extract_key("A-1"), None);
        assert_eq!(extract_key("utf8-AB2-7"), Some("AB2-7".into()));
    }

    #[test]
    fn key_falls_back_to_worktree_dir() {
        assert_eq!(
            row_key(None, Some("db-migrations-AUS-8475-seed")).as_deref(),
            Some("AUS-8475")
        );
        assert_eq!(
            row_key(Some("main"), Some("api.accounting-AUS-8268")).as_deref(),
            Some("AUS-8268")
        );
    }

    #[test]
    fn level_comes_from_prefix() {
        assert_eq!(level("subtask/AUS-1-x"), Some(Level::Subtask));
        assert_eq!(level("story/AUS-1-x"), Some(Level::Story));
        assert_eq!(level("AUS-1-x"), None);
    }

    #[test]
    fn slug_title_drops_prefix_and_key() {
        assert_eq!(
            slug_title("subtask/AUS-8475-ndis-print-terms-seed"),
            "ndis print terms seed"
        );
        assert_eq!(
            slug_title("AUS-7597-ndis-service-plan"),
            "ndis service plan"
        );
        assert_eq!(slug_title("feature_x"), "feature x");
        assert_eq!(slug_title("story/AUS-7646"), "");
    }

    const PLAN: &str = "# AUS-8109: NDIS service plan print\n\n## In short\n\n| a | b |\n\n## Subtasks\n\n| Jira | Repo, branch | Title | Depends on |\n|---|---|---|---|\n| AUS-8268 | api.accounting `subtask/AUS-8268-x` | Shared totals | none |\n| AUS-8475 (column) | db-migrations `subtask/AUS-8475-ndis-cost-breakdown-column` | Recurrence `cost_breakdown` column | none |\n| AUS-8475 (seed) | db-migrations `subtask/AUS-8475-seed` | Seed | none |\n\n## Risks\n\n| AUS-9999 | not a subtask | x |\n";

    #[test]
    fn plan_table_is_parsed() {
        let plan = parse_plan(PLAN).unwrap();
        assert_eq!(plan.key, "AUS-8109");
        assert_eq!(plan.title, "NDIS service plan print");
        let keys: Vec<&str> = plan.subtasks.iter().map(|s| s.key.as_str()).collect();
        assert_eq!(keys, ["AUS-8268", "AUS-8475", "AUS-8475"]);
        assert_eq!(plan.subtasks[1].title, "Recurrence cost_breakdown column");
    }

    #[test]
    fn plan_without_key_title_is_none() {
        assert_eq!(
            parse_plan("# Notes\n## Subtasks\n| AUS-1 | x | y |\n"),
            None
        );
    }

    fn row(id: usize, branch: &str, t: i64, base: Option<(&str, BaseKind)>) -> Row {
        Row {
            id,
            repo: "api.accounting".into(),
            repo_path: PathBuf::from("/r"),
            branch: Some(branch.into()),
            detached: None,
            key: extract_key(branch),
            level: level(branch),
            subject: String::new(),
            commit_time: t,
            upstream: None,
            upstream_gone: false,
            unpushed: None,
            base: base.map(|(n, k)| Base {
                name: n.into(),
                branch: n.strip_prefix("origin/").unwrap_or(n).into(),
                kind: k,
                key: extract_key(n),
                ahead: 1,
            }),
            checkouts: Vec::new(),
            active: true,
            flags: RowFlags::default(),
            stale_fetch: None,
        }
    }

    fn find<'a>(nodes: &'a [Node], key: &str) -> Option<&'a Node> {
        for n in nodes {
            if n.key.as_deref() == Some(key) {
                return Some(n);
            }
            if let Some(f) = find(&n.children, key) {
                return Some(f);
            }
        }
        None
    }

    fn all(rows: &[Row]) -> Vec<usize> {
        (0..rows.len()).collect()
    }

    #[test]
    fn epic_comes_from_the_base() {
        let rows = vec![row(
            0,
            "subtask/AUS-8268-x",
            5,
            Some(("origin/AUS-7597-ndis-service-plan", BaseKind::Epic)),
        )];
        let tree = build_tree(&rows, &all(&rows), &[]);
        assert_eq!(tree.len(), 1);
        assert_eq!(tree[0].key.as_deref(), Some("AUS-7597"));
        assert_eq!(tree[0].kind, NodeKind::Epic);
        assert_eq!(tree[0].title, "ndis service plan");
        assert_eq!(tree[0].children[0].key.as_deref(), Some("AUS-8268"));
        assert_eq!(tree[0].children[0].rows, vec![0]);
    }

    #[test]
    fn epic_passes_down_a_stack() {
        let rows = vec![
            row(
                0,
                "subtask/AUS-8470-a",
                1,
                Some(("origin/AUS-7597-epic", BaseKind::Epic)),
            ),
            row(
                1,
                "subtask/AUS-8472-b",
                2,
                Some(("subtask/AUS-8470-a", BaseKind::Stacked)),
            ),
            row(
                2,
                "subtask/AUS-8484-c",
                3,
                Some(("origin/subtask/AUS-8472-b", BaseKind::Stacked)),
            ),
            row(
                3,
                "subtask/AUS-8490-d",
                4,
                Some(("subtask/AUS-8484-c", BaseKind::Stacked)),
            ),
        ];
        let tree = build_tree(&rows, &all(&rows), &[]);
        assert_eq!(tree.len(), 1);
        let epic = &tree[0];
        assert_eq!(epic.key.as_deref(), Some("AUS-7597"));
        let mut kids: Vec<_> = epic
            .children
            .iter()
            .map(|n| n.key.clone().unwrap())
            .collect();
        kids.sort();
        assert_eq!(kids, ["AUS-8470", "AUS-8472", "AUS-8484", "AUS-8490"]);
        assert_eq!(epic.newest, 4);
    }

    #[test]
    fn a_stack_cycle_terminates() {
        let rows = vec![
            row(
                0,
                "subtask/AUS-1-a",
                1,
                Some(("subtask/AUS-2-b", BaseKind::Stacked)),
            ),
            row(
                1,
                "subtask/AUS-2-b",
                2,
                Some(("subtask/AUS-1-a", BaseKind::Stacked)),
            ),
        ];
        let tree = build_tree(&rows, &all(&rows), &[]);
        assert_eq!(tree.len(), 2);
    }

    #[test]
    fn story_from_plan_and_epic_from_children() {
        let plan = parse_plan(PLAN).unwrap();
        let rows = vec![
            row(
                0,
                "subtask/AUS-8268-x",
                5,
                Some(("origin/AUS-7597-epic", BaseKind::Epic)),
            ),
            row(
                1,
                "subtask/AUS-8475-ndis-cost-breakdown-column",
                3,
                Some(("origin/develop", BaseKind::Default)),
            ),
            row(
                2,
                "subtask/AUS-8475-seed",
                4,
                Some(("origin/develop", BaseKind::Default)),
            ),
        ];
        let tree = build_tree(&rows, &all(&rows), &[plan]);
        assert_eq!(tree.len(), 1);
        assert_eq!(tree[0].key.as_deref(), Some("AUS-7597"));
        let story = find(&tree, "AUS-8109").unwrap();
        assert_eq!(story.kind, NodeKind::Story);
        assert_eq!(story.title, "NDIS service plan print");
        let t8475 = find(&story.children, "AUS-8475").unwrap();
        assert_eq!(t8475.rows, vec![2, 1]);
        assert_eq!(t8475.title, "Recurrence cost_breakdown column");
    }

    #[test]
    fn story_base_gives_the_story() {
        let rows = vec![
            row(
                0,
                "subtask/AUS-10-x",
                2,
                Some(("origin/story/AUS-9-parent", BaseKind::Story)),
            ),
            row(
                1,
                "story/AUS-9-parent",
                1,
                Some(("origin/develop", BaseKind::Default)),
            ),
        ];
        let tree = build_tree(&rows, &all(&rows), &[]);
        assert_eq!(tree.len(), 1);
        assert_eq!(tree[0].key.as_deref(), Some("AUS-9"));
        assert_eq!(tree[0].kind, NodeKind::Story);
        assert_eq!(tree[0].rows, vec![1]);
        assert_eq!(tree[0].children[0].key.as_deref(), Some("AUS-10"));
    }

    #[test]
    fn bare_key_branch_takes_its_title_from_a_sibling() {
        let rows = vec![
            row(0, "story/AUS-7646", 2, None),
            row(1, "story/AUS-7646-fe", 1, None),
        ];
        let tree = build_tree(&rows, &all(&rows), &[]);
        assert_eq!(tree[0].title, "fe");
    }

    #[test]
    fn keyless_rows_group_by_repo() {
        let mut r = row(0, "feature-x", 1, None);
        r.repo = "webapp".into();
        let rows = vec![r];
        let tree = build_tree(&rows, &all(&rows), &[]);
        assert_eq!(tree[0].kind, NodeKind::Other);
        assert_eq!(tree[0].title, "webapp");
    }

    #[test]
    fn only_visible_rows_are_grouped() {
        let rows = vec![row(0, "AUS-1-a", 1, None), row(1, "AUS-2-b", 2, None)];
        let tree = build_tree(&rows, &[1], &[]);
        assert_eq!(tree.len(), 1);
        assert_eq!(tree[0].key.as_deref(), Some("AUS-2"));
    }
}

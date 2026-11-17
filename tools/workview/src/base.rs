use std::collections::HashMap;

use crate::model::{BaseKind, Level};
use crate::ticket::extract_key;

#[derive(Clone, Debug, Default)]
pub struct Graph {
    index: HashMap<String, usize>,
    parents: Vec<Vec<usize>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reach(Vec<u64>);

impl Reach {
    fn empty(n: usize) -> Self {
        Reach(vec![0; n.div_ceil(64)])
    }
    fn insert(&mut self, i: usize) -> bool {
        let (w, b) = (i / 64, 1u64 << (i % 64));
        let fresh = self.0[w] & b == 0;
        self.0[w] |= b;
        fresh
    }
    fn contains(&self, i: usize) -> bool {
        self.0[i / 64] & (1u64 << (i % 64)) != 0
    }
    fn minus_count(&self, other: &Reach) -> u32 {
        self.0
            .iter()
            .zip(&other.0)
            .map(|(a, b)| (a & !b).count_ones())
            .sum()
    }
}

impl Graph {
    pub fn parse(text: &str) -> Self {
        let lines: Vec<Vec<&str>> = text
            .lines()
            .map(|l| l.split_whitespace().collect::<Vec<_>>())
            .filter(|f| !f.is_empty())
            .collect();
        let mut index = HashMap::new();
        for fields in &lines {
            let n = index.len();
            index.entry(fields[0].to_string()).or_insert(n);
        }
        let mut parents = vec![Vec::new(); index.len()];
        for fields in &lines {
            let i = index[fields[0]];
            parents[i] = fields[1..]
                .iter()
                .filter_map(|p| index.get(*p).copied())
                .collect();
        }
        Graph { index, parents }
    }

    pub fn len(&self) -> usize {
        self.parents.len()
    }

    pub fn contains(&self, sha: &str) -> bool {
        self.index.contains_key(sha)
    }

    pub fn reach(&self, sha: &str) -> Reach {
        let mut r = Reach::empty(self.len());
        let Some(&start) = self.index.get(sha) else {
            return r;
        };
        let mut stack = vec![start];
        while let Some(i) = stack.pop() {
            if r.insert(i) {
                stack.extend(&self.parents[i]);
            }
        }
        r
    }

    fn has(&self, r: &Reach, sha: &str) -> bool {
        self.index.get(sha).is_some_and(|&i| r.contains(i))
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Candidate {
    pub name: String,
    pub tip: String,
    pub hinted: bool,
}

pub struct Subject<'a> {
    pub name: Option<&'a str>,
    pub key: Option<&'a str>,
    pub tip: &'a str,
}

pub fn strip_remote<'a>(name: &'a str, remotes: &[String]) -> &'a str {
    for r in remotes {
        if let Some(rest) = name
            .strip_prefix(r.as_str())
            .and_then(|s| s.strip_prefix('/'))
        {
            return rest;
        }
    }
    name
}

fn has_level_prefix(short: &str) -> bool {
    short.starts_with("subtask/") || short.starts_with("story/")
}

type Rank = (u32, bool, bool, bool, bool, usize);

pub fn choose<'c>(
    graph: &Graph,
    subject: &Subject,
    candidates: &'c [Candidate],
    default: &str,
    remotes: &[String],
) -> Option<&'c Candidate> {
    let default_cand = candidates.iter().find(|c| c.name == default);
    if !graph.contains(subject.tip) {
        return default_cand;
    }
    let rb = graph.reach(subject.tip);
    let mut best: Option<(&Candidate, Rank)> = None;
    for c in candidates {
        let short = strip_remote(&c.name, remotes);
        if let Some(name) = subject.name
            && (c.name == name || short == name)
        {
            continue;
        }
        if subject.key.is_some() && extract_key(short).as_deref() == subject.key {
            continue;
        }
        let is_default = c.name == default;
        if !is_default && !graph.contains(&c.tip) {
            continue;
        }
        let rc = graph.reach(&c.tip);
        if graph.has(&rc, subject.tip) {
            continue;
        }
        let ahead = rb.minus_count(&rc);
        let ancestor = is_default || graph.has(&rb, &c.tip);
        let rank = (
            ahead,
            !ancestor,
            has_level_prefix(short),
            !c.hinted,
            !is_default,
            c.name.len(),
        );
        if best.as_ref().is_none_or(|(_, r)| rank < *r) {
            best = Some((c, rank));
        }
    }
    best.map(|(c, _)| c).or(default_cand)
}

pub fn kind(
    base: &str,
    is_default: bool,
    row_level: Option<Level>,
    remotes: &[String],
) -> BaseKind {
    if is_default {
        return BaseKind::Default;
    }
    let short = strip_remote(base, remotes);
    if short.starts_with("subtask/") {
        BaseKind::Stacked
    } else if short.starts_with("story/") {
        if row_level == Some(Level::Story) {
            BaseKind::Stacked
        } else {
            BaseKind::Story
        }
    } else if extract_key(short).is_some() {
        BaseKind::Epic
    } else {
        BaseKind::Other
    }
}

pub fn hints_from_branch_reflog(first_line: &str) -> Option<String> {
    let msg = first_line.split_once('\t')?.1;
    let from = msg.split("Created from ").nth(1)?.trim();
    (from != "HEAD" && !from.is_empty()).then(|| from.to_string())
}

pub fn checkout_sources<'a>(head_log: &'a str, branch: &str) -> Vec<&'a str> {
    let mut out = Vec::new();
    for line in head_log.lines() {
        let Some((_, msg)) = line.split_once('\t') else {
            continue;
        };
        let Some(rest) = msg.strip_prefix("checkout: moving from ") else {
            continue;
        };
        if let Some((from, to)) = rest.rsplit_once(" to ")
            && to == branch
            && from != branch
            && !out.contains(&from)
        {
            out.push(from);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const EPIC: &str = "origin/AUS-7597-ndis-service-plan";
    const DEFAULT: &str = "origin/develop";

    struct Repo {
        lines: Vec<String>,
        refs: Vec<(String, String)>,
    }

    impl Repo {
        fn new() -> Self {
            Repo {
                lines: Vec::new(),
                refs: vec![(DEFAULT.into(), "d0".into())],
            }
        }
        fn commit(&mut self, sha: &str, parent: &str) {
            let p = if parent == "d0" {
                "d0".to_string()
            } else {
                parent.to_string()
            };
            self.lines.push(format!("{sha} {p}"));
        }
        fn branch(&mut self, name: &str, tip: &str) {
            self.refs.push((name.into(), tip.into()));
        }
        fn graph(&self) -> Graph {
            Graph::parse(&self.lines.join("\n"))
        }
        fn candidates(&self, hints: &[&str]) -> Vec<Candidate> {
            self.refs
                .iter()
                .map(|(n, t)| Candidate {
                    name: n.clone(),
                    tip: t.clone(),
                    hinted: hints.contains(&n.as_str()),
                })
                .collect()
        }
        fn tip(&self, name: &str) -> String {
            self.refs.iter().find(|(n, _)| n == name).unwrap().1.clone()
        }
        fn base(&self, name: &str, hints: &[&str]) -> String {
            let tip = self.tip(name);
            let key = extract_key(name);
            let cands = self.candidates(hints);
            let subject = Subject {
                name: Some(name),
                key: key.as_deref(),
                tip: &tip,
            };
            let remotes = vec!["origin".to_string()];
            choose(&self.graph(), &subject, &cands, DEFAULT, &remotes)
                .unwrap()
                .name
                .clone()
        }
        fn ahead(&self, name: &str, base: &str) -> u32 {
            let g = self.graph();
            let base_tip = self.tip(base);
            g.reach(&self.tip(name)).minus_count(&g.reach(&base_tip))
        }
    }

    const STACK: [&str; 7] = [
        "subtask/AUS-8470-a",
        "subtask/AUS-8472-b",
        "subtask/AUS-8484-c",
        "subtask/AUS-8483-d",
        "subtask/AUS-8485-e",
        "subtask/AUS-8486-f",
        "subtask/AUS-8490-g",
    ];

    fn stack_repo() -> Repo {
        let mut r = Repo::new();
        r.commit("e1", "d0");
        r.commit("e2", "e1");
        r.branch(EPIC, "e2");
        let mut prev = "e2".to_string();
        for (i, name) in STACK.iter().enumerate() {
            let n = if i == 2 { 2 } else { 1 };
            for j in 0..n {
                let sha = format!("s{i}x{j}");
                r.commit(&sha, &prev);
                prev = sha;
            }
            r.branch(name, &prev);
            r.branch(&format!("origin/{name}"), &prev);
        }
        r
    }

    #[test]
    fn real_stack_resolves_each_member_to_its_parent() {
        let r = stack_repo();
        assert_eq!(r.base(STACK[0], &[]), EPIC);
        for i in 1..STACK.len() {
            let got = r.base(STACK[i], &[]);
            assert_eq!(
                strip_remote(&got, &["origin".into()]),
                STACK[i - 1],
                "base of {}",
                STACK[i]
            );
        }
    }

    #[test]
    fn checkout_from_a_child_does_not_close_a_cycle() {
        let r = stack_repo();
        let got = r.base(STACK[2], &[STACK[6], "origin/subtask/AUS-8490-g"]);
        assert_eq!(strip_remote(&got, &["origin".into()]), STACK[1]);
        assert_eq!(r.ahead(STACK[2], &got), 2);
    }

    #[test]
    fn stacked_vscode_base_wins_its_tie_with_the_local_copy() {
        let r = stack_repo();
        let got = r.base(STACK[2], &["origin/subtask/AUS-8472-b"]);
        assert_eq!(got, "origin/subtask/AUS-8472-b");
    }

    fn sibling_repo(epic_moves: bool) -> Repo {
        let mut r = Repo::new();
        r.commit("e1", "d0");
        r.branch(EPIC, "e1");
        let mut prev = "e1".to_string();
        for i in 0..3 {
            let sha = format!("a{i}");
            r.commit(&sha, &prev);
            prev = sha;
        }
        r.branch("subtask/AUS-8268-x", &prev);
        r.branch("origin/subtask/AUS-8268-x", &prev);
        prev = "e1".into();
        for i in 0..5 {
            let sha = format!("b{i}");
            r.commit(&sha, &prev);
            prev = sha;
        }
        r.branch("subtask/AUS-8495-y", &prev);
        if epic_moves {
            r.commit("e2", "e1");
            r.refs.retain(|(n, _)| n != EPIC);
            r.branch(EPIC, "e2");
        }
        r
    }

    #[test]
    fn siblings_resolve_to_the_epic() {
        for moves in [false, true] {
            let r = sibling_repo(moves);
            assert_eq!(r.base("subtask/AUS-8495-y", &[]), EPIC, "moves={moves}");
            assert_eq!(r.base("subtask/AUS-8268-x", &[]), EPIC, "moves={moves}");
            assert_eq!(
                r.base(
                    "subtask/AUS-8495-y",
                    &["subtask/AUS-8268-x", "origin/subtask/AUS-8268-x"]
                ),
                EPIC
            );
            assert_eq!(r.ahead("subtask/AUS-8495-y", EPIC), 5);
        }
    }

    #[test]
    fn self_named_and_same_key_candidates_are_dropped() {
        let mut r = Repo::new();
        r.commit("x1", "d0");
        r.commit("x2", "x1");
        r.branch("origin/subtask/AUS-8469-old-name", "x1");
        r.branch("archive/AUS-8469", "x2");
        assert_eq!(
            r.base("archive/AUS-8469", &["origin/subtask/AUS-8469-old-name"]),
            DEFAULT
        );

        let mut k = Repo::new();
        k.commit("y1", "d0");
        k.commit("y2", "y1");
        k.branch("feature", "y2");
        k.branch("origin/feature", "y1");
        assert_eq!(k.base("feature", &["origin/feature"]), DEFAULT);
    }

    #[test]
    fn equal_tip_candidate_is_dropped() {
        let mut r = Repo::new();
        r.commit("x1", "d0");
        r.branch("AUS-1-a", "x1");
        r.branch("AUS-2-b", "x1");
        assert_eq!(r.base("AUS-2-b", &["AUS-1-a"]), DEFAULT);
    }

    #[test]
    fn falls_back_to_the_default() {
        let mut r = Repo::new();
        r.commit("x1", "d0");
        r.branch("AUS-1-a", "x1");
        assert_eq!(r.base("AUS-1-a", &[]), DEFAULT);
        r.branch("AUS-3-on-default", "d0");
        assert_eq!(r.base("AUS-3-on-default", &[]), DEFAULT);
    }

    #[test]
    fn candidate_merged_into_default_collapses_into_it() {
        let mut r = Repo::new();
        r.commit("x1", "d0");
        r.branch("AUS-1-a", "x1");
        r.branch("AUS-7-merged", "d0");
        assert_eq!(r.base("AUS-1-a", &["AUS-7-merged"]), DEFAULT);
    }

    #[test]
    fn kinds() {
        let remotes = vec!["origin".to_string()];
        let k = |b: &str, d: bool, l: Option<Level>| kind(b, d, l, &remotes);
        assert_eq!(k("origin/develop", true, None), BaseKind::Default);
        assert_eq!(
            k("origin/subtask/AUS-1-x", false, Some(Level::Subtask)),
            BaseKind::Stacked
        );
        assert_eq!(
            k("story/AUS-1-x", false, Some(Level::Story)),
            BaseKind::Stacked
        );
        assert_eq!(
            k("origin/story/AUS-1-x", false, Some(Level::Subtask)),
            BaseKind::Story
        );
        assert_eq!(k("origin/story/AUS-1-x", false, None), BaseKind::Story);
        assert_eq!(
            k("origin/AUS-7597-ndis-service-plan", false, None),
            BaseKind::Epic
        );
        assert_eq!(k("release-2026", false, None), BaseKind::Other);
    }

    #[test]
    fn reflog_hints() {
        assert_eq!(
            hints_from_branch_reflog(
                "0000 abcd A <a@b> 1 +0000\tbranch: Created from origin/develop"
            )
            .as_deref(),
            Some("origin/develop")
        );
        assert_eq!(
            hints_from_branch_reflog("0000 abcd A <a@b> 1 +0000\tbranch: Created from HEAD"),
            None
        );
        let log = "a b A <a> 1 +0\tcheckout: moving from main to AUS-1-x\n\
                   a b A <a> 2 +0\tcheckout: moving from AUS-1-x to AUS-2-y\n\
                   a b A <a> 3 +0\tcheckout: moving from AUS-2-y to AUS-1-x\n\
                   a b A <a> 4 +0\tcommit: x\n";
        assert_eq!(checkout_sources(log, "AUS-1-x"), vec!["main", "AUS-2-y"]);
    }
}

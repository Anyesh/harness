use std::collections::{HashMap, HashSet};
use std::path::{Component, Path, PathBuf};
use std::process::Command;

use serde_json::Value;

use crate::glob::{expand, expand_tilde};
use crate::model::{AgentInfo, Signal, Tie};
use crate::scan::read_tail;
use crate::ticket::extract_key;

const TAIL_LINES: usize = 400;
const TAIL_BYTES: u64 = 8 * 1024 * 1024;
const WRITE_VERBS: [&str; 11] = [
    "commit",
    "checkout",
    "switch",
    "rebase",
    "merge",
    "cherry-pick",
    "reset",
    "stash",
    "am",
    "apply",
    "add",
];

pub fn herdr_bin() -> PathBuf {
    std::env::var_os("HERDR_BIN_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("herdr"))
}

pub fn list() -> Vec<AgentInfo> {
    let Ok(out) = Command::new(herdr_bin()).args(["agent", "list"]).output() else {
        return Vec::new();
    };
    if !out.status.success() {
        return Vec::new();
    }
    parse_list(&String::from_utf8_lossy(&out.stdout))
}

pub fn parse_list(text: &str) -> Vec<AgentInfo> {
    let v: Value = serde_json::from_str(text).unwrap_or_default();
    let Some(agents) = v["result"]["agents"].as_array() else {
        return Vec::new();
    };
    let s = |a: &Value, k: &str| a[k].as_str().map(str::to_string);
    agents
        .iter()
        .filter_map(|a| {
            Some(AgentInfo {
                pane_id: s(a, "pane_id")?,
                agent: s(a, "agent").unwrap_or_default(),
                name: s(a, "terminal_title_stripped").unwrap_or_default(),
                status: s(a, "agent_status").unwrap_or_default(),
                session_id: a["agent_session"]["value"].as_str().map(str::to_string),
                cwd: s(a, "cwd").map(PathBuf::from),
                foreground_cwd: s(a, "foreground_cwd").map(PathBuf::from),
            })
        })
        .collect()
}

pub fn focus(pane_id: &str) -> anyhow::Result<()> {
    let out = Command::new(herdr_bin())
        .args(["agent", "focus", pane_id])
        .output()?;
    if !out.status.success() {
        anyhow::bail!(
            "herdr agent focus: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(())
}

pub fn find_transcripts(globs: &[String], session_id: &str) -> Vec<PathBuf> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    let mut add = |p: PathBuf, out: &mut Vec<PathBuf>| {
        let real = p.canonicalize().unwrap_or(p);
        if seen.insert(real.clone()) {
            out.push(real);
        }
    };
    for g in globs {
        for main in expand(&g.replace("{id}", session_id)) {
            let sub = main.with_extension("").join("subagents");
            add(main, &mut out);
            for s in expand(&format!("{}/*.jsonl", sub.display())) {
                add(s, &mut out);
            }
        }
    }
    out
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Activity {
    pub writes: Vec<PathBuf>,
    pub mentions: Vec<PathBuf>,
}

pub fn read_activity(files: &[PathBuf], cwd: &Path, since: i64) -> Activity {
    let mut act = Activity::default();
    for f in files {
        let Some(text) = read_tail(f, TAIL_BYTES) else {
            continue;
        };
        let lines: Vec<&str> = text.lines().collect();
        for line in &lines[lines.len().saturating_sub(TAIL_LINES)..] {
            line_activity(line, cwd, since, &mut act);
        }
    }
    act
}

pub fn line_activity(line: &str, cwd: &Path, since: i64, act: &mut Activity) {
    let Ok(v) = serde_json::from_str::<Value>(line) else {
        return;
    };
    let recent = v["timestamp"]
        .as_str()
        .and_then(parse_rfc3339)
        .is_some_and(|ts| ts >= since);
    let Some(content) = v["message"]["content"].as_array() else {
        return;
    };
    for item in content {
        if item["type"] != "tool_use" {
            continue;
        }
        let input = &item["input"];
        let name = if recent {
            item["name"].as_str().unwrap_or("")
        } else {
            ""
        };
        match name {
            "Edit" | "Write" | "MultiEdit" | "NotebookEdit" => {
                for k in ["file_path", "notebook_path"] {
                    if let Some(p) = input[k].as_str() {
                        act.writes.push(resolve(p, cwd));
                    }
                }
            }
            "Bash" => {
                if let Some(cmd) = input["command"].as_str() {
                    act.writes.extend(git_write_targets(cmd, cwd));
                }
            }
            _ => {}
        }
        let mut texts = Vec::new();
        strings(input, &mut texts);
        for t in texts {
            act.mentions.extend(path_tokens(t));
        }
    }
}

fn strings<'a>(v: &'a Value, out: &mut Vec<&'a str>) {
    match v {
        Value::String(s) => out.push(s),
        Value::Array(a) => a.iter().for_each(|x| strings(x, out)),
        Value::Object(o) => o.values().for_each(|x| strings(x, out)),
        _ => {}
    }
}

fn resolve(p: &str, cwd: &Path) -> PathBuf {
    let p = expand_tilde(p);
    if p.is_absolute() { p } else { cwd.join(p) }
}

const TRAILING: &[char] = &['.', ',', ';', ':', ')', ']', '}', '!', '?', '`'];

pub fn path_tokens(text: &str) -> Vec<PathBuf> {
    text.split(|c: char| c.is_whitespace() || "\"'=(){}[]<>,;|&`:".contains(c))
        .map(|t| t.trim_end_matches(TRAILING))
        .filter(|t| t.starts_with('/') || t.starts_with("~/"))
        .map(expand_tilde)
        .collect()
}

fn shell_words(segment: &str) -> Vec<String> {
    segment
        .split_whitespace()
        .map(|w| w.trim_matches(|c| c == '"' || c == '\'').to_string())
        .collect()
}

pub fn git_write_targets(command: &str, cwd: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut dir: Option<PathBuf> = None;
    let normalized = command.replace("&&", "\n").replace("||", "\n");
    for segment in normalized.split(['\n', ';', '|']) {
        let words = shell_words(segment);
        let Some(first) = words.first() else { continue };
        if first == "cd" {
            if let Some(d) = words.get(1) {
                let base = dir.clone().unwrap_or_else(|| cwd.to_path_buf());
                dir = Some(resolve_from(d, &base));
            }
            continue;
        }
        let Some(gi) = words.iter().position(|w| w == "git" || w.ends_with("/git")) else {
            continue;
        };
        let mut target = dir.clone();
        let mut i = gi + 1;
        let mut verb = None;
        while i < words.len() {
            let w = &words[i];
            if w == "-C" {
                if let Some(d) = words.get(i + 1) {
                    let base = target.clone().unwrap_or_else(|| cwd.to_path_buf());
                    target = Some(resolve_from(d, &base));
                }
                i += 2;
            } else if w == "-c" {
                i += 2;
            } else if let Some(wt) = w.strip_prefix("--work-tree=") {
                target = Some(resolve_from(wt, cwd));
                i += 1;
            } else if w.starts_with('-') {
                i += 1;
            } else {
                verb = Some(w.as_str());
                break;
            }
        }
        if let (Some(v), Some(t)) = (verb, target)
            && WRITE_VERBS.contains(&v)
        {
            out.push(t);
        }
    }
    out
}

fn resolve_from(p: &str, base: &Path) -> PathBuf {
    let p = expand_tilde(p);
    let joined = if p.is_absolute() { p } else { base.join(p) };
    let mut clean = PathBuf::new();
    for c in joined.components() {
        match c {
            Component::ParentDir => {
                clean.pop();
            }
            Component::CurDir => {}
            other => clean.push(other.as_os_str()),
        }
    }
    clean
}

pub fn owner<'a>(path: &Path, checkouts: &'a [CheckoutKey]) -> Option<&'a CheckoutKey> {
    checkouts
        .iter()
        .filter(|c| path.starts_with(&c.path))
        .max_by_key(|c| c.path.components().count())
}

#[derive(Clone, Debug)]
pub struct CheckoutKey {
    pub path: PathBuf,
    pub repo: usize,
    pub key: Option<String>,
}

#[derive(Clone, Debug, Default)]
pub struct Ties {
    pub works: HashMap<PathBuf, Vec<Tie>>,
    pub looked: HashSet<PathBuf>,
}

pub fn tie(agent: &AgentInfo, act: &Activity, checkouts: &[CheckoutKey], ties: &mut Ties) {
    let make = |signal| Tie {
        pane_id: agent.pane_id.clone(),
        name: agent.name.clone(),
        status: agent.status.clone(),
        signal,
    };
    let mut works: Vec<(&PathBuf, Signal)> = Vec::new();
    for w in &act.writes {
        if let Some(c) = owner(w, checkouts)
            && !works.iter().any(|(p, _)| *p == &c.path)
        {
            works.push((&c.path, Signal::Transcript));
        }
    }
    let cwd = agent.foreground_cwd.as_ref().or(agent.cwd.as_ref());
    let home = cwd.and_then(|c| owner(c, checkouts));
    if works.is_empty()
        && let Some(key) = extract_key(&agent.name)
        && let Some(home) = home
    {
        for c in checkouts {
            if c.repo == home.repo && c.key.as_deref() == Some(key.as_str()) {
                works.push((&c.path, Signal::Title));
            }
        }
    }
    if works.is_empty()
        && let Some(home) = home
    {
        works.push((&home.path, Signal::Cwd));
    }
    for (p, s) in &works {
        ties.works.entry((*p).clone()).or_default().push(make(*s));
    }
    for m in &act.mentions {
        if let Some(c) = owner(m, checkouts)
            && !works.iter().any(|(p, _)| *p == &c.path)
        {
            ties.looked.insert(c.path.clone());
        }
    }
}

pub fn parse_rfc3339(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() < 19 || b[4] != b'-' || b[10] != b'T' {
        return None;
    }
    let num = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
    let (y, mo, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (h, mi, se) = (num(11..13)?, num(14..16)?, num(17..19)?);
    let mut rest = &s[19..];
    if let Some(r) = rest.strip_prefix('.') {
        rest = r.trim_start_matches(|c: char| c.is_ascii_digit());
    }
    let offset = match rest {
        "Z" | "z" | "" => 0,
        tz if tz.len() == 6 => {
            let sign = if tz.starts_with('-') { -1 } else { 1 };
            sign * (tz[1..3].parse::<i64>().ok()? * 3600 + tz[4..6].parse::<i64>().ok()? * 60)
        }
        _ => return None,
    };
    let (yy, mm) = if mo <= 2 {
        (y - 1, mo + 9)
    } else {
        (y, mo - 3)
    };
    let era = yy.div_euclid(400);
    let yoe = yy - era * 400;
    let doy = (153 * mm + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    Some(days * 86400 + h * 3600 + mi * 60 + se - offset)
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000;

    fn ts(offset: i64) -> String {
        let t = NOW + offset;
        let days = t.div_euclid(86400);
        let secs = t.rem_euclid(86400);
        let z = days + 719468;
        let era = z.div_euclid(146097);
        let doe = z - era * 146097;
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let d = doy - (153 * mp + 2) / 5 + 1;
        let m = if mp < 10 { mp + 3 } else { mp - 9 };
        let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
        format!(
            "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.123Z",
            secs / 3600,
            secs % 3600 / 60,
            secs % 60
        )
    }

    fn tool(offset: i64, name: &str, input: Value) -> String {
        serde_json::json!({
            "type": "assistant",
            "timestamp": ts(offset),
            "message": {"content": [{"type": "tool_use", "name": name, "input": input}]}
        })
        .to_string()
    }

    fn ck(path: &str, repo: usize, key: Option<&str>) -> CheckoutKey {
        CheckoutKey {
            path: PathBuf::from(path),
            repo,
            key: key.map(str::to_string),
        }
    }

    fn agent(name: &str, cwd: &str) -> AgentInfo {
        AgentInfo {
            pane_id: "w9:p1C".into(),
            agent: "claude".into(),
            name: name.into(),
            status: "working".into(),
            session_id: Some("sid".into()),
            cwd: Some(cwd.into()),
            foreground_cwd: Some(cwd.into()),
        }
    }

    fn checkouts() -> Vec<CheckoutKey> {
        vec![
            ck("/s/db-migrations", 0, None),
            ck(
                "/s/_worktrees/db-migrations-AUS-8475-column",
                0,
                Some("AUS-8475"),
            ),
            ck(
                "/s/_worktrees/db-migrations-AUS-8475-seed",
                0,
                Some("AUS-8475"),
            ),
            ck("/s/_worktrees/db-migrations-AUS-8475", 0, Some("AUS-8475")),
            ck("/s/api.accounting", 1, None),
        ]
    }

    fn activity(lines: &[String]) -> Activity {
        let mut a = Activity::default();
        for l in lines {
            line_activity(l, Path::new("/s/db-migrations"), NOW - 3600, &mut a);
        }
        a
    }

    #[test]
    fn rfc3339_round_trips() {
        assert_eq!(parse_rfc3339(&ts(0)), Some(NOW));
        assert_eq!(parse_rfc3339("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_rfc3339("1970-01-01T01:00:00+01:00"), Some(0));
        assert_eq!(parse_rfc3339("garbage"), None);
    }

    #[test]
    fn parses_herdr_agent_list() {
        let text = r#"{"result":{"agents":[{"agent":"claude","agent_session":{"value":"abc"},"agent_status":"working","cwd":"/s","foreground_cwd":"/s/x","pane_id":"w9:p9","terminal_title_stripped":"Jira AUS-8475 subtask"}]}}"#;
        let a = parse_list(text);
        assert_eq!(a.len(), 1);
        assert_eq!(a[0].session_id.as_deref(), Some("abc"));
        assert_eq!(a[0].foreground_cwd.as_deref(), Some(Path::new("/s/x")));
        assert!(parse_list("not json").is_empty());
    }

    #[test]
    fn transcript_writes_win_over_title_and_cwd() {
        let a = activity(&[
            tool(
                -60,
                "Edit",
                serde_json::json!({"file_path": "/s/_worktrees/db-migrations-AUS-8475-column/x.sql"}),
            ),
            tool(
                -30,
                "Bash",
                serde_json::json!({"command": "cd /s/_worktrees/db-migrations-AUS-8475-seed && git add -A && git commit -m x"}),
            ),
        ]);
        let mut t = Ties::default();
        tie(
            &agent("Jira AUS-8475 subtask", "/s/db-migrations"),
            &a,
            &checkouts(),
            &mut t,
        );
        assert_eq!(t.works.len(), 2);
        let col = &t.works[Path::new("/s/_worktrees/db-migrations-AUS-8475-column")];
        assert_eq!(col[0].signal, Signal::Transcript);
        assert!(
            t.works
                .contains_key(Path::new("/s/_worktrees/db-migrations-AUS-8475-seed"))
        );
        assert!(!t.works.contains_key(Path::new("/s/db-migrations")));
    }

    #[test]
    fn title_key_ties_within_the_cwd_repo() {
        let mut t = Ties::default();
        tie(
            &agent("Jira AUS-8475 subtask", "/s/db-migrations"),
            &Activity::default(),
            &checkouts(),
            &mut t,
        );
        assert_eq!(t.works.len(), 3);
        assert!(t.works.values().all(|v| v[0].signal == Signal::Title));
    }

    #[test]
    fn cwd_is_the_last_resort() {
        let mut t = Ties::default();
        tie(
            &agent("lead", "/s/api.accounting/src"),
            &Activity::default(),
            &checkouts(),
            &mut t,
        );
        assert_eq!(t.works.len(), 1);
        assert_eq!(
            t.works[Path::new("/s/api.accounting")][0].signal,
            Signal::Cwd
        );
    }

    #[test]
    fn read_only_git_c_is_only_looked_at() {
        let a = activity(&[tool(
            -10,
            "Bash",
            serde_json::json!({"command": "git -C /s/_worktrees/db-migrations-AUS-8475-seed log --oneline -3; git -C /s/api.accounting status"}),
        )]);
        assert!(a.writes.is_empty());
        let mut t = Ties::default();
        tie(
            &agent("lead", "/s/api.accounting"),
            &a,
            &checkouts(),
            &mut t,
        );
        assert!(
            t.looked
                .contains(Path::new("/s/_worktrees/db-migrations-AUS-8475-seed"))
        );
        assert_eq!(
            t.works[Path::new("/s/api.accounting")][0].signal,
            Signal::Cwd
        );
        assert!(!t.looked.contains(Path::new("/s/api.accounting")));
    }

    #[test]
    fn git_c_write_counts() {
        let got = git_write_targets(
            "git -C /s/_worktrees/db-migrations-AUS-8475-seed commit -m 'x y'",
            Path::new("/"),
        );
        assert_eq!(
            got,
            vec![PathBuf::from("/s/_worktrees/db-migrations-AUS-8475-seed")]
        );
        assert!(git_write_targets("git commit -m x", Path::new("/s")).is_empty());
        assert_eq!(
            git_write_targets(
                "cd ../api.accounting && git stash",
                Path::new("/s/db-migrations")
            ),
            vec![PathBuf::from("/s/api.accounting")]
        );
    }

    #[test]
    fn edits_older_than_the_window_are_ignored() {
        let a = activity(&[tool(
            -7200,
            "Edit",
            serde_json::json!({"file_path": "/s/_worktrees/db-migrations-AUS-8475-column/x.sql"}),
        )]);
        assert!(a.writes.is_empty());
        assert_eq!(a.mentions.len(), 1);
    }

    #[test]
    fn path_boundary_and_trailing_punctuation() {
        let cs = checkouts();
        let o = owner(
            Path::new("/s/_worktrees/db-migrations-AUS-8475-column/a"),
            &cs,
        )
        .unwrap();
        assert_eq!(
            o.path,
            Path::new("/s/_worktrees/db-migrations-AUS-8475-column")
        );
        let toks =
            path_tokens("see /s/_worktrees/db-migrations-AUS-8475. and `/s/api.accounting`,");
        assert_eq!(
            toks,
            vec![
                PathBuf::from("/s/_worktrees/db-migrations-AUS-8475"),
                PathBuf::from("/s/api.accounting")
            ]
        );
        assert_eq!(
            owner(&toks[0], &cs).unwrap().path,
            Path::new("/s/_worktrees/db-migrations-AUS-8475")
        );
    }

    #[test]
    fn malformed_lines_are_skipped() {
        let a = activity(&[
            "{not json".to_string(),
            tool(
                -5,
                "Write",
                serde_json::json!({"file_path": "/s/api.accounting/a.py"}),
            ),
        ]);
        assert_eq!(a.writes, vec![PathBuf::from("/s/api.accounting/a.py")]);
    }

    #[test]
    fn transcripts_are_found_with_subagents_and_deduplicated() {
        let t = tempfile::tempdir().unwrap();
        let real = t.path().join(".claude/projects/p");
        std::fs::create_dir_all(real.join("sid/subagents")).unwrap();
        std::fs::write(real.join("sid.jsonl"), "").unwrap();
        std::fs::write(real.join("sid/subagents/agent-1.jsonl"), "").unwrap();
        for prof in [".claude-a", ".claude-b"] {
            std::fs::create_dir_all(t.path().join(prof)).unwrap();
            std::os::unix::fs::symlink(
                t.path().join(".claude/projects"),
                t.path().join(prof).join("projects"),
            )
            .unwrap();
        }
        let globs = vec![format!(
            "{}/.claude*/projects/*/{{id}}.jsonl",
            t.path().display()
        )];
        let found = find_transcripts(&globs, "sid");
        assert_eq!(found.len(), 2, "{found:?}");
    }

    #[test]
    fn subagent_edit_counts() {
        let t = tempfile::tempdir().unwrap();
        let sub = t.path().join("sub.jsonl");
        std::fs::write(
            &sub,
            format!(
                "{}\n",
                tool(
                    -5,
                    "Edit",
                    serde_json::json!({"file_path": "/s/_worktrees/db-migrations-AUS-8475-seed/a"})
                )
            ),
        )
        .unwrap();
        let a = read_activity(&[sub], Path::new("/"), NOW - 3600);
        assert_eq!(a.writes.len(), 1);
    }
}

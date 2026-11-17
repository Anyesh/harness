use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

const DAY: i64 = 86400;

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

fn rfc3339(t: i64) -> String {
    let days = t.div_euclid(DAY);
    let secs = t.rem_euclid(DAY);
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.000Z",
        secs / 3600,
        secs % 3600 / 60,
        secs % 60
    )
}

struct Fixture {
    tmp: tempfile::TempDir,
}

impl Fixture {
    fn path(&self, p: &str) -> PathBuf {
        self.tmp.path().join(p)
    }

    fn env(&self, c: &mut Command) {
        c.env("HOME", self.tmp.path())
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t");
    }

    fn git_in(&self, dir: &Path, args: &[&str], date: Option<i64>) -> String {
        let mut c = Command::new("git");
        c.arg("-C").arg(dir).args(args);
        self.env(&mut c);
        if let Some(d) = date {
            c.env("GIT_COMMITTER_DATE", format!("@{d} +0000"))
                .env("GIT_AUTHOR_DATE", format!("@{d} +0000"));
        }
        let out = c.output().unwrap();
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    fn git(&self, args: &[&str]) -> String {
        self.git_in(&self.path("repo"), args, None)
    }

    fn commit(&self, dir: &Path, msg: &str, date: Option<i64>) {
        let f = dir.join(format!("{}.txt", msg.replace([' ', '/'], "_")));
        std::fs::write(&f, msg).unwrap();
        self.git_in(dir, &["add", "-A"], None);
        self.git_in(dir, &["commit", "-q", "-m", msg], date);
    }

    fn backdate(&self, files: &[PathBuf], t: i64) {
        for f in files.iter().filter(|f| f.exists()) {
            let ok = Command::new("touch")
                .arg("-d")
                .arg(format!("@{t}"))
                .arg(f)
                .status()
                .unwrap();
            assert!(ok.success());
        }
    }

    fn backdate_worktree(&self, name: &str, t: i64) {
        let admin = self.path("repo/.git/worktrees").join(name);
        self.backdate(
            &[
                admin.join("HEAD"),
                admin.join("logs/HEAD"),
                admin.join("index"),
            ],
            t,
        );
    }
}

const STACK: [&str; 5] = [
    "subtask/AUS-8470-a",
    "subtask/AUS-8472-b",
    "subtask/AUS-8484-c",
    "subtask/AUS-8483-d",
    "subtask/AUS-8490-e",
];

fn build() -> Fixture {
    let f = Fixture {
        tmp: tempfile::tempdir().unwrap(),
    };
    let t = now();
    let origin = f.path("origin.git");
    f.git_in(
        f.tmp.path(),
        &[
            "init",
            "-q",
            "--bare",
            "-b",
            "develop",
            origin.to_str().unwrap(),
        ],
        None,
    );
    let repo = f.path("repo");
    f.git_in(
        f.tmp.path(),
        &["init", "-q", "-b", "develop", repo.to_str().unwrap()],
        None,
    );
    f.git(&["remote", "add", "origin", origin.to_str().unwrap()]);
    f.commit(&repo, "root", None);
    f.git(&["push", "-q", "-u", "origin", "develop"]);
    f.git(&["remote", "set-head", "origin", "develop"]);

    f.git(&["checkout", "-q", "-b", "AUS-7597-epic"]);
    f.commit(&repo, "epic", None);
    f.git(&["push", "-q", "-u", "origin", "AUS-7597-epic"]);
    let mut prev = "AUS-7597-epic".to_string();
    for (i, b) in STACK.iter().enumerate() {
        f.git(&["checkout", "-q", "-b", b, &prev]);
        for n in 0..if i == 2 { 2 } else { 1 } {
            f.commit(&repo, &format!("{b} {n}"), None);
        }
        f.git(&["push", "-q", "-u", "origin", b]);
        prev = b.to_string();
    }
    f.git(&["checkout", "-q", STACK[0]]);
    f.git(&["checkout", "-q", STACK[4]]);
    f.git(&["checkout", "-q", STACK[0]]);

    f.git(&[
        "checkout",
        "-q",
        "-b",
        "subtask/AUS-8495-y",
        "origin/develop",
    ]);
    f.git(&["branch", "--unset-upstream"]);
    f.commit(&repo, "fallback", None);

    f.git(&["checkout", "-q", "-b", "AUS-9-gone", "origin/develop"]);
    f.commit(&repo, "gone work", None);
    f.git(&["push", "-q", "-u", "origin", "AUS-9-gone"]);
    f.git(&["push", "-q", "origin", "--delete", "AUS-9-gone"]);
    f.git(&["fetch", "-q", "--prune"]);

    f.git(&[
        "checkout",
        "-q",
        "-b",
        "subtask/AUS-7509-old",
        "origin/develop",
    ]);
    f.commit(&repo, "old work", Some(t - 200 * DAY));

    f.git(&[
        "checkout",
        "-q",
        "-b",
        "subtask/AUS-1-parked",
        "origin/develop",
    ]);
    f.commit(&repo, "parked work", Some(t - 200 * DAY));
    f.git(&["push", "-q", "-u", "origin", "subtask/AUS-1-parked"]);

    let wt = |name: &str, args: &[&str]| {
        let mut a = vec!["worktree", "add", "-q"];
        let p = f.path(name);
        a.extend(args);
        let mut full: Vec<String> = a.iter().map(|s| s.to_string()).collect();
        full.insert(3, p.to_str().unwrap().to_string());
        let refs: Vec<&str> = full.iter().map(String::as_str).collect();
        f.git(&refs);
        p
    };
    wt("wt-clean", &[STACK[1]]);
    wt("wt-det-reach", &["--detach", "origin/develop"]);
    let uniq = wt("wt-det-uniq", &["--detach", "origin/develop"]);
    f.commit(&uniq, "unique detached", None);
    let dirty = wt("wt-dirty", &["subtask/AUS-8495-y"]);
    std::fs::write(dirty.join("scratch.txt"), "x").unwrap();
    wt("wt-edit", &[STACK[4]]);
    wt("wt-read", &[STACK[3]]);

    let old = t - 2 * DAY;
    for name in [
        "wt-clean",
        "wt-det-reach",
        "wt-det-uniq",
        "wt-dirty",
        "wt-edit",
        "wt-read",
    ] {
        f.backdate_worktree(name, old);
    }
    let git_dir = repo.join(".git");
    f.backdate(
        &[git_dir.join("HEAD"), git_dir.join("logs/HEAD")],
        t - 200 * DAY,
    );

    let projects = f.path("claude/projects/p");
    std::fs::create_dir_all(projects.join("sid/subagents")).unwrap();
    let tool = |name: &str, input: Value| {
        serde_json::json!({
            "type": "assistant",
            "timestamp": rfc3339(t - 60),
            "message": {"content": [{"type": "tool_use", "name": name, "input": input}]}
        })
        .to_string()
    };
    let main_lines = [
        tool(
            "Edit",
            serde_json::json!({"file_path": f.path("wt-edit/x.txt").to_str().unwrap()}),
        ),
        tool(
            "Bash",
            serde_json::json!({"command": format!("git -C {} log --oneline -3", f.path("wt-read").display())}),
        ),
    ];
    std::fs::write(projects.join("sid.jsonl"), main_lines.join("\n") + "\n").unwrap();
    std::fs::write(
        projects.join("sid/subagents/agent-1.jsonl"),
        tool(
            "Write",
            serde_json::json!({"file_path": f.path("wt-dirty/new.txt").to_str().unwrap()}),
        ) + "\n",
    )
    .unwrap();

    let herdr = f.path("herdr");
    let agents = serde_json::json!({"result": {"agents": [{
        "agent": "claude",
        "agent_session": {"value": "sid"},
        "agent_status": "working",
        "cwd": repo.to_str().unwrap(),
        "foreground_cwd": repo.to_str().unwrap(),
        "pane_id": "w1:p1",
        "terminal_title_stripped": "lead"
    }]}});
    std::fs::write(f.path("agents.json"), agents.to_string()).unwrap();
    std::fs::write(
        &herdr,
        format!(
            "#!/bin/sh\n[ \"$1 $2\" = \"agent list\" ] && cat '{}'\n",
            f.path("agents.json").display()
        ),
    )
    .unwrap();
    Command::new("chmod")
        .arg("+x")
        .arg(&herdr)
        .status()
        .unwrap();

    std::fs::write(
        f.path("workview.toml"),
        format!(
            "roots = [{:?}]\nplan_globs = [{:?}]\ntranscript_globs = [{:?}]\n",
            repo.to_str().unwrap(),
            format!("{}/plans/*.md", f.tmp.path().display()),
            format!("{}/claude/projects/*/{{id}}.jsonl", f.tmp.path().display()),
        ),
    )
    .unwrap();
    f
}

fn workview(f: &Fixture, args: &[&str]) -> String {
    let mut c = Command::new(env!("CARGO_BIN_EXE_workview"));
    c.args(args)
        .env("WORKVIEW_CONFIG", f.path("workview.toml"))
        .env("HERDR_BIN_PATH", f.path("herdr"));
    f.env(&mut c);
    let out = c.output().unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

fn snapshot(dir: &Path, out: &mut BTreeMap<PathBuf, Vec<u8>>) {
    for e in std::fs::read_dir(dir).unwrap().filter_map(Result::ok) {
        let p = e.path();
        if p.is_dir() {
            snapshot(&p, out);
        } else {
            out.insert(p.clone(), std::fs::read(&p).unwrap());
        }
    }
}

fn row<'a>(m: &'a Value, label: &str) -> &'a Value {
    m["rows"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["branch"] == label)
        .unwrap_or_else(|| panic!("no row {label}"))
}

fn checkout<'a>(m: &'a Value, f: &Fixture, name: &str) -> &'a Value {
    let p = f.path(name);
    m["checkouts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["path"] == p.to_str().unwrap())
        .unwrap_or_else(|| panic!("no checkout {name}"))
}

fn has_descendant(node: &Value, key: &str) -> bool {
    node["children"]
        .as_array()
        .unwrap()
        .iter()
        .any(|c| c["key"] == key || has_descendant(c, key))
}

#[test]
fn scan_reports_bases_flags_ties_and_badge_without_writing() {
    let f = build();
    let mut before = BTreeMap::new();
    snapshot(&f.path("repo/.git"), &mut before);
    snapshot(&f.path("origin.git"), &mut before);

    let m: Value = serde_json::from_str(&workview(&f, &["json"])).unwrap();

    let mut after = BTreeMap::new();
    snapshot(&f.path("repo/.git"), &mut after);
    snapshot(&f.path("origin.git"), &mut after);
    assert!(before == after, "a scan changed a .git file");

    let first = &row(&m, STACK[0])["base"];
    assert_eq!(first["kind"], "epic");
    assert_eq!(first["key"], "AUS-7597");
    assert_eq!(first["ahead"], 1);
    for i in 1..STACK.len() {
        let base = &row(&m, STACK[i])["base"];
        assert_eq!(base["kind"], "stacked", "{}", STACK[i]);
        assert_eq!(
            base["key"].as_str(),
            STACK[i - 1].split('/').nth(1).map(|s| &s[..8]),
            "{}",
            STACK[i]
        );
    }
    assert_eq!(row(&m, STACK[2])["base"]["ahead"], 2);
    let epic = m["tickets"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["key"] == "AUS-7597")
        .expect("epic node");
    assert_eq!(epic["kind"], "epic");
    assert!(has_descendant(epic, "AUS-8490"));

    let fallback = row(&m, "subtask/AUS-8495-y");
    assert_eq!(fallback["base"]["name"], "origin/develop");
    assert_eq!(fallback["base"]["kind"], "default");
    assert_eq!(fallback["flags"]["push"], 1);
    assert_eq!(fallback["flags"]["no_upstream"], true);

    let gone = row(&m, "AUS-9-gone");
    assert_eq!(gone["flags"]["gone"], true);
    assert!(gone["flags"]["push"].is_null());
    assert!(row(&m, STACK[1])["flags"]["push"].is_null());

    assert!(
        m["rows"]
            .as_array()
            .unwrap()
            .iter()
            .all(|r| r["branch"] != "subtask/AUS-7509-old")
    );
    assert!(
        m["rows"]
            .as_array()
            .unwrap()
            .iter()
            .all(|r| r["branch"] != "subtask/AUS-1-parked")
    );
    let base = checkout(&m, &f, "repo");
    assert_eq!(base["active"], false);
    assert_eq!(base["flags"]["off_default"], true);
    assert!(base["busy"].as_array().unwrap().is_empty());

    let rem = |n: &str| checkout(&m, &f, n)["flags"]["removable"] == true;
    assert!(rem("wt-clean"));
    assert!(rem("wt-det-reach"));
    assert!(!rem("wt-det-uniq"));
    assert!(!rem("wt-dirty"));
    assert!(!rem("wt-edit"));
    assert!(!rem("wt-read"));
    assert_eq!(checkout(&m, &f, "wt-dirty")["flags"]["dirty"], true);

    let edit = checkout(&m, &f, "wt-edit");
    assert_eq!(edit["busy"][0]["signal"], "transcript");
    assert_eq!(
        checkout(&m, &f, "wt-dirty")["busy"][0]["signal"],
        "transcript"
    );
    let read = checkout(&m, &f, "wt-read");
    assert!(read["busy"].as_array().unwrap().is_empty());
    assert_eq!(read["looked_at"], true);

    assert_eq!(m["summary"]["push"], 2);
    assert_eq!(m["summary"]["stray"], 0);
    assert_eq!(m["summary"]["rm"], 2);
    assert_eq!(workview(&f, &["badge"]), "push 2 · rm 2\n");

    let all: Value = serde_json::from_str(&workview(&f, &["json", "--all"])).unwrap();
    let old = row(&all, "subtask/AUS-7509-old");
    assert_eq!(old["active"], false);
    assert!(old["flags"]["push"].is_null());
    assert_eq!(old["unpushed"], 1);
    assert_eq!(all["summary"]["push"], 2);
    let printed = workview(&f, &["print", "worktrees", "--all"]);
    assert!(printed.contains("OFF-DEFAULT"));
}

#[test]
fn badge_prints_nothing_when_nothing_waits() {
    let tmp = tempfile::tempdir().unwrap();
    let cfg = tmp.path().join("w.toml");
    std::fs::write(
        &cfg,
        format!(
            "roots = [{:?}]\n",
            tmp.path().join("none").to_str().unwrap()
        ),
    )
    .unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_workview"))
        .arg("badge")
        .env("WORKVIEW_CONFIG", &cfg)
        .env("HERDR_BIN_PATH", tmp.path().join("missing-herdr"))
        .output()
        .unwrap();
    assert!(out.status.success());
    assert!(out.stdout.is_empty());
}

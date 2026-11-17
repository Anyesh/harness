use std::path::{Path, PathBuf};

pub fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default()
}

pub fn expand_tilde(p: &str) -> PathBuf {
    match p.strip_prefix("~/") {
        Some(rest) => home().join(rest),
        None if p == "~" => home(),
        None => PathBuf::from(p),
    }
}

pub fn wildcard(pattern: &str, s: &str) -> bool {
    let (p, t): (Vec<char>, Vec<char>) = (pattern.chars().collect(), s.chars().collect());
    let (mut pi, mut ti, mut star, mut mark) = (0, 0, None, 0);
    while ti < t.len() {
        if pi < p.len() && (p[pi] == '?' || p[pi] == t[ti]) {
            pi += 1;
            ti += 1;
        } else if pi < p.len() && p[pi] == '*' {
            star = Some(pi);
            mark = ti;
            pi += 1;
        } else if let Some(sp) = star {
            pi = sp + 1;
            mark += 1;
            ti = mark;
        } else {
            return false;
        }
    }
    p[pi..].iter().all(|&c| c == '*')
}

pub fn expand(pattern: &str) -> Vec<PathBuf> {
    let full = expand_tilde(pattern);
    let mut current = vec![PathBuf::new()];
    for comp in full.components() {
        let part = comp.as_os_str().to_string_lossy();
        let mut next = Vec::new();
        for base in &current {
            if part.contains(['*', '?']) {
                next.extend(matches_in(base, &part));
            } else {
                next.push(base.join(comp.as_os_str()));
            }
        }
        current = next;
    }
    current.retain(|p| p.exists());
    current.sort();
    current
}

fn matches_in(dir: &Path, pattern: &str) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    entries
        .filter_map(Result::ok)
        .filter(|e| wildcard(pattern, &e.file_name().to_string_lossy()))
        .map(|e| e.path())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wildcard_matches() {
        assert!(wildcard("archive/*", "archive/a/b"));
        assert!(!wildcard("archive/*", "subtask/archive/x"));
        assert!(wildcard(".claude*", ".claude-chihiro"));
        assert!(wildcard("*.plan.md", "AUS-1.plan.md"));
        assert!(!wildcard("*.plan.md", "AUS-1.md"));
    }

    #[test]
    fn expand_walks_wildcard_segments() {
        let t = tempfile::tempdir().unwrap();
        for d in ["a1/x", "a2/x", "b/x"] {
            std::fs::create_dir_all(t.path().join(d)).unwrap();
            std::fs::write(t.path().join(d).join("f.jsonl"), "").unwrap();
        }
        let got = expand(&format!("{}/a*/x/f.jsonl", t.path().display()));
        assert_eq!(got.len(), 2);
    }
}

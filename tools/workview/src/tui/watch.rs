use std::collections::HashSet;
use std::path::{Path, PathBuf};

use anyhow::Result;
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};

pub struct Watch {
    watcher: RecommendedWatcher,
    watched: HashSet<PathBuf>,
}

pub fn relevant(kind: &EventKind, path: &Path) -> bool {
    matches!(
        kind,
        EventKind::Create(_) | EventKind::Modify(_) | EventKind::Remove(_)
    ) && path.extension().is_none_or(|e| e != "lock")
}

pub fn owner<'a>(path: &Path, repos: &'a [(PathBuf, PathBuf)]) -> Option<&'a PathBuf> {
    repos
        .iter()
        .filter(|(_, common)| path.starts_with(common))
        .max_by_key(|(_, common)| common.components().count())
        .map(|(repo, _)| repo)
}

impl Watch {
    /// Reads are not reported, so workview's own reads of the git dirs cause no events.
    pub fn new(sink: impl Fn(PathBuf) + Send + 'static) -> Result<Self> {
        let watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            let Ok(event) = res else { return };
            for path in event.paths {
                if relevant(&event.kind, &path) {
                    sink(path);
                }
            }
        })?;
        Ok(Watch {
            watcher,
            watched: HashSet::new(),
        })
    }

    pub fn sync(&mut self, repos: &[(PathBuf, PathBuf)]) -> Result<()> {
        for (_, common) in repos {
            let mut dirs = vec![
                (common.clone(), RecursiveMode::NonRecursive),
                (common.join("refs"), RecursiveMode::Recursive),
                (common.join("worktrees"), RecursiveMode::NonRecursive),
            ];
            if let Ok(entries) = std::fs::read_dir(common.join("worktrees")) {
                dirs.extend(
                    entries
                        .filter_map(Result::ok)
                        .map(|e| (e.path(), RecursiveMode::NonRecursive)),
                );
            }
            for (dir, mode) in dirs {
                if dir.is_dir() && !self.watched.contains(&dir) {
                    self.watcher.watch(&dir, mode)?;
                    self.watched.insert(dir);
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use notify::event::{AccessKind, ModifyKind};

    use super::*;

    #[test]
    fn lock_files_and_reads_are_ignored() {
        let modify = EventKind::Modify(ModifyKind::Any);
        assert!(relevant(&modify, Path::new("/r/.git/HEAD")));
        assert!(!relevant(&modify, Path::new("/r/.git/HEAD.lock")));
        assert!(!relevant(
            &EventKind::Access(AccessKind::Any),
            Path::new("/r/.git/HEAD")
        ));
    }

    #[test]
    fn owner_picks_the_repo_by_common_dir() {
        let repos = vec![
            (PathBuf::from("/a"), PathBuf::from("/a/.git")),
            (PathBuf::from("/a/s/b"), PathBuf::from("/a/s/b/.git")),
        ];
        assert_eq!(
            owner(Path::new("/a/s/b/.git/refs/heads/x"), &repos),
            Some(&PathBuf::from("/a/s/b"))
        );
        assert_eq!(
            owner(Path::new("/a/.git/worktrees/w/HEAD"), &repos),
            Some(&PathBuf::from("/a"))
        );
        assert_eq!(owner(Path::new("/z"), &repos), None);
    }

    #[test]
    fn a_commit_is_seen() {
        let t = tempfile::tempdir().unwrap();
        let common = t.path().join(".git");
        std::fs::create_dir_all(common.join("refs/heads")).unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        let mut w = Watch::new(move |p| {
            let _ = tx.send(p);
        })
        .unwrap();
        w.sync(&[(t.path().to_path_buf(), common.clone())]).unwrap();
        std::fs::write(common.join("refs/heads/x"), "abc\n").unwrap();
        let got = rx.recv_timeout(std::time::Duration::from_secs(2)).unwrap();
        assert!(got.starts_with(&common));
    }
}

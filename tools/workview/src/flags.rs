use crate::model::{Checkout, CheckoutFlags, Row, RowFlags, Summary};
use crate::scan::Status;

pub fn row_flags(
    unpushed: Option<u32>,
    upstream: Option<&str>,
    gone: bool,
    has_remote: bool,
    merged: bool,
    active: bool,
) -> RowFlags {
    let mut f = RowFlags {
        merged,
        ..Default::default()
    };
    if !has_remote {
        f.no_remote = true;
        return f;
    }
    if gone {
        f.gone = true;
        return f;
    }
    if let Some(n) = unpushed.filter(|n| *n > 0 && active) {
        f.push = Some(n);
        f.no_upstream = upstream.is_none();
    }
    f
}

pub struct CheckoutFacts<'a> {
    pub is_main: bool,
    pub locked: bool,
    pub prunable: bool,
    pub status: Option<&'a Status>,
    pub touched: Option<i64>,
    pub on_branch: bool,
    pub detached_reachable: Option<bool>,
    pub busy: bool,
    pub looked: bool,
    pub off_default: bool,
}

pub fn checkout_flags(f: &CheckoutFacts, now: i64, quiet_hours: u64) -> CheckoutFlags {
    let dirty = f.status.is_some_and(|s| s.dirty);
    let submodule = f.status.is_some_and(|s| s.submodule);
    let clean = f.status.is_some_and(|s| !s.dirty && !s.submodule);
    let quiet = f
        .touched
        .is_some_and(|t| now - t > quiet_hours as i64 * 3600);
    let safe_head = f.on_branch || f.detached_reachable == Some(true);
    CheckoutFlags {
        dirty,
        submodule,
        prunable: f.prunable && !f.is_main,
        removable: !f.is_main
            && !f.prunable
            && !f.locked
            && clean
            && !f.busy
            && !f.looked
            && quiet
            && safe_head,
        off_default: f.is_main && f.off_default,
    }
}

pub fn summary(rows: &[Row], checkouts: &[Checkout]) -> Summary {
    Summary {
        push: rows
            .iter()
            .filter(|r| r.active && r.flags.push.is_some())
            .count(),
        stray: checkouts.iter().filter(|c| is_stray(c)).count(),
        rm: checkouts
            .iter()
            .filter(|c| c.flags.removable || c.flags.prunable)
            .count(),
    }
}

pub fn is_stray(c: &Checkout) -> bool {
    c.is_main && c.active && c.busy.is_empty() && (c.flags.off_default || c.flags.dirty)
}

pub fn badge(s: &Summary) -> String {
    [("push", s.push), ("stray", s.stray), ("rm", s.rm)]
        .iter()
        .filter(|(_, n)| *n > 0)
        .map(|(k, n)| format!("{k} {n}"))
        .collect::<Vec<_>>()
        .join(" · ")
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;
    use crate::model::{Signal, Tie};

    const NOW: i64 = 1_800_000_000;

    #[test]
    fn push_needs_a_live_upstream_or_none() {
        let f = row_flags(Some(3), Some("origin/x"), false, true, false, true);
        assert_eq!(f.push, Some(3));
        assert!(!f.no_upstream);
        let f = row_flags(Some(3), None, false, true, false, true);
        assert_eq!(f.push, Some(3));
        assert!(f.no_upstream);
        assert_eq!(
            row_flags(Some(0), Some("o/x"), false, true, false, true).push,
            None
        );
    }

    #[test]
    fn dormant_rows_never_show_push() {
        assert_eq!(
            row_flags(Some(3), None, false, true, false, false).push,
            None
        );
    }

    #[test]
    fn gone_never_shows_push() {
        let f = row_flags(Some(5), Some("origin/x"), true, true, false, true);
        assert!(f.gone);
        assert_eq!(f.push, None);
    }

    #[test]
    fn no_remote_replaces_push() {
        let f = row_flags(Some(5), None, false, false, false, true);
        assert!(f.no_remote);
        assert_eq!(f.push, None);
    }

    fn facts(status: &Status) -> CheckoutFacts<'_> {
        CheckoutFacts {
            is_main: false,
            locked: false,
            prunable: false,
            status: Some(status),
            touched: Some(NOW - 48 * 3600),
            on_branch: true,
            detached_reachable: None,
            busy: false,
            looked: false,
            off_default: false,
        }
    }

    #[test]
    fn removable_when_quiet_clean_untied_and_safe() {
        let clean = Status::default();
        assert!(checkout_flags(&facts(&clean), NOW, 24).removable);
    }

    #[test]
    fn removable_refusals() {
        let clean = Status::default();
        let dirty = Status {
            dirty: true,
            submodule: false,
        };
        let cases: Vec<(&str, CheckoutFacts)> = vec![
            (
                "recent",
                CheckoutFacts {
                    touched: Some(NOW - 3600),
                    ..facts(&clean)
                },
            ),
            (
                "unknown activity",
                CheckoutFacts {
                    touched: None,
                    ..facts(&clean)
                },
            ),
            (
                "busy",
                CheckoutFacts {
                    busy: true,
                    ..facts(&clean)
                },
            ),
            (
                "looked",
                CheckoutFacts {
                    looked: true,
                    ..facts(&clean)
                },
            ),
            ("dirty", facts(&dirty)),
            (
                "locked",
                CheckoutFacts {
                    locked: true,
                    ..facts(&clean)
                },
            ),
            (
                "main",
                CheckoutFacts {
                    is_main: true,
                    ..facts(&clean)
                },
            ),
            (
                "detached unique",
                CheckoutFacts {
                    on_branch: false,
                    detached_reachable: Some(false),
                    ..facts(&clean)
                },
            ),
        ];
        for (name, f) in cases {
            assert!(!checkout_flags(&f, NOW, 24).removable, "{name}");
        }
        let reachable = CheckoutFacts {
            on_branch: false,
            detached_reachable: Some(true),
            ..facts(&clean)
        };
        assert!(checkout_flags(&reachable, NOW, 24).removable);
    }

    #[test]
    fn submodule_only_is_a_note_not_dirty() {
        let sub = Status {
            dirty: false,
            submodule: true,
        };
        let f = checkout_flags(
            &CheckoutFacts {
                is_main: true,
                ..facts(&sub)
            },
            NOW,
            24,
        );
        assert!(f.submodule && !f.dirty);
    }

    #[test]
    fn prunable_and_off_default() {
        let clean = Status::default();
        let f = checkout_flags(
            &CheckoutFacts {
                prunable: true,
                status: None,
                ..facts(&clean)
            },
            NOW,
            24,
        );
        assert!(f.prunable && !f.removable);
        let f = checkout_flags(
            &CheckoutFacts {
                is_main: true,
                off_default: true,
                ..facts(&clean)
            },
            NOW,
            24,
        );
        assert!(f.off_default);
    }

    fn checkout(active: bool, off_default: bool, dirty: bool, busy: bool) -> Checkout {
        Checkout {
            repo: "r".into(),
            path: PathBuf::from("/r"),
            is_main: true,
            branch: None,
            detached: None,
            locked: false,
            activity: None,
            active,
            busy: if busy {
                vec![Tie {
                    pane_id: "p".into(),
                    name: "n".into(),
                    status: "working".into(),
                    signal: Signal::Cwd,
                }]
            } else {
                Vec::new()
            },
            looked_at: false,
            flags: CheckoutFlags {
                off_default,
                dirty,
                ..Default::default()
            },
        }
    }

    #[test]
    fn stray_needs_active_unbusy_and_off_default_or_dirty() {
        assert!(is_stray(&checkout(true, true, false, false)));
        assert!(is_stray(&checkout(true, false, true, false)));
        assert!(!is_stray(&checkout(false, true, false, false)));
        assert!(!is_stray(&checkout(true, true, false, true)));
        assert!(!is_stray(&checkout(true, false, false, false)));
    }

    #[test]
    fn badge_lists_non_zero_parts() {
        assert_eq!(
            badge(&Summary {
                push: 4,
                stray: 1,
                rm: 1
            }),
            "push 4 · stray 1 · rm 1"
        );
        assert_eq!(
            badge(&Summary {
                push: 0,
                stray: 2,
                rm: 0
            }),
            "stray 2"
        );
        assert_eq!(badge(&Summary::default()), "");
    }
}

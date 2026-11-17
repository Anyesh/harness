use std::path::PathBuf;

use serde::Serialize;

pub const SCHEMA: u32 = 1;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    Story,
    Subtask,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum BaseKind {
    Default,
    Stacked,
    Story,
    Epic,
    Other,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Base {
    pub name: String,
    pub branch: String,
    pub kind: BaseKind,
    pub key: Option<String>,
    pub ahead: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Signal {
    Transcript,
    Title,
    Cwd,
}

impl Signal {
    pub fn label(self) -> &'static str {
        match self {
            Signal::Transcript => "transcript",
            Signal::Title => "title",
            Signal::Cwd => "cwd",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Tie {
    pub pane_id: String,
    pub name: String,
    pub status: String,
    pub signal: Signal,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct AgentInfo {
    pub pane_id: String,
    pub agent: String,
    pub name: String,
    pub status: String,
    pub session_id: Option<String>,
    pub cwd: Option<PathBuf>,
    pub foreground_cwd: Option<PathBuf>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct RowFlags {
    pub push: Option<u32>,
    pub gone: bool,
    pub no_upstream: bool,
    pub no_remote: bool,
    pub merged: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct Row {
    pub id: usize,
    pub repo: String,
    pub repo_path: PathBuf,
    pub branch: Option<String>,
    pub detached: Option<String>,
    pub key: Option<String>,
    pub level: Option<Level>,
    pub subject: String,
    pub commit_time: i64,
    pub upstream: Option<String>,
    pub upstream_gone: bool,
    pub unpushed: Option<u32>,
    pub base: Option<Base>,
    pub checkouts: Vec<PathBuf>,
    pub active: bool,
    pub flags: RowFlags,
    pub stale_fetch: Option<String>,
}

impl Row {
    pub fn label(&self) -> String {
        match (&self.branch, &self.detached) {
            (Some(b), _) => b.clone(),
            (None, Some(sha)) => format!("(detached {})", &sha[..sha.len().min(8)]),
            (None, None) => "(unknown)".into(),
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct CheckoutFlags {
    pub dirty: bool,
    pub submodule: bool,
    pub removable: bool,
    pub prunable: bool,
    pub off_default: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct Checkout {
    pub repo: String,
    pub path: PathBuf,
    pub is_main: bool,
    pub branch: Option<String>,
    pub detached: Option<String>,
    pub locked: bool,
    pub activity: Option<i64>,
    pub active: bool,
    pub busy: Vec<Tie>,
    pub looked_at: bool,
    pub flags: CheckoutFlags,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum NodeKind {
    Epic,
    Story,
    Ticket,
    Other,
}

#[derive(Clone, Debug, Serialize)]
pub struct Node {
    pub kind: NodeKind,
    pub key: Option<String>,
    pub title: String,
    pub rows: Vec<usize>,
    pub children: Vec<Node>,
    pub newest: i64,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Summary {
    pub push: usize,
    pub stray: usize,
    pub rm: usize,
}

#[derive(Clone, Debug, Serialize)]
pub struct RepoInfo {
    pub name: String,
    pub path: PathBuf,
    pub default: Option<String>,
    pub has_remote: bool,
    pub fetch_age_days: Option<u64>,
    pub errors: Vec<String>,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct Dormant {
    pub rows: usize,
    pub checkouts: usize,
    pub unpushed_rows: Vec<usize>,
}

#[derive(Clone, Debug, Serialize)]
pub struct Model {
    pub schema: u32,
    pub generated_at: i64,
    pub all: bool,
    pub summary: Summary,
    pub repos: Vec<RepoInfo>,
    pub tickets: Vec<Node>,
    pub rows: Vec<Row>,
    pub checkouts: Vec<Checkout>,
    pub agents: Vec<AgentInfo>,
    pub dormant: Dormant,
}

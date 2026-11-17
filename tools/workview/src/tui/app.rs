use std::collections::HashMap;
use std::path::PathBuf;

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::model::Model;
use crate::text::{self, Item, View};

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Req {
    Rescan(PathBuf),
    Agents,
    All,
    SetAll(bool),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Effect {
    Send(Req),
    Focus(String),
    Fetch(PathBuf),
    Expand {
        id: String,
        repo: PathBuf,
        tip: String,
    },
    Quit,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Shown {
    pub depth: usize,
    pub item: Item,
    pub ident: String,
}

#[derive(Default)]
pub struct App {
    pub model: Option<Model>,
    pub view: Option<View>,
    pub selected: usize,
    pub expanded: HashMap<String, Vec<String>>,
    pub filter: String,
    pub filtering: bool,
    pub confirm_fetch: Option<PathBuf>,
    pub help: bool,
    pub all: bool,
    pub status: String,
    pub watch_note: Option<String>,
}

fn row_ident(m: &Model, i: usize) -> String {
    let r = &m.rows[i];
    format!("row\0{}\0{}", r.repo, r.label())
}

impl App {
    pub fn view(&self) -> View {
        self.view.unwrap_or(View::Tickets)
    }

    pub fn shown(&self) -> Vec<Shown> {
        let Some(m) = &self.model else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for l in text::lines(m, self.view(), None, &self.filter) {
            let ident = match &l.item {
                Item::Row(i) => row_ident(m, *i),
                Item::Checkout(i) => format!("co\0{}", m.checkouts[*i].path.display()),
                Item::Node { key, title, .. } => format!("node\0{key:?}\0{title}"),
                Item::Heading(s) | Item::Note(s) => format!("text\0{s}"),
            };
            let log = self.expanded.get(&ident).cloned();
            out.push(Shown {
                depth: l.depth,
                item: l.item,
                ident: ident.clone(),
            });
            for (n, entry) in log.into_iter().flatten().enumerate() {
                out.push(Shown {
                    depth: l.depth + 1,
                    item: Item::Note(entry),
                    ident: format!("{ident}\0log{n}"),
                });
            }
        }
        out
    }

    pub fn set_model(&mut self, m: Model) {
        let before = self.shown().get(self.selected).map(|s| s.ident.clone());
        self.all = m.all;
        self.model = Some(m);
        let shown = self.shown();
        if let Some(id) = before
            && let Some(i) = shown.iter().position(|s| s.ident == id)
        {
            self.selected = i;
        }
        self.selected = self.selected.min(shown.len().saturating_sub(1));
    }

    fn selected_item(&self) -> Option<Shown> {
        self.shown().into_iter().nth(self.selected)
    }

    fn selected_repo(&self) -> Option<PathBuf> {
        let m = self.model.as_ref()?;
        match self.selected_item()?.item {
            Item::Row(i) => Some(m.rows[i].repo_path.clone()),
            Item::Checkout(i) => {
                let c = &m.checkouts[i];
                m.repos
                    .iter()
                    .find(|r| r.name == c.repo)
                    .map(|r| r.path.clone())
            }
            _ => None,
        }
    }

    fn busy_pane(&self) -> Option<String> {
        let m = self.model.as_ref()?;
        let paths: Vec<PathBuf> = match self.selected_item()?.item {
            Item::Row(i) => m.rows[i].checkouts.clone(),
            Item::Checkout(i) => vec![m.checkouts[i].path.clone()],
            _ => return None,
        };
        m.checkouts
            .iter()
            .filter(|c| paths.contains(&c.path))
            .find_map(|c| c.busy.first().map(|t| t.pane_id.clone()))
    }

    fn toggle_expand(&mut self) -> Vec<Effect> {
        let Some(s) = self.selected_item() else {
            return Vec::new();
        };
        let Item::Row(i) = s.item else {
            return Vec::new();
        };
        if self.expanded.remove(&s.ident).is_some() {
            return Vec::new();
        }
        let Some(m) = &self.model else {
            return Vec::new();
        };
        let r = &m.rows[i];
        let tip = r
            .branch
            .clone()
            .or_else(|| r.detached.clone())
            .unwrap_or_default();
        vec![Effect::Expand {
            id: s.ident,
            repo: r.repo_path.clone(),
            tip,
        }]
    }

    pub fn set_expanded(&mut self, id: String, log: Vec<String>) {
        let log = if log.is_empty() {
            vec!["(no unpushed commits)".to_string()]
        } else {
            log
        };
        self.expanded.insert(id, log);
    }

    fn move_to(&mut self, i: usize) {
        let n = self.shown().len();
        self.selected = i.min(n.saturating_sub(1));
    }

    pub fn key(&mut self, k: KeyEvent) -> Vec<Effect> {
        if k.modifiers.contains(KeyModifiers::CONTROL) && k.code == KeyCode::Char('c') {
            return vec![Effect::Quit];
        }
        if let Some(repo) = self.confirm_fetch.take() {
            if k.code == KeyCode::Char('y') {
                self.status = format!("fetching {}", repo.display());
                return vec![Effect::Fetch(repo)];
            }
            self.status = "fetch cancelled".into();
            return Vec::new();
        }
        if self.filtering {
            match k.code {
                KeyCode::Enter => self.filtering = false,
                KeyCode::Esc => {
                    self.filtering = false;
                    self.filter.clear();
                }
                KeyCode::Backspace => {
                    self.filter.pop();
                }
                KeyCode::Char(c) => self.filter.push(c),
                _ => {}
            }
            self.move_to(self.selected);
            return Vec::new();
        }
        if self.help {
            self.help = false;
            return Vec::new();
        }
        match k.code {
            KeyCode::Char('q') => return vec![Effect::Quit],
            KeyCode::Char('1') => self.switch(View::Tickets),
            KeyCode::Char('2') => self.switch(View::Push),
            KeyCode::Char('3') => self.switch(View::Worktrees),
            KeyCode::Char('j') | KeyCode::Down => self.move_to(self.selected + 1),
            KeyCode::Char('k') | KeyCode::Up => self.move_to(self.selected.saturating_sub(1)),
            KeyCode::Char('g') | KeyCode::Home => self.move_to(0),
            KeyCode::Char('G') | KeyCode::End => self.move_to(usize::MAX),
            KeyCode::Char(' ') => return self.toggle_expand(),
            KeyCode::Enter => {
                return match self.busy_pane() {
                    Some(p) => vec![Effect::Focus(p)],
                    None => self.toggle_expand(),
                };
            }
            KeyCode::Char('/') => {
                self.filtering = true;
                self.filter.clear();
            }
            KeyCode::Esc => self.filter.clear(),
            KeyCode::Char('a') => {
                self.all = !self.all;
                self.status = if self.all {
                    "loading all rows"
                } else {
                    "active rows only"
                }
                .into();
                return vec![Effect::Send(Req::SetAll(self.all))];
            }
            KeyCode::Char('r') => {
                self.status = "rescanning".into();
                return vec![Effect::Send(Req::All)];
            }
            KeyCode::Char('F') => match self.selected_repo() {
                Some(repo) => {
                    self.status = format!("fetch {}? y/n", repo.display());
                    self.confirm_fetch = Some(repo);
                }
                None => self.status = "select a branch or checkout to fetch its repo".into(),
            },
            KeyCode::Char('?') => self.help = true,
            _ => {}
        }
        Vec::new()
    }

    fn switch(&mut self, v: View) {
        self.view = Some(v);
        self.selected = 0;
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use ratatui::crossterm::event::KeyEventKind;

    use super::*;
    use crate::model::{
        Checkout, CheckoutFlags, Dormant, Node, NodeKind, Row, RowFlags, Signal, Summary, Tie,
    };

    fn key(c: KeyCode) -> KeyEvent {
        KeyEvent {
            code: c,
            modifiers: KeyModifiers::NONE,
            kind: KeyEventKind::Press,
            state: ratatui::crossterm::event::KeyEventState::NONE,
        }
    }

    fn model() -> Model {
        let row = |id: usize, b: &str, path: &str| Row {
            id,
            repo: "r".into(),
            repo_path: PathBuf::from("/r"),
            branch: Some(b.into()),
            detached: None,
            key: crate::ticket::extract_key(b),
            level: None,
            subject: String::new(),
            commit_time: 10 - id as i64,
            upstream: None,
            upstream_gone: false,
            unpushed: Some(1),
            base: None,
            checkouts: vec![PathBuf::from(path)],
            active: true,
            flags: RowFlags {
                push: Some(1),
                ..Default::default()
            },
            stale_fetch: None,
        };
        let busy = Tie {
            pane_id: "w1:p2".into(),
            name: "worker".into(),
            status: "working".into(),
            signal: Signal::Transcript,
        };
        let co = |path: &str, busy: Vec<Tie>| Checkout {
            repo: "r".into(),
            path: PathBuf::from(path),
            is_main: false,
            branch: None,
            detached: None,
            locked: false,
            activity: None,
            active: true,
            busy,
            looked_at: false,
            flags: CheckoutFlags::default(),
        };
        let node = |k: &str, rows: Vec<usize>| Node {
            kind: NodeKind::Ticket,
            key: Some(k.into()),
            title: String::new(),
            rows,
            children: Vec::new(),
            newest: 0,
        };
        Model {
            schema: 1,
            generated_at: 0,
            all: false,
            summary: Summary::default(),
            repos: Vec::new(),
            tickets: vec![node("AUS-1", vec![0]), node("AUS-2", vec![1])],
            rows: vec![row(0, "AUS-1-a", "/w/a"), row(1, "AUS-2-b", "/w/b")],
            checkouts: vec![co("/w/a", vec![busy]), co("/w/b", Vec::new())],
            agents: Vec::new(),
            dormant: Dormant::default(),
        }
    }

    #[test]
    fn enter_on_a_busy_row_focuses_its_agent() {
        let mut app = App::default();
        app.set_model(model());
        app.key(key(KeyCode::Char('j')));
        assert_eq!(
            app.key(key(KeyCode::Enter)),
            vec![Effect::Focus("w1:p2".into())]
        );
    }

    #[test]
    fn enter_on_an_idle_row_expands_it() {
        let mut app = App::default();
        app.set_model(model());
        app.key(key(KeyCode::Char('G')));
        let fx = app.key(key(KeyCode::Enter));
        let Some(Effect::Expand { id, tip, .. }) = fx.first().cloned() else {
            panic!("{fx:?}");
        };
        assert_eq!(tip, "AUS-2-b");
        app.set_expanded(id, vec!["abc fix".into()]);
        assert_eq!(app.shown().len(), 5);
    }

    #[test]
    fn selection_follows_the_row_across_updates() {
        let mut app = App::default();
        app.set_model(model());
        app.key(key(KeyCode::Char('G')));
        let mut m = model();
        m.tickets.reverse();
        app.set_model(m);
        assert_eq!(app.selected, 1);
    }

    #[test]
    fn fetch_needs_confirmation() {
        let mut app = App::default();
        app.set_model(model());
        app.key(key(KeyCode::Char('j')));
        assert!(app.key(key(KeyCode::Char('F'))).is_empty());
        assert_eq!(app.key(key(KeyCode::Char('n'))), Vec::new());
        app.key(key(KeyCode::Char('F')));
        assert_eq!(
            app.key(key(KeyCode::Char('y'))),
            vec![Effect::Fetch(PathBuf::from("/r"))]
        );
    }

    #[test]
    fn filter_narrows_lines() {
        let mut app = App::default();
        app.set_model(model());
        app.key(key(KeyCode::Char('/')));
        for c in "aus-2".chars() {
            app.key(key(KeyCode::Char(c)));
        }
        app.key(key(KeyCode::Enter));
        assert_eq!(app.shown().len(), 2);
    }

    #[test]
    fn a_toggles_all() {
        let mut app = App::default();
        app.set_model(model());
        assert_eq!(
            app.key(key(KeyCode::Char('a'))),
            vec![Effect::Send(Req::SetAll(true))]
        );
    }
}

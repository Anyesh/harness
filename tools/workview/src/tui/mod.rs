mod app;
mod ui;
mod watch;

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::Result;
use ratatui::DefaultTerminal;
use ratatui::crossterm::event::{self, Event, KeyEventKind};
use ratatui::widgets::ListState;

use crate::config::Config;
use crate::model::Model;
use crate::world::World;
use crate::{agents, git, scan};
use app::{App, Effect, Req};
use watch::Watch;

const DEBOUNCE: Duration = Duration::from_millis(300);
const AGENTS_EVERY: Duration = Duration::from_secs(3);
const FULL_EVERY: Duration = Duration::from_secs(60);
const FALLBACK_EVERY: Duration = Duration::from_secs(10);

enum Msg {
    Key(event::KeyEvent),
    Resize,
    Model(Box<Model>, Vec<(PathBuf, PathBuf)>),
    Changed(PathBuf),
    Fetched(PathBuf, Result<(), String>),
    Expanded(String, Vec<String>),
}

fn commons(world: &World) -> Vec<(PathBuf, PathBuf)> {
    world
        .repos
        .iter()
        .map(|r| (r.path.clone(), r.common_dir.clone()))
        .collect()
}

fn worker(cfg: Config, reqs: Receiver<Req>, tx: Sender<Msg>) {
    let mut world = World::load(cfg, false);
    if tx
        .send(Msg::Model(Box::new(world.model()), commons(&world)))
        .is_err()
    {
        return;
    }
    while let Ok(first) = reqs.recv() {
        let mut batch = vec![first];
        batch.extend(reqs.try_iter());
        let mut seen = HashSet::new();
        batch.retain(|r| seen.insert(r.clone()));
        if batch.contains(&Req::All) {
            batch.retain(|r| matches!(r, Req::SetAll(_)));
            batch.insert(0, Req::All);
        }
        for req in batch {
            match req {
                Req::All => world.rescan_all(),
                Req::Agents => world.refresh_agents(),
                Req::SetAll(all) => world.set_all(all),
                Req::Rescan(p) => world.rescan_repo(&p),
            }
        }
        if tx
            .send(Msg::Model(Box::new(world.model()), commons(&world)))
            .is_err()
        {
            return;
        }
    }
}

pub fn run(cfg: Config) -> Result<()> {
    let (tx, rx) = mpsc::channel::<Msg>();
    let (req_tx, req_rx) = mpsc::channel::<Req>();
    {
        let tx = tx.clone();
        thread::spawn(move || worker(cfg, req_rx, tx));
    }
    {
        let tx = tx.clone();
        thread::spawn(move || {
            while let Ok(ev) = event::read() {
                let msg = match ev {
                    Event::Key(k) if k.kind == KeyEventKind::Press => Msg::Key(k),
                    Event::Resize(..) => Msg::Resize,
                    _ => continue,
                };
                if tx.send(msg).is_err() {
                    return;
                }
            }
        });
    }
    let mut app = App::default();
    let watch = {
        let tx = tx.clone();
        Watch::new(move |p| {
            let _ = tx.send(Msg::Changed(p));
        })
    };
    let watch = match watch {
        Ok(w) => Some(w),
        Err(e) => {
            app.watch_note = Some(format!("watcher failed ({e}); rescanning every 10 s"));
            None
        }
    };
    let mut terminal = ratatui::init();
    let result = event_loop(&mut terminal, app, watch, &rx, &tx, &req_tx);
    ratatui::restore();
    result
}

fn event_loop(
    terminal: &mut DefaultTerminal,
    mut app: App,
    mut watch: Option<Watch>,
    rx: &Receiver<Msg>,
    tx: &Sender<Msg>,
    req_tx: &Sender<Req>,
) -> Result<()> {
    let mut list = ListState::default();
    let mut repos: Vec<(PathBuf, PathBuf)> = Vec::new();
    let mut pending: HashSet<PathBuf> = HashSet::new();
    let mut pending_at: Option<Instant> = None;
    let full_every = if watch.is_some() {
        FULL_EVERY
    } else {
        FALLBACK_EVERY
    };
    let mut next_agents = Instant::now() + AGENTS_EVERY;
    let mut next_full = Instant::now() + full_every;
    let mut dirty = true;
    loop {
        if dirty {
            terminal.draw(|f| ui::draw(f, &app, &mut list))?;
            dirty = false;
        }
        let now = Instant::now();
        let mut deadline = next_agents.min(next_full);
        if let Some(p) = pending_at {
            deadline = deadline.min(p);
        }
        match rx.recv_timeout(deadline.saturating_duration_since(now)) {
            Ok(Msg::Key(k)) => {
                for fx in app.key(k) {
                    match fx {
                        Effect::Quit => return Ok(()),
                        Effect::Send(r) => {
                            let _ = req_tx.send(r);
                        }
                        Effect::Focus(pane) => {
                            if let Err(e) = agents::focus(&pane) {
                                app.status = e.to_string();
                            }
                        }
                        Effect::Fetch(repo) => {
                            let tx = tx.clone();
                            thread::spawn(move || {
                                let r = git::fetch(&repo).map_err(|e| e.to_string());
                                let _ = tx.send(Msg::Fetched(repo, r));
                            });
                        }
                        Effect::Expand { id, repo, tip } => {
                            let tx = tx.clone();
                            thread::spawn(move || {
                                let _ = tx.send(Msg::Expanded(id, scan::unpushed_log(&repo, &tip)));
                            });
                        }
                    }
                }
                dirty = true;
            }
            Ok(Msg::Resize) => dirty = true,
            Ok(Msg::Model(m, r)) => {
                if let Some(w) = watch.as_mut()
                    && let Err(e) = w.sync(&r)
                {
                    app.watch_note = Some(format!("watcher failed ({e}); rescanning every 10 s"));
                    watch = None;
                    next_full = Instant::now() + FALLBACK_EVERY;
                }
                repos = r;
                if app.status == "rescanning" || app.status.starts_with("loading") {
                    app.status.clear();
                }
                app.set_model(*m);
                dirty = true;
            }
            Ok(Msg::Changed(path)) => {
                if let Some(repo) = watch::owner(&path, &repos) {
                    pending.insert(repo.clone());
                    pending_at.get_or_insert_with(|| Instant::now() + DEBOUNCE);
                }
            }
            Ok(Msg::Fetched(repo, r)) => {
                app.status = match r {
                    Ok(()) => format!("fetched {}", repo.display()),
                    Err(e) => format!("fetch failed: {e}"),
                };
                let _ = req_tx.send(Req::Rescan(repo));
                dirty = true;
            }
            Ok(Msg::Expanded(id, log)) => {
                app.set_expanded(id, log);
                dirty = true;
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return Ok(()),
        }
        let now = Instant::now();
        if pending_at.is_some_and(|p| now >= p) {
            for repo in pending.drain() {
                let _ = req_tx.send(Req::Rescan(repo));
            }
            pending_at = None;
        }
        if now >= next_agents {
            let _ = req_tx.send(Req::Agents);
            next_agents = now + AGENTS_EVERY;
        }
        if now >= next_full {
            let _ = req_tx.send(Req::All);
            next_full = now
                + if watch.is_some() {
                    FULL_EVERY
                } else {
                    FALLBACK_EVERY
                };
        }
    }
}

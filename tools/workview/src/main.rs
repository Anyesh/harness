mod action;
mod agents;
mod assemble;
mod base;
mod config;
mod flags;
mod git;
mod glob;
mod model;
mod scan;
mod text;
mod ticket;
mod tui;
mod world;

use std::time::Instant;

use anyhow::{Result, bail};

use crate::text::View;
use crate::world::World;

const USAGE: &str = "usage: workview [--timing] [print [tickets|push|worktrees] [--all] [--key KEY] | json [--all] | badge | --action open]";

struct Args {
    command: String,
    view: View,
    all: bool,
    key: Option<String>,
    timing: bool,
}

fn parse(argv: &[String]) -> Result<Args> {
    let mut a = Args {
        command: "tui".into(),
        view: View::Tickets,
        all: false,
        key: None,
        timing: false,
    };
    let mut it = argv.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--all" => a.all = true,
            "--timing" => a.timing = true,
            "--key" => a.key = it.next().cloned(),
            "--action" => match it.next().map(String::as_str) {
                Some("open") => a.command = "open".into(),
                other => bail!("unknown action {other:?}\n{USAGE}"),
            },
            "print" | "json" | "badge" if a.command == "tui" => a.command = arg.clone(),
            "-h" | "--help" => {
                println!("{USAGE}");
                std::process::exit(0);
            }
            v if a.command == "print" && View::parse(v).is_some() => {
                a.view = View::parse(v).expect("checked");
            }
            other => bail!("unexpected argument {other}\n{USAGE}"),
        }
    }
    Ok(a)
}

fn main() {
    if let Err(e) = run() {
        eprintln!("workview: {e:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let args = parse(&argv)?;
    if args.command == "open" {
        return action::open();
    }
    let cfg = config::load()?;
    if args.command == "tui" {
        return tui::run(cfg);
    }
    let start = Instant::now();
    let world = World::load(cfg, args.all);
    let model = world.model();
    if args.timing {
        eprintln!(
            "workview: scanned {} repos in {} ms",
            model.repos.len(),
            start.elapsed().as_millis()
        );
    }
    match args.command.as_str() {
        "json" => println!("{}", serde_json::to_string_pretty(&model)?),
        "badge" => {
            let line = flags::badge(&model.summary);
            if !line.is_empty() {
                println!("{line}");
            }
        }
        _ => print!("{}", text::render(&model, args.view, args.key.as_deref())),
    }
    Ok(())
}

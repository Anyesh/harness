use std::process::Command;

use anyhow::{Context, Result, bail};
use serde_json::Value;

use crate::agents::herdr_bin;

const PROGRAM: &str = "workview";

fn herdr(args: &[&str]) -> Result<Value> {
    let out = Command::new(herdr_bin())
        .args(args)
        .output()
        .with_context(|| format!("run herdr {}", args.join(" ")))?;
    if !out.status.success() {
        bail!(
            "herdr {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(serde_json::from_slice(&out.stdout).unwrap_or_default())
}

fn runs_workview(info: &Value) -> bool {
    info["result"]["process_info"]["foreground_processes"]
        .as_array()
        .is_some_and(|ps| ps.iter().any(|p| p["name"] == PROGRAM))
}

/// `herdr plugin pane` lists nothing, so the running pane is found by its foreground
/// program, which keeps one workview across every workspace.
pub fn open() -> Result<()> {
    let panes = herdr(&["pane", "list"])?;
    for pane in panes["result"]["panes"].as_array().into_iter().flatten() {
        if pane.get("agent").is_some_and(|a| !a.is_null()) {
            continue;
        }
        let Some(id) = pane["pane_id"].as_str() else {
            continue;
        };
        let info = herdr(&["pane", "process-info", "--pane", id]).unwrap_or_default();
        if runs_workview(&info) {
            herdr(&["plugin", "pane", "focus", id])?;
            return Ok(());
        }
    }
    let answer = herdr(&[
        "plugin",
        "pane",
        "open",
        "--plugin",
        PROGRAM,
        "--entrypoint",
        "view",
        "--placement",
        "tab",
        "--focus",
    ])?;
    if let Some(tab) = answer["result"]["plugin_pane"]["pane"]["tab_id"].as_str()
        && let Err(e) = herdr(&["tab", "rename", tab, PROGRAM])
    {
        eprintln!("workview: tab rename: {e}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_a_workview_foreground_process() {
        let v: Value = serde_json::from_str(
            r#"{"result":{"process_info":{"foreground_processes":[{"name":"workview"}]}}}"#,
        )
        .unwrap();
        assert!(runs_workview(&v));
        assert!(!runs_workview(&Value::Null));
    }
}

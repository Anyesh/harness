use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, List, ListItem, ListState, Paragraph, Wrap};

use super::app::App;
use crate::flags;
use crate::model::NodeKind;
use crate::text::{self, Item, View};

const HELP: &str = "1 tickets   2 to push   3 worktrees
j/k move   g/G top/bottom
space  show unpushed commits
enter  focus the busy agent, else expand
/      filter by key or text (esc clears)
a      active only / everything
r      rescan   F fetch the selected repo (asks y/n)
q      quit";

fn field_style(field: &str) -> Style {
    let s = Style::default();
    if field.starts_with("PUSH") {
        s.fg(Color::Yellow).add_modifier(Modifier::BOLD)
    } else if field.starts_with("BUSY") {
        s.fg(Color::Green)
    } else if field.starts_with("DIRTY") {
        s.fg(Color::Red)
    } else if field.starts_with("REMOVABLE") || field.starts_with("PRUNABLE") {
        s.fg(Color::Magenta)
    } else if field.starts_with("OFF-DEFAULT") {
        s.fg(Color::Cyan)
    } else if field.starts_with('+') {
        s.fg(Color::Blue)
    } else if field.starts_with("GONE")
        || field.starts_with("NO-")
        || field.starts_with('(')
        || field == "merged"
        || field == "submodule"
    {
        s.fg(Color::DarkGray)
    } else {
        s
    }
}

fn styled(depth: usize, item: &Item, text: String) -> Line<'static> {
    let indent = Span::raw("  ".repeat(depth));
    match item {
        Item::Node { kind, .. } => {
            let color = match kind {
                NodeKind::Epic => Color::Magenta,
                NodeKind::Story => Color::Blue,
                NodeKind::Ticket => Color::White,
                NodeKind::Other => Color::Gray,
            };
            Line::from(vec![
                indent,
                Span::styled(
                    text,
                    Style::default().fg(color).add_modifier(Modifier::BOLD),
                ),
            ])
        }
        Item::Heading(_) => Line::from(vec![
            indent,
            Span::styled(
                text,
                Style::default().add_modifier(Modifier::BOLD | Modifier::UNDERLINED),
            ),
        ]),
        Item::Note(_) => Line::from(vec![
            indent,
            Span::styled(text, Style::default().fg(Color::DarkGray)),
        ]),
        Item::Row(_) | Item::Checkout(_) => {
            let mut spans = vec![indent];
            for (i, field) in text.split("  ").enumerate() {
                if i > 0 {
                    spans.push(Span::raw("  "));
                }
                let style = if i == 0 {
                    Style::default().fg(Color::Gray)
                } else {
                    field_style(field)
                };
                spans.push(Span::styled(field.to_string(), style));
            }
            Line::from(spans)
        }
    }
}

fn tabs(view: View, all: bool) -> Line<'static> {
    let mut spans = Vec::new();
    for (v, label) in [
        (View::Tickets, "1 tickets"),
        (View::Push, "2 to push"),
        (View::Worktrees, "3 worktrees"),
    ] {
        let style = if v == view {
            Style::default().add_modifier(Modifier::REVERSED)
        } else {
            Style::default().fg(Color::DarkGray)
        };
        spans.push(Span::styled(format!(" {label} "), style));
        spans.push(Span::raw(" "));
    }
    if all {
        spans.push(Span::styled(" all ", Style::default().fg(Color::Yellow)));
    }
    Line::from(spans)
}

pub fn draw(f: &mut Frame, app: &App, list: &mut ListState) {
    let [head, body, foot] = Layout::vertical([
        Constraint::Length(2),
        Constraint::Min(1),
        Constraint::Length(2),
    ])
    .areas(f.area());
    let Some(model) = &app.model else {
        f.render_widget(Paragraph::new("workview: scanning…"), body);
        return;
    };
    let badge = flags::badge(&model.summary);
    let badge = if badge.is_empty() {
        "nothing waits".to_string()
    } else {
        badge
    };
    f.render_widget(
        Paragraph::new(vec![
            Line::styled(badge, Style::default().add_modifier(Modifier::BOLD)),
            tabs(app.view(), app.all),
        ]),
        head,
    );
    let shown = app.shown();
    let items: Vec<ListItem> = shown
        .iter()
        .map(|s| {
            let text = match &s.item {
                Item::Note(n) => n.clone(),
                other => text::item_text(model, other),
            };
            ListItem::new(styled(s.depth, &s.item, text))
        })
        .collect();
    list.select((!shown.is_empty()).then_some(app.selected));
    f.render_stateful_widget(
        List::new(items).highlight_style(Style::default().bg(Color::Rgb(60, 56, 54))),
        body,
        list,
    );
    let mut status = if app.filtering || !app.filter.is_empty() {
        format!("/{}", app.filter)
    } else {
        app.status.clone()
    };
    if let Some(note) = &app.watch_note {
        status = format!("{status}  {note}");
    }
    f.render_widget(
        Paragraph::new(vec![
            Line::styled(text::footer(model), Style::default().fg(Color::DarkGray)),
            Line::from(format!("{status}  ? help")),
        ]),
        foot,
    );
    if app.help {
        let area = centered(f.area(), 54, 12);
        f.render_widget(Clear, area);
        f.render_widget(
            Paragraph::new(HELP)
                .wrap(Wrap { trim: false })
                .block(Block::default().borders(Borders::ALL).title(" keys ")),
            area,
        );
    }
}

fn centered(r: Rect, w: u16, h: u16) -> Rect {
    let w = w.min(r.width);
    let h = h.min(r.height);
    Rect::new(r.x + (r.width - w) / 2, r.y + (r.height - h) / 2, w, h)
}

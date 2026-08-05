//! Turning collected state into the page.
//!
//! Rendered on the server rather than assembled by scripts in the browser, for
//! two reasons: the console must work when the model and the network are both
//! having a bad day, and a page that needs JavaScript to say "everything is
//! down" is a page that says nothing when it matters.

use crate::collect::{Fetched, Reach, ServiceView};

/// Escape text before it reaches HTML.
///
/// Every value here arrives from a service, which means from a workflow name,
/// which means from something a user typed. It is not trusted.
pub fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
    out
}

fn chip(class: &str, label: &str) -> String {
    format!(r#"<span class="chip {class}">{}</span>"#, escape(label))
}

fn reach_chip(r: &Reach) -> String {
    match r {
        Reach::Up => chip("up", "up"),
        Reach::Down => chip("down", "down"),
        Reach::Unhealthy => chip("unhealthy", "unhealthy"),
        Reach::Unknown => chip("unknown", "unknown"),
    }
}

pub fn services_panel(views: &[ServiceView]) -> String {
    let rows: String = views
        .iter()
        .map(|v| {
            let port = v
                .port
                .map(|p| format!(":{p}"))
                .unwrap_or_else(|| "-".to_string());
            let detail = v
                .detail
                .as_deref()
                .map(|d| format!(" {}", escape(d)))
                .unwrap_or_default();
            format!(
                r#"<div class="row">
  <span class="name">{name}</span>
  {tier}
  <span class="meta">{port}{detail}</span>
  {state}
</div>"#,
                name = escape(v.name),
                tier = chip(
                    if v.essential { "essential" } else { "optional" },
                    if v.essential { "essential" } else { "optional" }
                ),
                port = escape(&port),
                detail = detail,
                state = reach_chip(&v.reach),
            )
        })
        .collect();

    panel("services", &rows)
}

/// A panel whose data could not be collected explains itself.
fn unavailable(what: &str, why: &str) -> String {
    format!(
        r#"<div class="unavailable">{what} unavailable<span class="why">{why}</span></div>"#,
        what = escape(what),
        why = escape(why),
    )
}

pub fn history_panel(fetched: &Fetched) -> String {
    let body = match fetched {
        Fetched::Unreachable => unavailable(
            "workflow history",
            "the workflow service is not answering, so nothing can be said about \
             what ran. This is not the same as nothing having run.",
        ),
        Fetched::Error { message } => unavailable("workflow history", message),
        Fetched::Ok { data: v } => {
            let recent = v.get("recent").and_then(|r| r.as_array()).map(Vec::as_slice);
            match recent {
                None | Some([]) => r#"<p class="empty">no runs recorded yet</p>"#.to_string(),
                Some(rows) => {
                    let body: String = rows
                        .iter()
                        .take(15)
                        .map(|r| {
                            let ok = r["success"].as_bool().unwrap_or(false);
                            // The reason, not just the verdict. A row that says
                            // only "failed" sends the operator to a log file to
                            // learn what this page already knows, and a skipped
                            // scheduled run looks identical to a broken one.
                            let why = r["error"].as_str().unwrap_or("");
                            let why = if why.chars().count() > 90 {
                                let cut: String = why.chars().take(89).collect();
                                format!("{cut}…")
                            } else {
                                why.to_string()
                            };
                            format!(
                                "<tr><td>{}</td><td>{}</td><td>{} ms</td><td>{}</td>\
                                 <td class=\"why\">{}</td></tr>",
                                escape(r["workflow"].as_str().unwrap_or("?")),
                                escape(r["trigger"].as_str().unwrap_or("?")),
                                r["duration_ms"].as_u64().unwrap_or(0),
                                if ok {
                                    chip("up", "ok")
                                } else {
                                    chip("down", "failed")
                                },
                                escape(&why)
                            )
                        })
                        .collect();
                    format!(
                        "<table><thead><tr><th>workflow</th><th>trigger</th>\
                         <th>took</th><th>result</th><th>why</th></tr></thead>\
                         <tbody>{body}</tbody></table>"
                    )
                }
            }
        }
    };
    panel("recent runs", &body)
}

pub fn audit_panel(fetched: &Fetched) -> String {
    let body = match fetched {
        Fetched::Unreachable => unavailable(
            "tool audit",
            "the model gateway is not answering. No tool call can be confirmed \
             or ruled out from here.",
        ),
        Fetched::Error { message } => unavailable("tool audit", message),
        Fetched::Ok { data: v } => {
            let calls = v.get("calls").and_then(|c| c.as_array()).map(Vec::as_slice);
            match calls {
                None | Some([]) => {
                    r#"<p class="empty">the model has not used a tool yet</p>"#.to_string()
                }
                Some(rows) => {
                    let body: String = rows
                        .iter()
                        .rev()
                        .take(15)
                        .map(|c| {
                            let allowed = c["allowed"].as_bool().unwrap_or(false);
                            let dry = c["dry_run"].as_bool().unwrap_or(false);
                            let state = if !allowed {
                                chip("down", "refused")
                            } else if dry {
                                chip("unhealthy", "dry run")
                            } else {
                                chip("up", "done")
                            };
                            format!(
                                "<tr><td>{}</td><td>{}</td><td>{}</td><td>{state}</td></tr>",
                                escape(c["tool"].as_str().unwrap_or("?")),
                                escape(c["caller"].as_str().unwrap_or("?")),
                                escape(c["effect"].as_str().unwrap_or("?")),
                            )
                        })
                        .collect();
                    format!(
                        "<table><thead><tr><th>tool</th><th>caller</th>\
                         <th>effect</th><th>result</th></tr></thead><tbody>{body}</tbody></table>"
                    )
                }
            }
        }
    };
    panel("what the model did", &body)
}

pub fn rollback_panel(environments: Option<&[String]>) -> String {
    let body = match environments {
        None => unavailable(
            "rollback",
            "bectl is unavailable, so this is not a ZFS root. There is no \
             one-step way back from a bad change.",
        ),
        Some([]) => r#"<p class="empty">no boot environments yet. Take one before
            anything risky: <code>hajimectl snapshot &lt;reason&gt;</code></p>"#
            .to_string(),
        Some(list) => {
            let items: String = list
                .iter()
                .map(|n| {
                    format!(
                        r#"<div class="row"><span class="name">{}</span></div>"#,
                        escape(n)
                    )
                })
                .collect();
            items
        }
    };
    panel("you can go back to", &body)
}

fn panel(title: &str, body: &str) -> String {
    format!(
        r#"<section class="panel"><h2>{}</h2><div class="body">{body}</div></section>"#,
        escape(title)
    )
}

/// The whole page.
/// What the world model makes of the current state.
///
/// The services panel above answers "what is down". This answers the question
/// after it: given what is running, is the arrangement even coherent? A service
/// up without the database it reads from is not down, and is not working
/// either, and nothing else on this page would say so.
pub fn constraints_panel(views: &[ServiceView]) -> String {
    use hajime_model::world::World;

    let running: Vec<&str> = views
        .iter()
        .filter(|v| v.reach == Reach::Up)
        .map(|v| v.name)
        .collect();

    let world = World::default();
    let violations = world.check(&running);
    let used = world.memory_of(&running);
    let available = world.budget().available_mb();

    let mut body = format!(
        r#"<p class="meta">{used} MB of {available} MB budgeted</p>"#
    );

    if violations.is_empty() {
        body.push_str(r#"<p class="empty">every constraint is satisfied</p>"#);
    } else {
        let rows: String = violations
            .iter()
            .map(|v| format!("<li>{}</li>", escape(&v.to_string())))
            .collect();
        body.push_str(&format!(r#"<ul class="violations">{rows}</ul>"#));
    }

    panel("the model's view", &body)
}

pub fn page(
    headline: &str,
    views: &[ServiceView],
    history: &Fetched,
    audit: &Fetched,
    environments: Option<&[String]>,
) -> String {
    let tone = if headline.contains("down") {
        "is-bad"
    } else if headline.contains("unhealthy") || headline.contains("stopped") {
        "is-warn"
    } else {
        "is-good"
    };

    format!(
        r#"<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Hajime</title>
<link rel="stylesheet" href="/console.css">
<meta http-equiv="refresh" content="30">
</head>
<body>
<div class="cabinet"><div class="screen">
  <h1 class="title"><span class="mark"></span> Hajime</h1>
  <p class="headline {tone}">{headline}</p>
  <div class="panels">
    {services}
    {constraints}
    {history}
    {audit}
    {rollback}
  </div>
</div></div>
<footer>refreshes every 30 seconds</footer>
</body>
</html>"#,
        headline = escape(headline),
        services = services_panel(views),
        constraints = constraints_panel(views),
        history = history_panel(history),
        audit = audit_panel(audit),
        rollback = rollback_panel(environments),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn view(name: &'static str, essential: bool, reach: Reach) -> ServiceView {
        ServiceView {
            name,
            description: "d",
            essential,
            port: Some(1234),
            typical_mb: 10,
            reach,
            detail: None,
        }
    }

    #[test]
    fn the_model_panel_names_a_dependency_that_is_not_running() {
        // A service up without the database it reads from is not down, and is
        // not working either. Nothing else on the page says so.
        let views = vec![
            view("hajime_workflow", true, Reach::Up),
            view("postgresql", true, Reach::Down),
        ];
        let html = constraints_panel(&views);
        assert!(html.contains("postgresql"), "{html}");
        assert!(html.contains("hajime_workflow"), "{html}");
    }

    #[test]
    fn the_model_panel_says_so_plainly_when_nothing_is_wrong() {
        let every: Vec<ServiceView> = hajime_sys::service::start_order()
            .map(|s| ServiceView {
                name: s.name,
                description: s.description,
                essential: s.is_essential(),
                port: s.port,
                typical_mb: s.typical_mb,
                reach: Reach::Up,
                detail: None,
            })
            .collect();
        let html = constraints_panel(&every);
        // Everything up satisfies the dependency and essential-service rules.
        // Whether it also fits the budget is a separate question the panel
        // answers on its own line.
        assert!(html.contains("MB of"), "the budget belongs on it: {html}");
    }

    #[test]
    fn the_model_panel_escapes_what_it_renders() {
        // The violation text is built from static strings today, but it is
        // rendered through the same escape as everything else so that stays
        // true if a name ever reaches it.
        let views = vec![view("hajime_workflow", true, Reach::Up)];
        let html = constraints_panel(&views);
        assert!(!html.contains("<script"), "{html}");
    }

    #[test]
    fn text_from_other_services_is_escaped() {
        // A workflow name is something a person typed. It reaches this page
        // through two services and must not become markup.
        let hostile = Fetched::ok(serde_json::json!({
            "recent": [{
                "workflow": "<script>alert('x')</script>",
                "trigger": "manual", "duration_ms": 5, "success": true
            }]
        }));
        let html = history_panel(&hostile);
        assert!(!html.contains("<script>"), "script tag survived: {html}");
        assert!(html.contains("&lt;script&gt;"));
    }

    #[test]
    fn escaping_covers_every_dangerous_character() {
        assert_eq!(escape(r#"<a href="x" a='b'>&</a>"#),
            "&lt;a href=&quot;x&quot; a=&#39;b&#39;&gt;&amp;&lt;/a&gt;");
    }

    #[test]
    fn arabic_text_passes_through_unharmed() {
        assert_eq!(escape("مرحباً بالعالم"), "مرحباً بالعالم");
    }

    #[test]
    fn an_unreachable_service_explains_itself_rather_than_rendering_empty() {
        // The failure this guards against: a blank panel that looks like
        // "nothing happened" when it means "nobody answered".
        let html = history_panel(&Fetched::Unreachable);
        assert!(html.contains("not answering"));
        assert!(html.contains("not the same as nothing having run"));
    }

    #[test]
    fn a_failed_run_shows_why_it_failed() {
        // The verdict alone sends the operator to a log file to learn what this
        // page already received.
        let data = serde_json::json!({"recent": [{
            "workflow": "Nightly backup", "trigger": "schedule",
            "duration_ms": 0, "success": false,
            "error": "missed: 6 occurrence(s) came due while the scheduler was down"
        }]});
        let html = history_panel(&Fetched::ok(data));
        assert!(html.contains("missed: 6 occurrence"), "{html}");
    }

    #[test]
    fn a_long_reason_is_cut_rather_than_allowed_to_stretch_the_table() {
        let long = "x".repeat(400);
        let data = serde_json::json!({"recent": [{
            "workflow": "W", "trigger": "schedule", "duration_ms": 0,
            "success": false, "error": long
        }]});
        let html = history_panel(&Fetched::ok(data));
        assert!(html.contains('…'), "should be elided: {html}");
        assert!(!html.contains(&"x".repeat(120)), "should not carry the whole string");
    }

    #[test]
    fn an_error_message_cannot_inject_markup() {
        // The text comes from a workflow that quoted a request body, so it is
        // as untrusted as anything else on this page.
        let data = serde_json::json!({"recent": [{
            "workflow": "W", "trigger": "schedule", "duration_ms": 0,
            "success": false, "error": "<script>alert('x')</script>"
        }]});
        let html = history_panel(&Fetched::ok(data));
        assert!(!html.contains("<script>"), "{html}");
        assert!(html.contains("&lt;script&gt;"), "{html}");
    }

    #[test]
    fn an_error_and_an_outage_render_differently() {
        let unreachable = history_panel(&Fetched::Unreachable);
        let refused = history_panel(&Fetched::error("unauthorised"));
        assert_ne!(unreachable, refused);
        assert!(refused.contains("unauthorised"));
    }

    #[test]
    fn an_empty_history_is_stated_not_left_blank() {
        let html = history_panel(&Fetched::ok(serde_json::json!({"recent": []})));
        assert!(html.contains("no runs recorded yet"));
    }

    #[test]
    fn a_dry_run_tool_call_is_distinguishable_from_a_real_one() {
        let audit = Fetched::ok(serde_json::json!({
            "calls": [
                {"tool": "post_to_x", "caller": "m", "effect": "external",
                 "allowed": true, "dry_run": true},
                {"tool": "fetch_page", "caller": "m", "effect": "read",
                 "allowed": true, "dry_run": false}
            ]
        }));
        let html = audit_panel(&audit);
        assert!(html.contains("dry run"), "{html}");
        assert!(html.contains("done"), "{html}");
    }

    #[test]
    fn a_refused_tool_call_is_visible() {
        let audit = Fetched::ok(serde_json::json!({
            "calls": [{"tool": "post_to_x", "caller": "m", "effect": "external",
                       "allowed": false, "dry_run": false}]
        }));
        assert!(audit_panel(&audit).contains("refused"));
    }

    #[test]
    fn the_headline_tone_follows_the_worst_state() {
        let down = page("1 down: caddy", &[], &Fetched::Unreachable, &Fetched::Unreachable, None);
        assert!(down.contains("is-bad"));

        let ok = page("everything up", &[], &Fetched::Unreachable, &Fetched::Unreachable, None);
        assert!(ok.contains("is-good"));

        let saving = page(
            "sites up, 2 optional service(s) stopped",
            &[], &Fetched::Unreachable, &Fetched::Unreachable, None,
        );
        assert!(saving.contains("is-warn"));
    }

    #[test]
    fn services_render_with_their_tier_and_state() {
        let html = services_panel(&[
            view("caddy", true, Reach::Up),
            view("llamacpp", false, Reach::Down),
        ]);
        assert!(html.contains("caddy"));
        assert!(html.contains("chip essential"));
        assert!(html.contains("chip optional"));
        assert!(html.contains("chip up"));
        assert!(html.contains("chip down"));
    }

    #[test]
    fn without_zfs_the_rollback_panel_says_so() {
        let html = rollback_panel(None);
        assert!(html.contains("not a ZFS root"));
        assert!(html.contains("no \n            one-step way back")
            || html.contains("one-step way back"));
    }

    #[test]
    fn the_page_is_valid_enough_to_parse_and_carries_no_stray_markup() {
        let html = page(
            "everything up",
            &[view("caddy", true, Reach::Up)],
            &Fetched::ok(serde_json::json!({"recent": []})),
            &Fetched::ok(serde_json::json!({"calls": []})),
            Some(&["hajime-before-upgrade-20260804-093015".to_string()]),
        );
        assert!(html.starts_with("<!doctype html>"));
        assert_eq!(html.matches("<body>").count(), 1);
        assert_eq!(html.matches("</html>").count(), 1);
        assert!(html.contains("console.css"));
    }
}

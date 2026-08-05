//! The services Hajime knows about.
//!
//! One table, so that `hajimectl` and the boot self-check agree on what exists
//! rather than each keeping its own list and drifting apart.
//!
//! Every entry describes a service well enough to start it, check it and
//! decide whether it may be stopped when memory runs short.

use serde::{Deserialize, Serialize};

/// How badly the system needs a service.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Tier {
    /// The sites go down without it. Never stopped automatically.
    Essential,
    /// Useful, but the sites survive without it. Stopped first under pressure.
    Optional,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Service {
    /// The `rc.d` script name, which is also how it is addressed on the CLI.
    pub name: &'static str,
    pub description: &'static str,
    pub tier: Tier,
    /// Where it listens, when it listens at all.
    pub port: Option<u16>,
    /// A path that answers with 200 when the service is healthy.
    pub health_path: Option<&'static str>,
    /// Roughly what it occupies. Used to answer "will stopping this help?"
    /// before stopping it, rather than after.
    pub typical_mb: u32,
}

impl Service {
    pub fn health_url(&self) -> Option<String> {
        match (self.port, self.health_path) {
            (Some(p), Some(path)) => Some(format!("http://127.0.0.1:{p}{path}")),
            _ => None,
        }
    }

    pub fn is_essential(&self) -> bool {
        self.tier == Tier::Essential
    }
}

/// Everything Hajime manages.
///
/// Ordered by start order: a service may depend on those above it. The order
/// is reversed when stopping.
pub const SERVICES: &[Service] = &[
    Service {
        name: "postgresql",
        description: "PostgreSQL, the database behind the workflow store",
        tier: Tier::Essential,
        port: Some(5432),
        health_path: None,
        typical_mb: 500,
    },
    Service {
        name: "mysql",
        description: "MariaDB, the shop database",
        tier: Tier::Essential,
        port: Some(3306),
        health_path: None,
        typical_mb: 400,
    },
    Service {
        name: "redis",
        description: "Redis, cache and queues",
        tier: Tier::Essential,
        port: Some(6379),
        health_path: None,
        typical_mb: 100,
    },
    Service {
        name: "caddy",
        description: "Caddy, reverse proxy and TLS",
        tier: Tier::Essential,
        port: Some(80),
        health_path: None,
        typical_mb: 50,
    },
    Service {
        name: "cloudflared",
        description: "Cloudflare tunnel: the only path in from outside",
        tier: Tier::Essential,
        port: None,
        health_path: None,
        typical_mb: 50,
    },
    Service {
        name: "hajime_workflow",
        description: "Workflow engine: schedules and webhooks",
        tier: Tier::Essential,
        port: Some(5678),
        health_path: Some("/health"),
        typical_mb: 25,
    },
    Service {
        name: "hajime_wa",
        description: "WhatsApp gateway",
        tier: Tier::Optional,
        port: Some(3000),
        health_path: Some("/health"),
        typical_mb: 20,
    },
    Service {
        name: "hajime_wa_bridge",
        description: "WhatsApp protocol bridge, holds the device session",
        tier: Tier::Optional,
        port: Some(3001),
        health_path: Some("/health"),
        typical_mb: 30,
    },
    Service {
        name: "hajime_ai",
        description: "Model gateway and tool gateway",
        tier: Tier::Optional,
        port: Some(11434),
        health_path: Some("/health"),
        typical_mb: 30,
    },
    Service {
        name: "llamacpp",
        description: "Inference engine. By far the largest single consumer",
        tier: Tier::Optional,
        port: Some(11435),
        health_path: Some("/health"),
        typical_mb: 2200,
    },
];

pub fn find(name: &str) -> Option<&'static Service> {
    SERVICES.iter().find(|s| s.name == name)
}

/// Services in the order they should start.
pub fn start_order() -> impl Iterator<Item = &'static Service> {
    SERVICES.iter()
}

/// Services in the order they should stop: the reverse, so dependants go first.
pub fn stop_order() -> impl Iterator<Item = &'static Service> {
    SERVICES.iter().rev()
}

/// What a saving mode would stop, and how much it would free.
pub fn optional() -> Vec<&'static Service> {
    SERVICES.iter().filter(|s| !s.is_essential()).collect()
}

pub fn reclaimable_mb() -> u32 {
    optional().iter().map(|s| s.typical_mb).sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_service_has_a_unique_name() {
        let mut names: Vec<&str> = SERVICES.iter().map(|s| s.name).collect();
        let before = names.len();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), before, "duplicate service name in the table");
    }

    #[test]
    fn the_sites_depend_only_on_essential_services() {
        // If the tunnel, the proxy or a database were optional, saving mode
        // would take the sites down while trying to protect them.
        for name in ["cloudflared", "caddy", "postgresql", "mysql", "hajime_workflow"] {
            let s = find(name).unwrap_or_else(|| panic!("{name} missing from the table"));
            assert!(s.is_essential(), "{name} must be essential");
        }
    }

    #[test]
    fn the_inference_engine_is_optional_and_is_the_big_one() {
        let llama = find("llamacpp").unwrap();
        assert!(!llama.is_essential());
        // It should dominate what saving mode can reclaim; if it ever stops
        // being the largest, the mode's value proposition has changed.
        let biggest = optional().iter().map(|s| s.typical_mb).max().unwrap();
        assert_eq!(llama.typical_mb, biggest);
    }

    #[test]
    fn saving_mode_frees_a_meaningful_amount() {
        // On a 8 GB host this is the difference between swapping and not.
        assert!(reclaimable_mb() >= 2000, "got {} MB", reclaimable_mb());
    }

    #[test]
    fn stop_order_is_the_reverse_of_start_order() {
        let starts: Vec<&str> = start_order().map(|s| s.name).collect();
        let mut stops: Vec<&str> = stop_order().map(|s| s.name).collect();
        stops.reverse();
        assert_eq!(starts, stops);
    }

    #[test]
    fn databases_start_before_the_things_that_use_them() {
        let order: Vec<&str> = start_order().map(|s| s.name).collect();
        let pos = |n: &str| order.iter().position(|x| *x == n).unwrap();
        assert!(pos("postgresql") < pos("hajime_workflow"));
        assert!(pos("hajime_wa_bridge") > pos("hajime_wa") - 1);
        assert!(pos("llamacpp") > pos("hajime_ai") - 1);
    }

    #[test]
    fn a_health_url_needs_both_a_port_and_a_path() {
        assert_eq!(
            find("hajime_workflow").unwrap().health_url().as_deref(),
            Some("http://127.0.0.1:5678/health")
        );
        // cloudflared has no port and no path, so it has no URL to poll.
        assert!(find("cloudflared").unwrap().health_url().is_none());
        // Databases have a port but speak their own protocol, not HTTP.
        assert!(find("postgresql").unwrap().health_url().is_none());
    }

    #[test]
    fn an_unknown_service_is_not_invented() {
        assert!(find("nonexistent").is_none());
    }
}

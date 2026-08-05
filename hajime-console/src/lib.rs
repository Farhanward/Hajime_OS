//! The system console.
//!
//! One page that answers: what is broken, what ran, what the model did, and
//! what you can roll back to. It owns no data; it asks the services and
//! assembles their answers.
//!
//! Rendered on the server. A dashboard that needs JavaScript to tell you the
//! system is down is a dashboard that tells you nothing when it matters.

pub mod collect;
pub mod render;

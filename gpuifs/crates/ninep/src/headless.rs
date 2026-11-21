//! A `Tree` on its own thread behind `FsBackend`, with a fake frame clock and
//! `/debug/inject` for driving user events.
#![allow(unused_variables, dead_code)]

use std::sync::Arc;

use crate::FsBackend;

pub struct HeadlessBackend {}

impl HeadlessBackend {
    pub fn new(reg: tree::Registry) -> Arc<Self> {
        todo!("W3")
    }
}

#[async_trait::async_trait]
impl FsBackend for HeadlessBackend {
    fn snapshot(&self) -> Arc<tree::Snapshot> {
        todo!("W3")
    }
    async fn apply(&self, s: tree::SessionId, op: tree::Op) -> Result<(), proto::Error> {
        todo!("W3")
    }
    fn subscribe(&self, events_file: &tree::FsPath) -> Result<tree::Subscription, proto::Error> {
        todo!("W3")
    }
    fn new_session(&self) -> tree::SessionId {
        todo!("W3")
    }
}

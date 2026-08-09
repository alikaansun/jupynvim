//! Matplotlib interactive bridge RPC.
//!
//! Drives mouse-controlled pan / box-zoom / reset on an inline matplotlib
//! figure without the Jupyter comm/widget machinery. Each interaction calls
//! `_jupynvim_mpl.dispatch_b64(...)` on the kernel (the Python helper installed
//! by the Lua frontend), which mutates the target axes and returns the Figure
//! so the inline backend renders a fresh PNG. That PNG is captured here — via a
//! one-shot collector keyed by the run's msg_id — and returned to the frontend,
//! which repaints the existing Kitty image in place.
//!
//! The run uses `store_history=false` and its msg_id is deliberately NOT
//! registered in `session.msg_to_cell`, so `Session::apply_event` never appends
//! the PNG to the cell's outputs. See `core/src/rpc/exec.rs` (`start_kernel`
//! event pump) for the interception that fulfills the collector.

use anyhow::{anyhow, Result};
use base64::Engine;
use serde_json::{json, Value as Json};
use std::sync::Arc;
use std::time::Duration;

use super::Server;
use crate::kernel::KernelEvent;

/// The parent_msg_id an event is a reply to (the originating request's msg_id).
pub(crate) fn event_parent(ev: &KernelEvent) -> Option<&str> {
    match ev {
        KernelEvent::Stream { parent_msg_id, .. }
        | KernelEvent::DisplayData { parent_msg_id, .. }
        | KernelEvent::ExecuteResult { parent_msg_id, .. }
        | KernelEvent::Error { parent_msg_id, .. }
        | KernelEvent::Status { parent_msg_id, .. }
        | KernelEvent::ExecuteInput { parent_msg_id, .. }
        | KernelEvent::ExecuteReply { parent_msg_id, .. }
        | KernelEvent::UpdateDisplayData { parent_msg_id, .. }
        | KernelEvent::ClearOutput { parent_msg_id, .. }
        | KernelEvent::KernelInfo { parent_msg_id, .. } => parent_msg_id.as_deref(),
    }
}

/// The base64 `image/png` in an event's MIME bundle (execute_result /
/// display_data / update_display_data), if any.
pub(crate) fn event_png(ev: &KernelEvent) -> Option<String> {
    let data = match ev {
        KernelEvent::ExecuteResult { data, .. }
        | KernelEvent::DisplayData { data, .. }
        | KernelEvent::UpdateDisplayData { data, .. } => data,
        _ => return None,
    };
    data.get("image/png").and_then(|v| match v {
        Json::String(s) => Some(s.clone()),
        // Some kernels split base64 into an array of lines.
        Json::Array(a) => Some(a.iter().filter_map(|x| x.as_str()).collect::<Vec<_>>().concat()),
        _ => None,
    })
}

/// True once the kernel returned to idle for this request — no more output
/// will arrive for its msg_id.
pub(crate) fn event_is_idle(ev: &KernelEvent) -> bool {
    matches!(ev, KernelEvent::Status { execution_state, .. } if execution_state == "idle")
}

impl Server {
    /// `op` is one of "begin" | "pan" | "box_zoom" | "reset" | "end". `args`
    /// is an op-specific object (fractional figure coordinates in [0,1], y
    /// measured top-down). Returns `{ png_b64 }` with the re-rendered figure,
    /// or an error if the op produced no image (e.g. no active figure).
    pub(super) async fn mpl_op(self: Arc<Self>, p: Json) -> Result<Json> {
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id required"))?;
        let cell_id = p
            .get("cell_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("cell_id required"))?;
        let op = p
            .get("op")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("op required"))?;
        if !matches!(op, "begin" | "pan" | "box_zoom" | "reset" | "end") {
            return Err(anyhow!("unknown mpl op '{op}'"));
        }
        let args = p.get("args").cloned().unwrap_or_else(|| json!({}));

        let session = self
            .sessions
            .get(sid)
            .ok_or_else(|| anyhow!("no session"))?
            .clone();

        // base64 the payload so it drops safely into a Python single-quoted
        // string literal (base64 alphabet has no quotes/backslashes/newlines).
        let payload = json!({ "cell_id": cell_id, "op": op, "args": args });
        let payload_b64 = base64::engine::general_purpose::STANDARD.encode(payload.to_string());
        let code = format!("_jupynvim_mpl.dispatch_b64('{payload_b64}')");

        let msg_id = uuid::Uuid::new_v4().to_string();
        let (tx, rx) = tokio::sync::oneshot::channel::<Option<String>>();
        self.mpl_collectors.insert(msg_id.clone(), tx);

        {
            let guard = session.kernel.read().await;
            let kernel = guard.as_ref().ok_or_else(|| anyhow!("kernel not started"))?;
            // silent=false so the figure renders on iopub; store_history=false
            // keeps it out of Out[N]. msg_id intentionally NOT in msg_to_cell.
            if let Err(e) = kernel
                .execute_with_id_opts(&code, msg_id.clone(), false, false)
                .await
            {
                self.mpl_collectors.remove(&msg_id);
                return Err(e);
            }
        }

        match tokio::time::timeout(Duration::from_secs(5), rx).await {
            Ok(Ok(Some(png))) => Ok(json!({ "png_b64": png })),
            Ok(Ok(None)) => {
                // Run finished (idle) without an image — no active/target figure.
                Err(anyhow!("mpl op '{op}' produced no figure"))
            }
            Ok(Err(_)) => {
                self.mpl_collectors.remove(&msg_id);
                Err(anyhow!("mpl op '{op}' collector dropped"))
            }
            Err(_) => {
                self.mpl_collectors.remove(&msg_id);
                Err(anyhow!("mpl op '{op}' timed out"))
            }
        }
    }
}

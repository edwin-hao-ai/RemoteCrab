// Emit the exact bytes the Windows receiver would put on the wire for 0x22/0x23,
// so the Swift side can be asked to decode them.
fn main() {
    let n = rc_protocol::Notification {
        app: "Slack".into(),
        title: "Build finished".into(),
        subtitle: "#42".into(),
        body: "12 tests passed".into(),
        window_title: Some("CI".into()),
    };
    let r = rc_protocol::CommandResult {
        request_id: "a1".into(),
        status: rc_protocol::CommandStatus::AppNotRunning,
        detail: Some("目标应用没有运行".into()),
    };
    println!("{}", serde_json::to_string(&n).unwrap());
    println!("{}", serde_json::to_string(&r).unwrap());
    let nn = rc_protocol::Notification { window_title: None, ..Default::default() };
    println!("{}", serde_json::to_string(&nn).unwrap());
}

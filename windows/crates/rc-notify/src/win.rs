//! The Windows half: actually reading notifications, and turning each one into
//! a `0x22` frame.
//!
//! Split from [`crate::notify`] on purpose. That module decides *whether* to
//! relay and is testable on any host; this one can only run on Windows, so
//! keeping them apart means a bug in the decision logic is caught by CI rather
//! than by a user noticing a notification that never arrived.
//!
//! **Why polling.** The obvious implementation is the push API — subscribe to
//! `NotificationPosted`. The `windows` crate 0.62 does not project that event,
//! so the choice was a push API through raw COM, or polling
//! `GetNotificationsAsync()`. Polling won, for three reasons: it is the same
//! shape as the Mac half (which polls the accessibility tree because macOS has
//! no notification API at all), it needs no apartment/threading decisions, and
//! the notification list is the only projection that carries the banner *text*.
//!
//! The cost of polling is that the API hands back **every** notification it is
//! holding, not just new ones, so a naive loop re-sends everything on every
//! tick. [`SeenSet`] is what makes that correct.

use rc_net::notify::{Captured, Notification, Relay};

use std::collections::VecDeque;

/// A live listener, or the reason there is not one.
pub enum Listener {
    Ready(UserNotificationListener),
    /// The user has not granted notification access in Windows Settings. There
    /// is a pane for it, and naming it is the entire recovery.
    NotPermitted,
    Unsupported(String),
}

impl Listener {
    pub fn is_ready(&self) -> bool {
        matches!(self, Listener::Ready(_))
    }
}

/// Create the listener, having first established that we may read
/// notifications at all.
///
/// Creating the listener and being allowed to read are **different** things.
/// Conflating them is how this feature ends up reporting "no notifications"
/// when the truth is "you have never been asked" — the single most confusing
/// failure it has, because both look like a working system with nothing to say.
pub fn start() -> Listener {
    let Ok(listener) = UserNotificationListener::Current() else {
        return Listener::Unsupported("UserNotificationListener::current failed".into());
    };
    match listener.RequestAccessAsync().and_then(|op| op.join()) {
        Ok(UserNotificationListenerAccessStatus::Allowed) => Listener::Ready(listener),
        Ok(_) => Listener::NotPermitted,
        Err(e) => Listener::Unsupported(format!("RequestAccessAsync: {e}")),
    }
}

/// Read the current notification list and hand each *new* one to `on_banner`.
///
/// Returns the number relayed, so a caller can log a heartbeat that says
/// "listening, 3 new" rather than nothing at all — a relay that is silently
/// idle and a relay that is broken look identical from the outside.
pub fn poll_once(
    listener: &UserNotificationListener,
    seen: &mut SeenSet,
    relay: &Relay,
    on_banner: &mut dyn FnMut(Notification),
) -> usize {
    let all = match listener
        .GetNotificationsAsync(NotificationKinds::Toast)
        .and_then(|op| op.join())
    {
        Ok(v) => v,
        Err(e) => {
            eprintln!("  notify: GetNotificationsAsync failed: {e}");
            return 0;
        }
    };

    let mut relayed = 0usize;
    for n in all.into_iter() {
        // `Id()` is fallible in this projection, so a notification whose id
        // cannot be read cannot be de-duplicated. Treating that as "not new"
        // would silently drop it, so it gets a key derived from what *is*
        // readable — a possible duplicate beats a possible loss.
        let id = match n.Id() {
            Ok(v) => v.to_string(),
            Err(_) => match n.CreationTime() {
                Ok(t) => format!("anon-{t:?}"),
                Err(_) => "anon-unknown".to_string(),
            },
        };
        if !seen.add(&id) {
            // Already relayed on an earlier tick. The API returns a snapshot of
            // everything Windows is holding, not a delta, so skipping these is
            // what stops every banner being re-sent every few seconds.
            continue;
        }

        // The display name is what the denylist matches on, so an unreadable
        // one leaves an empty `app` — which `Relay::decide` treats as *denied*.
        // Failing closed here is the whole privacy story; do not "improve" it
        // into a best-effort guess.
        let app = n
            .AppInfo()
            .and_then(|a| a.DisplayInfo())
            .and_then(|d| d.DisplayName())
            .map(|d| d.to_string())
            .unwrap_or_default();
        let (title, subtitle, body) = texts(&n);
        let captured = Captured {
            app,
            title,
            subtitle,
            body,
        };
        if let Ok(n) = rc_net::notify::admit(relay, captured) {
            relayed += 1;
            on_banner(n);
        }
    }
    relayed
}

/// Pull the human-readable strings out of a notification.
///
/// The text is not a field: it is a list of `(key, value)` elements on the
/// *first* binding of the visual, and which key means what varies by template
/// (`ToastGeneric` uses "text", a badge uses "text", some apps put the app's
/// own name in "attribution"). So this collects every element it can find and
/// lets the relay's own emptiness rule decide whether there was anything worth
/// sending — rather than guessing a key and dropping the notifications that used
/// a different one.
///
/// Public because it is the part most likely to need adjusting on a real
/// machine, and having it callable from a test is cheaper than a rebuild.
fn texts(n: &UserNotification) -> (String, String, String) {
    let Ok(visual) = n.Notification().and_then(|i| i.Visual()) else {
        return (String::new(), String::new(), String::new());
    };
    // `Bindings()` is a vector of bindings and the first is the one Windows
    // shows. `IVector::First()` yields an *iterator*, so the element is reached
    // through `GetMany` — reading it as a binding directly is the obvious
    // mistake and it type-checks as something else entirely.
    let binding = visual
        .Bindings()
        .ok()
        .and_then(|b| b.First().ok())
        .and_then(|it| {
            let mut out: [Option<NotificationBinding>; 1] = [None];
            it.GetMany(&mut out).ok().map(|_| out[0].take())
        })
        .flatten();
    let Some(binding) = binding else {
        return (String::new(), String::new(), String::new());
    };
    let Ok(elements) = binding.GetTextElements() else {
        return (String::new(), String::new(), String::new());
    };
    let mut out: Vec<String> = Vec::new();
    for e in elements.into_iter() {
        // Each element is `{ key, language, text }`. Only `text` is the line
        // the user reads; the key is a template slot name ("text", "attribution")
        // and is not part of the message.
        if let Ok(v) = e.Text() {
            let v = v.to_string();
            if !v.trim().is_empty() {
                out.push(v);
            }
        }
    }
    // Best effort by position: the first element is what the user reads, the
    // second is the supporting line. Anything beyond that is joined, because
    // dropping it loses information the phone could have shown.
    let title = out.first().cloned().unwrap_or_default();
    let subtitle = out.get(1).cloned().unwrap_or_default();
    let body = if out.len() > 2 {
        out[2..].join("\n")
    } else {
        String::new()
    };
    (title, subtitle, body)
}

/// Ids already relayed, oldest first, bounded.
///
/// Bounded because this runs for the life of the process and Windows keeps a
/// notification in its list long after it has been read; an unbounded set is a
/// slow leak in a program that is meant to run all day in the tray.
#[derive(Debug)]
pub struct SeenSet {
    order: VecDeque<String>,
    seen: std::collections::HashSet<String>,
    capacity: usize,
}

impl SeenSet {
    pub fn new(capacity: usize) -> Self {
        SeenSet {
            order: VecDeque::new(),
            seen: std::collections::HashSet::new(),
            capacity: capacity.max(1),
        }
    }

    /// Record an id; `false` means it was already there.
    pub fn add(&mut self, id: &str) -> bool {
        if !self.seen.insert(id.to_string()) {
            return false;
        }
        self.order.push_back(id.to_string());
        while self.order.len() > self.capacity {
            if let Some(old) = self.order.pop_front() {
                self.seen.remove(&old);
            }
        }
        true
    }

    pub fn len(&self) -> usize {
        self.order.len()
    }

    pub fn is_empty(&self) -> bool {
        self.order.is_empty()
    }
}

impl Default for SeenSet {
    fn default() -> Self {
        Self::new(512)
    }
}

// The blocking `.join()` on `IAsyncOperation` is called inline at the two use
// sites rather than through a helper: `windows_future::Async` is sealed, so it
// cannot be named as a generic bound. Both operations are concrete, so the
// calls type-check without one.
use windows::UI::Notifications::Management::{
    UserNotificationListener, UserNotificationListenerAccessStatus,
};
// `UserNotification` and its `Notification` payload live in the parent
// namespace, not in `Management` — the listener only adds the access check and
// the query methods.
use windows::UI::Notifications::NotificationKinds;
use windows::UI::Notifications::{NotificationBinding, UserNotification};

#[cfg(test)]
mod tests {
    use super::SeenSet;

    /// The whole reason this type exists: the API returns a snapshot, not a
    /// delta, so re-sending is the default failure mode.
    #[test]
    fn an_id_is_only_new_once() {
        let mut s = SeenSet::new(8);
        assert!(s.add("a"));
        assert!(!s.add("a"));
        assert!(s.add("b"));
    }

    /// All day in the tray means a long-lived process, and Windows holds on to
    /// notifications long after they are read.
    #[test]
    fn the_set_is_bounded_and_forgets_the_oldest() {
        let mut s = SeenSet::new(3);
        for id in ["a", "b", "c", "d", "e"] {
            s.add(id);
        }
        assert_eq!(s.len(), 3);
        // The oldest is gone, so it counts as new again. Re-sending an ancient
        // banner is the lesser evil against growing without bound.
        assert!(s.add("a"));
        assert_eq!(s.len(), 3);
    }

    #[test]
    fn a_zero_capacity_still_works() {
        // A zero would otherwise evict the entry it just added and turn every
        // call into `true`, i.e. re-send everything, forever.
        let mut s = SeenSet::new(0);
        assert!(s.add("a"));
        assert!(!s.add("a"));
    }
}

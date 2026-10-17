//! One facts file (`src/fork/FACTS.md`) in, one `Session` out. No IO here.
//!
//! The daemon records; this file decides what the records mean. It can be that way round because
//! a bridge lives only as long as one connection, so new opinions arrive with the next reconnect,
//! while a daemon keeps the code it started with until its session ends.

use crate::text::{clean, decode};
use serde::Serialize;

pub const MAX_RECORDS: usize = 64;

/// When a fact last changed. `seq` orders changes within one daemon's life; `at` is wall-clock
/// milliseconds on the daemon's host, for display.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Stamp {
    pub seq: u64,
    pub at: i64,
}

/// Declared mildest first, so `Ord` is "needs you more".
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Idle,
    Done,
    Working,
    Error,
    Blocked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Permission,
    Question,
    Auth,
}

/// Which protocol a `Status` came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    /// OSC 7501: the program said exactly this.
    Status,
    /// OSC 9;4: inferred from a progress bar appearing and going away.
    Progress,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Status {
    /// Empty for the root record, the program itself.
    pub id: String,
    pub state: State,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<Kind>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub progress: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub msg: Option<String>,
    pub source: Source,
    #[serde(flatten)]
    pub stamp: Stamp,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Fact<T> {
    #[serde(flatten)]
    pub value: T,
    #[serde(flatten)]
    pub stamp: Stamp,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Bell {
    pub count: u64,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Mark {
    pub step: String,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Exit {
    pub code: i32,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Text {
    pub text: String,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Notify {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub body: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Session {
    pub name: String,
    pub pid: i32,
    /// `(born, seq)` orders changes across a restart under the same name.
    pub born: u64,
    pub seq: u64,
    /// The one status to show for the whole session, if any. See `headline`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub now: Option<Status>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub status: Vec<Status>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bell: Option<Fact<Bell>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mark: Option<Fact<Mark>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit: Option<Fact<Exit>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<Fact<Text>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pwd: Option<Fact<Text>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notify: Option<Fact<Notify>>,
}

/// `None` for anything that is not a version 1 facts file. Within one, a line that does not
/// parse is skipped: unknown kinds are how a newer daemon talks to an older bridge.
pub fn parse(name: &str, bytes: &[u8]) -> Option<Session> {
    let mut lines = bytes.split(|&b| b == b'\n').filter_map(|l| std::str::from_utf8(l).ok());

    let (mut version, mut pid, mut born, mut seq) = (None, None, None, None);
    for pair in lines.next()?.split(' ') {
        match pair.split_once('=')? {
            ("v", v) => version = v.parse::<u32>().ok(),
            ("pid", v) => pid = v.parse().ok(),
            ("born", v) => born = v.parse().ok(),
            ("seq", v) => seq = v.parse().ok(),
            _ => {}
        }
    }
    if version? != 1 {
        return None;
    }
    let mut s = Session {
        name: name.to_owned(),
        pid: pid?,
        born: born?,
        seq: seq?,
        now: None,
        status: Vec::new(),
        bell: None,
        mark: None,
        exit: None,
        title: None,
        pwd: None,
        notify: None,
    };

    let mut progress = None;
    for line in lines {
        let mut cols = line.splitn(4, ' ');
        let (Some(kind), Some(seq), Some(at), Some(value)) = (cols.next(), cols.next(), cols.next(), cols.next())
        else {
            continue;
        };
        let (Ok(seq), Ok(at)) = (seq.parse(), at.parse()) else { continue };
        let stamp = Stamp { seq, at };
        match kind {
            "status" if s.status.len() < MAX_RECORDS => s.status.extend(status(value, stamp)),
            "progress" => progress = from_progress(value, stamp),
            "bell" => s.bell = value.parse().ok().map(|count| Fact { value: Bell { count }, stamp }),
            "mark" => s.mark = clean(value, 32).map(|step| Fact { value: Mark { step }, stamp }),
            "exit" => s.exit = value.parse().ok().map(|code| Fact { value: Exit { code }, stamp }),
            "title" => s.title = decode(value, 256).map(|text| Fact { value: Text { text }, stamp }),
            "pwd" => s.pwd = clean(value, 1024).map(|text| Fact { value: Text { text }, stamp }),
            "notify" => {
                s.notify = value.split_once(' ').and_then(|(title, body)| {
                    let value = Notify { title: decode(title, 128), body: decode(body, 512)? };
                    Some(Fact { value, stamp })
                });
            }
            _ => {}
        }
    }

    // `idle` means "here, at rest". Any shell mark after it means the shell has moved on, so the
    // program that said it is gone, however it went. The daemon keeps the record because the
    // protocol only tells it to end `working` and `blocked`.
    if let Some(mark) = &s.mark {
        s.status.retain(|r| r.state != State::Idle || r.stamp.seq > mark.stamp.seq);
    }
    s.now = headline(&s.status).cloned().or(progress);
    Some(s)
}

/// The record that most needs the user. Between equals the one nearest the root wins, since a
/// program's own line says more than one of its workers'; then the most recent.
fn headline(records: &[Status]) -> Option<&Status> {
    let depth = |r: &Status| if r.id.is_empty() { 0 } else { 1 + r.id.matches('/').count() };
    records.iter().max_by_key(|r| (r.state, std::cmp::Reverse(depth(r)), r.stamp.seq))
}

/// An OSC 7501 body: `key=value` pairs joined by colons; the last of a repeated key wins. The
/// daemon's parser has validated it, which is no reason to trust the file.
fn status(body: &str, stamp: Stamp) -> Option<Status> {
    let get = |key| body.split(':').filter_map(|p| p.split_once('=')).rfind(|p| p.0 == key);
    let value = |key| get(key).map(|p| p.1);
    let name = |s: &str, max| {
        let ok = |c: char| c.is_ascii_alphanumeric() || "_.+-/".contains(c);
        (!s.is_empty() && s.len() <= max && s.chars().all(ok)).then(|| s.to_owned())
    };

    let state = match value("state")? {
        "idle" => State::Idle,
        "working" => State::Working,
        "done" => State::Done,
        "blocked" => State::Blocked,
        "error" => State::Error,
        _ => return None,
    };
    let running = matches!(state, State::Working | State::Blocked);
    Some(Status {
        id: match value("id") {
            Some(id) => name(id, 128)?,
            None => String::new(),
        },
        state,
        kind: value("kind").filter(|_| state == State::Blocked).and_then(|k| match k {
            "permission" => Some(Kind::Permission),
            "question" => Some(Kind::Question),
            "auth" => Some(Kind::Auth),
            _ => None,
        }),
        progress: value("progress").filter(|_| running).and_then(percent),
        app: value("app").and_then(|a| name(a, 32)).filter(|a| !a.contains('/')),
        title: value("title").and_then(|t| decode(t, 192)),
        msg: value("msg").and_then(|m| decode(m, 2048)),
        source: Source::Status,
        stamp,
    })
}

fn percent(s: &str) -> Option<u8> {
    (s.len() <= 3 && s.bytes().all(|b| b.is_ascii_digit())).then(|| s.parse().ok())?.filter(|&n| n <= 100)
}

/// For a program that only draws a progress bar: a bar means working, a bar taken away means
/// it finished. Used only when the session has no OSC 7501 record at all.
fn from_progress(value: &str, stamp: Stamp) -> Option<Status> {
    let (word, n) = value.split_once(' ').map_or((value, None), |(w, n)| (w, percent(n)));
    let state = match word {
        "set" | "indeterminate" | "pause" => State::Working,
        "error" => State::Error,
        "remove" => State::Done,
        _ => return None,
    };
    Some(Status {
        id: String::new(),
        state,
        kind: None,
        progress: n.filter(|_| state == State::Working),
        app: None,
        title: None,
        msg: None,
        source: Source::Progress,
        stamp,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(body: &str) -> Session {
        parse("s", format!("v=1 pid=7 born=9 seq=99\n{body}").as_bytes()).unwrap()
    }

    #[test]
    fn a_real_capture() {
        let s = session(
            "progress 13 1792270706613 indeterminate\n\
             title 7 1792270695265 U2luZ2xlIHdvcmQgcmVwbHk=\n\
             notify 16 1792270715575 Q2xhdWRlIENvZGU= Q2xhdWRlIG5lZWRzIHlvdXIgcGVybWlzc2lvbg==\n\
             status 15 1792270709568 state=blocked:app=claude-code:kind=question:msg=YW5zd2VyOiBEbyB5b3UgcHJlZmVyIHJlZCBvciBibHVlPyAoUmVkIMK3IEJsdWUp\n",
        );
        assert_eq!((s.pid, s.born, s.seq), (7, 9, 99));
        let now = s.now.unwrap();
        assert_eq!((now.state, now.kind, now.source), (State::Blocked, Some(Kind::Question), Source::Status));
        assert_eq!(now.app.as_deref(), Some("claude-code"));
        assert_eq!(now.msg.as_deref(), Some("answer: Do you prefer red or blue? (Red · Blue)"));
        assert_eq!(now.stamp, Stamp { seq: 15, at: 1_792_270_709_568 });
        assert_eq!(s.title.unwrap().value.text, "Single word reply");
        let n = s.notify.unwrap().value;
        assert_eq!((n.title.as_deref(), n.body.as_str()), (Some("Claude Code"), "Claude needs your permission"));
    }

    #[test]
    fn not_a_facts_file() {
        for bad in ["", "hello", "v=2 pid=1 born=1 seq=1\n", "v=1 pid=x born=1 seq=1\n", "v=1 pid=1 seq=1\n"] {
            assert_eq!(parse("s", bad.as_bytes()), None, "{bad:?}");
        }
        assert_eq!(parse("s", b"\xff\xfe"), None);
    }

    #[test]
    fn unknown_things_are_skipped() {
        let s = parse(
            "s",
            b"v=1 pid=7 born=9 seq=3 later=yes\nfuture 1 2 x y z\nshort 1\nbell x 2 3\n\xff\xff 1 2 3\nbell 2 5 4\n",
        )
        .unwrap();
        assert_eq!(s.bell.unwrap(), Fact { value: Bell { count: 4 }, stamp: Stamp { seq: 2, at: 5 } });
        assert_eq!(s.now, None);
    }

    #[test]
    fn the_headline_is_whoever_needs_you_most() {
        let s = session(
            "status 1 0 state=working:msg=cm9vdA==\n\
             status 2 0 state=working:id=a\n\
             status 3 0 state=done:id=b\n",
        );
        assert_eq!(s.now.as_ref().unwrap().msg.as_deref(), Some("root"), "root beats a later child");
        let s = session(
            "status 1 0 state=working\nstatus 2 0 state=blocked:id=a/b:kind=auth\nstatus 3 0 state=error:id=c\n",
        );
        assert_eq!(s.now.unwrap().id, "a/b");
        let s = session("status 1 0 state=done:id=a\nstatus 2 0 state=done:id=b\n");
        assert_eq!(s.now.unwrap().id, "b", "latest between equals");
    }

    #[test]
    fn idle_does_not_outlive_its_program() {
        let s = session("mark 5 0 prompt_start\nstatus 3 0 state=idle:app=x\nstatus 4 0 state=done:id=d\n");
        assert_eq!(s.status.len(), 1);
        assert_eq!(s.now.unwrap().state, State::Done);
        let s = session("mark 2 0 output_start\nstatus 3 0 state=idle:app=x\n");
        assert_eq!(s.now.unwrap().state, State::Idle);
    }

    #[test]
    fn progress_speaks_only_when_status_is_silent() {
        let now = |b| session(b).now.map(|n| (n.state, n.progress, n.source));
        assert_eq!(now("progress 1 0 set 40\n"), Some((State::Working, Some(40), Source::Progress)));
        assert_eq!(now("progress 1 0 indeterminate\n"), Some((State::Working, None, Source::Progress)));
        assert_eq!(now("progress 1 0 remove\n"), Some((State::Done, None, Source::Progress)));
        assert_eq!(now("progress 1 0 error 40\n"), Some((State::Error, None, Source::Progress)));
        assert_eq!(now("progress 1 0 sideways\n"), None);
        assert_eq!(now("progress 9 0 set 40\nstatus 1 0 state=idle\n"), Some((State::Idle, None, Source::Status)));
    }

    #[test]
    fn fields_only_count_where_they_make_sense() {
        let one = |b: &str| session(&format!("status 1 0 {b}\n")).status.pop();
        let r = one("state=done:kind=auth:progress=5:app=a/b:title=!!!:msg=/w==").unwrap();
        assert_eq!((r.kind, r.progress, r.app, r.title, r.msg), (None, None, None, None, None));
        assert_eq!(one("state=working:progress=101").unwrap().progress, None);
        assert_eq!(one("state=working:progress=+5").unwrap().progress, None);
        assert_eq!(one("state=working:progress=100").unwrap().progress, Some(100));
        assert_eq!(one("state=idle:state=working").unwrap().state, State::Working, "last wins");
        assert_eq!(one("state=blocked:kind=mood").unwrap().kind, None);
        assert_eq!(one("state=sideways"), None);
        assert_eq!(one("app=x"), None);
        assert_eq!(one("state=done:id=a b"), None, "a bad id must not fall back to the root");
    }

    #[test]
    fn hostile_text_is_defused_and_bounded() {
        // "a" + RLO + "b" + ESC
        let r = session("status 1 0 state=error:msg=YeKArmIb\n").status.pop().unwrap();
        assert_eq!(r.msg.as_deref(), Some("ab"));
        let many: String = (0..200).map(|i| format!("status {i} 0 state=done:id=r{i}\n")).collect();
        assert_eq!(session(&many).status.len(), MAX_RECORDS);
    }

    #[test]
    fn the_wire_shape() {
        let s = session("bell 2 5 4\nexit 3 6 -1\nstatus 4 7 state=working:progress=40:id=a\n");
        assert_eq!(
            serde_json::to_string(&s).unwrap(),
            r#"{"name":"s","pid":7,"born":9,"seq":99,"#.to_owned()
                + r#""now":{"id":"a","state":"working","progress":40,"source":"status","seq":4,"at":7},"#
                + r#""status":[{"id":"a","state":"working","progress":40,"source":"status","seq":4,"at":7}],"#
                + r#""bell":{"count":4,"seq":2,"at":5},"exit":{"code":-1,"seq":3,"at":6}}"#
        );
    }
}

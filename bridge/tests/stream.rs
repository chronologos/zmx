//! The real program against a real directory. A "session" here is what the bridge takes one to
//! be: a facts file, a socket of the same name, and a live pid (this test's own).

use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::{PermissionsExt, symlink};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::mpsc::{Receiver, channel};
use std::time::{Duration, Instant};

struct Host {
    root: PathBuf,
    sockets: Vec<UnixListener>,
}

impl Host {
    /// Short path: a unix socket's is limited to about a hundred bytes.
    fn new(tag: &str) -> Host {
        let root = PathBuf::from(format!("/tmp/zb-{}-{tag}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("s")).unwrap();
        Host { root, sockets: Vec::new() }
    }
    fn dir(&self) -> PathBuf {
        self.root.join("s")
    }
    fn facts_root(&self) -> PathBuf {
        self.root.join("s.facts")
    }
    fn facts(&self, sub: &str) -> PathBuf {
        self.facts_root().join(sub)
    }
    /// What a daemon does on start.
    fn make_dirs(&self) {
        for d in [self.facts_root(), self.facts("now"), self.facts("tmp")] {
            fs::create_dir_all(&d).unwrap();
            fs::set_permissions(&d, fs::Permissions::from_mode(0o700)).unwrap();
        }
    }
    fn socket(&mut self, name: &str) {
        self.sockets.push(UnixListener::bind(self.dir().join(name)).unwrap());
    }
    /// What a daemon does on every change.
    fn publish(&self, name: &str, pid: u32, seq: u64, body: &str) {
        fs::write(self.facts("tmp").join(name), format!("v=1 pid={pid} born=9 seq={seq}\n{body}")).unwrap();
        fs::rename(self.facts("tmp").join(name), self.facts("now").join(name)).unwrap();
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

struct Bridge {
    child: Child,
    stdin: Option<ChildStdin>,
    lines: Receiver<Value>,
}

fn command(dir: &Path, extra: &[&str]) -> Command {
    let mut c = Command::new(env!("CARGO_BIN_EXE_zmx-bridge"));
    c.arg("--dir").arg(dir).args(extra);
    c
}

impl Bridge {
    fn start(dir: &Path, extra: &[&str]) -> Bridge {
        let mut child =
            command(dir, extra).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::inherit()).spawn().unwrap();
        let stdin = child.stdin.take();
        let stdout: ChildStdout = child.stdout.take().unwrap();
        let (tx, lines) = channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                if tx.send(serde_json::from_str(&line.unwrap()).unwrap()).is_err() {
                    break;
                }
            }
        });
        Bridge { child, stdin, lines }
    }
    fn next(&self) -> Value {
        self.lines.recv_timeout(Duration::from_secs(3)).expect("a line within 3 s")
    }
    fn quiet(&self, ms: u64) {
        if let Ok(v) = self.lines.recv_timeout(Duration::from_millis(ms)) {
            panic!("expected silence, got {v}");
        }
    }
    fn opening(&self) -> Vec<Value> {
        let hello = self.next();
        assert_eq!((&hello["t"], &hello["proto"]), (&json!("hello"), &json!(1)));
        let mut sets = Vec::new();
        loop {
            let v = self.next();
            if v["t"] == "ready" {
                return sets;
            }
            assert_eq!(v["t"], "set");
            sets.push(v["session"].clone());
        }
    }
}

impl Drop for Bridge {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn me() -> u32 {
    std::process::id()
}

#[test]
fn opening_state_then_changes_then_the_end() {
    let mut h = Host::new("flow");
    h.make_dirs();
    h.socket("a");
    h.socket("b");
    h.publish("a", me(), 1, "status 1 5 state=working:app=demo\n");
    h.publish("ghost", me(), 1, "status 1 5 state=working\n"); // no socket
    h.socket("dead");
    h.publish("dead", 0x3fff_fff0, 1, "status 1 5 state=working\n"); // no such process

    let b = Bridge::start(&h.dir(), &[]);
    let sets = b.opening();
    assert_eq!(sets.len(), 1, "{sets:?}");
    assert_eq!((&sets[0]["name"], &sets[0]["now"]["state"]), (&json!("a"), &json!("working")));

    let t = Instant::now();
    h.publish("a", me(), 2, "status 2 6 state=blocked:kind=permission:msg=aGk=\n");
    let v = b.next();
    assert!(t.elapsed() < Duration::from_millis(500), "pushed, not polled: {:?}", t.elapsed());
    assert_eq!(v["t"], "set");
    assert_eq!(
        v["session"]["now"],
        json!({"id":"","state":"blocked","kind":"permission","msg":"hi","source":"status","seq":2,"at":6})
    );

    h.publish("b", me(), 0, "");
    assert_eq!(b.next(), json!({"t":"set","session":{"name":"b","pid":me(),"born":9,"seq":0}}));

    // Same content, new file: nothing to say.
    h.publish("b", me(), 0, "");
    b.quiet(200);

    // The socket going is the session ending; no facts write is involved.
    h.sockets.remove(0);
    fs::remove_file(h.dir().join("a")).unwrap();
    assert_eq!(b.next(), json!({"t":"del","name":"a"}));
}

#[test]
fn a_burst_arrives_as_its_last_state() {
    let mut h = Host::new("burst");
    h.make_dirs();
    h.socket("a");
    let b = Bridge::start(&h.dir(), &[]);
    assert!(b.opening().is_empty());
    for i in 1..=500 {
        h.publish("a", me(), i, &format!("status {i} 0 state=working:progress={}\n", i % 100));
    }
    let (mut lines, mut last) = (0, 0);
    while last != 500 {
        last = b.next()["session"]["seq"].as_u64().unwrap();
        lines += 1;
    }
    assert!(lines < 50, "{lines} lines for 500 changes");
    b.quiet(100);
}

#[test]
fn hanging_up_ends_it() {
    let h = Host::new("eof");
    let mut b = Bridge::start(&h.dir(), &[]);
    assert!(b.opening().is_empty());
    assert!(b.child.try_wait().unwrap().is_none());
    drop(b.stdin.take());
    let t = Instant::now();
    while b.child.try_wait().unwrap().is_none() {
        assert!(t.elapsed() < Duration::from_secs(2), "still running after stdin closed");
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(b.child.wait().unwrap().success());
}

#[test]
fn once_prints_the_opening_and_stops() {
    let mut h = Host::new("once");
    h.make_dirs();
    h.socket("a");
    h.publish("a", me(), 1, "progress 1 5 remove\n");
    let out = command(&h.dir(), &["--once"]).stdin(Stdio::null()).output().unwrap();
    assert!(out.status.success());
    let lines: Vec<Value> = out.stdout.lines().map(|l| serde_json::from_str(&l.unwrap()).unwrap()).collect();
    assert_eq!(lines.len(), 3);
    assert_eq!(lines[1]["session"]["now"]["state"], "done");
    assert_eq!(lines[1]["session"]["now"]["source"], "progress");
}

#[test]
fn directories_that_are_not_private_are_refused() {
    let refused = |h: &Host, why: &str| {
        let out = command(&h.dir(), &["--once"]).stdin(Stdio::null()).output().unwrap();
        assert_eq!(out.status.code(), Some(2), "{why}");
        assert!(out.stdout.is_empty(), "{why}: said something first");
    };

    let h = Host::new("link");
    fs::create_dir(h.root.join("elsewhere")).unwrap();
    symlink(h.root.join("elsewhere"), h.facts_root()).unwrap();
    refused(&h, "a symlink for the root");

    let h = Host::new("open");
    h.make_dirs();
    fs::set_permissions(h.facts("now"), fs::Permissions::from_mode(0o755)).unwrap();
    refused(&h, "a readable now/");

    let h = Host::new("ro");
    let out = command(&h.dir(), &["--once", "--read-only"]).stdin(Stdio::null()).output().unwrap();
    assert_eq!(out.status.code(), Some(2), "read-only must not create what is missing");
    assert!(!h.facts_root().exists());
}

#[test]
fn odd_entries_are_ignored_and_old_leftovers_swept() {
    let mut h = Host::new("odd");
    h.make_dirs();
    h.socket("a");
    h.socket("link");
    h.socket("junk");
    h.publish("a", me(), 1, "");
    fs::write(h.root.join("target"), format!("v=1 pid={} born=9 seq=1\n", me())).unwrap();
    symlink(h.root.join("target"), h.facts("now").join("link")).unwrap();
    fs::create_dir(h.facts("now").join("subdir")).unwrap();
    fs::write(h.facts("now").join("junk"), b"\x00\xff not a facts file").unwrap();
    h.publish("gone", me(), 1, "");
    let old = fs::File::options().write(true).open(h.facts("now").join("gone")).unwrap();
    old.set_modified(std::time::SystemTime::now() - Duration::from_secs(60)).unwrap();
    h.publish("fresh", me(), 1, "");

    let out = command(&h.dir(), &["--once", "--read-only"]).stdin(Stdio::null()).output().unwrap();
    assert_eq!(out.stdout.lines().count(), 3);
    assert!(h.facts("now").join("gone").exists(), "read-only deletes nothing");

    let out = command(&h.dir(), &["--once"]).stdin(Stdio::null()).output().unwrap();
    let text = String::from_utf8(out.stdout).unwrap();
    assert_eq!(text.lines().count(), 3, "{text}");
    assert!(text.contains(r#""name":"a""#));
    assert!(!h.facts("now").join("gone").exists(), "ended a minute ago");
    assert!(h.facts("now").join("fresh").exists(), "may be a daemon that is just starting");
}

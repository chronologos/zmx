//! zmx-bridge: what the zmx sessions on this host say about themselves, as JSON lines.
//!
//! One bridge per connection, started by whoever wants to listen (locally as a child process,
//! remotely as `ssh host zmx-bridge`), gone when they hang up. It keeps nothing: every daemon
//! publishes its own state as a file, and this program watches the directory. See README.md for
//! the protocol.

mod facts;
mod scan;
mod text;
mod watch;

use rustix::event::{PollFd, PollFlags, Timespec, poll};
use scan::{Change, Store};
use serde::Serialize;
use std::error::Error;
use std::io::{self, Write};
use std::path::PathBuf;
use std::process::{Command, ExitCode};
use std::time::{Duration, Instant};

const PROTO: u32 = 1;
/// A program can change its status as fast as it can print. The listener hears at most this often.
const MIN_GAP: Duration = Duration::from_millis(30);
/// Nothing announces a killed process, so look anyway this often.
const RESCAN: Duration = Duration::from_secs(5);

const USAGE: &str = "\
usage: zmx-bridge [--once] [--read-only] [--dir <socket_dir>]

Prints one JSON object per line: hello, a `set` per live session, ready, then a
`set` or `del` whenever something changes. Exits when stdin closes.

  --once        stop after `ready`
  --read-only   never create directories or delete files of ended sessions
  --dir <path>  zmx's socket directory (default: ask `zmx version`)
  --stdio       accepted and ignored; it is the only mode
  --version";

#[derive(Serialize)]
#[serde(tag = "t", rename_all = "lowercase")]
enum Msg<'a> {
    Hello {
        proto: u32,
        bridge: &'a str,
        #[serde(skip_serializing_if = "Option::is_none")]
        zmx: Option<&'a str>,
    },
    /// The whole current state of one session. Replaces whatever was known about it.
    Set { session: &'a facts::Session },
    /// The session has ended.
    Del { name: &'a str },
    /// Every session that exists has now been sent.
    Ready,
}

fn send(out: &mut impl Write, msg: &Msg) -> io::Result<()> {
    serde_json::to_writer(&mut *out, msg)?;
    out.write_all(b"\n")
}

struct Args {
    once: bool,
    read_only: bool,
    dir: Option<PathBuf>,
}

fn args() -> Result<Option<Args>, String> {
    let mut a = Args { once: false, read_only: false, dir: None };
    let mut it = std::env::args_os().skip(1);
    while let Some(arg) = it.next() {
        match arg.to_str() {
            Some("--stdio") => {}
            Some("--once") => a.once = true,
            Some("--read-only") => a.read_only = true,
            Some("--dir") => a.dir = Some(it.next().ok_or("--dir needs a path")?.into()),
            Some("--version") => {
                println!("zmx-bridge {} proto {PROTO}", env!("CARGO_PKG_VERSION"));
                return Ok(None);
            }
            Some("--help" | "-h") => {
                println!("{USAGE}");
                return Ok(None);
            }
            _ => return Err(format!("unknown argument {arg:?}\n{USAGE}")),
        }
    }
    Ok(Some(a))
}

/// zmx is the only authority on where its sockets are (three environment variables and a
/// fallback), so ask it. The copy installed beside this program first: a non-interactive ssh
/// command often has a PATH without ~/.local/bin.
fn ask_zmx() -> Result<(PathBuf, Option<String>), Box<dyn Error>> {
    let beside = std::env::current_exe().ok().and_then(|p| Some(p.parent()?.join("zmx")));
    let zmx = beside.filter(|p| p.is_file()).unwrap_or_else(|| "zmx".into());
    let out = Command::new(&zmx).arg("version").output().map_err(|e| format!("{}: {e}", zmx.display()))?;
    let text = String::from_utf8_lossy(&out.stdout);
    let field = |key| text.lines().filter_map(|l| l.split_once('\t')).find(|p| p.0 == key).map(|p| p.1.trim());
    let dir = field("socket_dir").ok_or("`zmx version` did not print socket_dir")?;
    Ok((dir.into(), field("zmx").map(str::to_owned)))
}

fn emit(out: &mut impl Write) -> impl FnMut(Change) -> io::Result<()> + '_ {
    |c| match c {
        Change::Set(session) => send(out, &Msg::Set { session }),
        Change::Del(name) => send(out, &Msg::Del { name }),
    }
}

fn run(a: Args) -> Result<(), Box<dyn Error>> {
    let (dir, zmx) = match a.dir {
        Some(d) => (d, None),
        None => ask_zmx()?,
    };
    let mut store = Store::open(&dir, a.read_only)?;
    // Before the first scan, so nothing can slip between it and the first wait.
    let mut watcher = watch::Watcher::new(&[&store.now, &store.sockets])?;

    let mut out = io::stdout().lock();
    send(&mut out, &Msg::Hello { proto: PROTO, bridge: env!("CARGO_PKG_VERSION"), zmx: zmx.as_deref() })?;
    store.scan(emit(&mut out))?;
    send(&mut out, &Msg::Ready)?;
    out.flush()?;
    if a.once {
        return Ok(());
    }

    let stdin = io::stdin();
    let mut watch_stdin = true;
    let mut last = Instant::now();
    loop {
        let timeout = Timespec { tv_sec: RESCAN.as_secs() as _, tv_nsec: 0 };
        let mut fds = vec![PollFd::new(&watcher, PollFlags::IN)];
        if watch_stdin {
            fds.push(PollFd::new(&stdin, PollFlags::IN));
        }
        match poll(&mut fds, Some(&timeout)) {
            Ok(_) => {}
            Err(rustix::io::Errno::INTR) => continue,
            Err(e) => return Err(e.into()),
        }
        if let Some(ev) = fds.get(1).map(PollFd::revents) {
            if ev.contains(PollFlags::NVAL) {
                // Some systems cannot poll a terminal. Someone is running this by hand; ^C works.
                watch_stdin = false;
            } else if !ev.is_empty() {
                // Nothing is expected on stdin yet. It is held open by the listener, so its end
                // is how a hang-up looks from here.
                let mut sink = [0u8; 4096];
                if matches!(rustix::io::read(&stdin, &mut sink), Ok(0) | Err(_)) {
                    return Ok(());
                }
            }
        }
        if let Some(wait) = MIN_GAP.checked_sub(last.elapsed()) {
            std::thread::sleep(wait);
        }
        watcher.drain()?;
        store.scan(emit(&mut out))?;
        out.flush()?;
        last = Instant::now();
    }
}

fn main() -> ExitCode {
    let a = match args() {
        Ok(Some(a)) => a,
        Ok(None) => return ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("zmx-bridge: {e}");
            return ExitCode::from(64);
        }
    };
    match run(a) {
        Ok(()) => ExitCode::SUCCESS,
        // The listener went away mid-write. That is the normal way for this program to end.
        Err(e) if e.downcast_ref::<io::Error>().is_some_and(|e| e.kind() == io::ErrorKind::BrokenPipe) => {
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("zmx-bridge: {e}");
            ExitCode::from(2)
        }
    }
}

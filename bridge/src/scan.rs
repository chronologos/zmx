//! The directories: finding them, trusting them, and turning them into a set of live sessions.

use crate::facts::{self, Session};
use rustix::fs::{self, AtFlags, FileType, Mode, OFlags};
use rustix::io::Errno;
use rustix::process::{Pid, geteuid, test_kill_process};
use std::collections::BTreeMap;
use std::ffi::{CStr, OsString};
use std::io::{self, Read};
use std::os::fd::OwnedFd;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const MAX_SESSIONS: usize = 512;
/// 64 records of at most 4 KiB, and change.
const MAX_FILE_BYTES: u64 = 512 * 1024;
/// How long a dead session's file is left alone, in case its daemon is only just starting.
const GRACE: Duration = Duration::from_secs(10);

/// An open directory. Everything below it is reached through the descriptor, so what was checked
/// at open is what gets used. inotify alone insists on a path.
pub struct Dir {
    pub fd: OwnedFd,
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    pub path: PathBuf,
}

const OPEN_DIR: OFlags = OFlags::RDONLY.union(OFlags::DIRECTORY).union(OFlags::CLOEXEC);

fn refuse(path: &Path, why: &str) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, format!("{}: {why}", path.display()))
}

impl Dir {
    /// zmx's own directory. It must be ours; zmx decides its mode (sessions can be group-shared).
    fn sockets(path: &Path) -> io::Result<Dir> {
        let fd = fs::open(path, OPEN_DIR, Mode::empty())?;
        if fs::fstat(&fd)?.st_uid != geteuid().as_raw() {
            return Err(refuse(path, "not owned by this user"));
        }
        Ok(Dir { fd, path: path.to_owned() })
    }

    /// A facts directory: a real directory (not a link to one), ours, closed to everyone else.
    /// The socket directory can fall back to /tmp, where anyone may have made this one first.
    fn private(parent: Option<&Dir>, path: PathBuf, create: bool) -> io::Result<Dir> {
        let flags = OPEN_DIR | OFlags::NOFOLLOW;
        let fd = match parent {
            Some(p) => {
                let name = path.file_name().expect("a named child");
                if create {
                    let _ = fs::mkdirat(&p.fd, name, Mode::RWXU);
                }
                fs::openat(&p.fd, name, flags, Mode::empty())
            }
            None => {
                if create {
                    let _ = fs::mkdir(&path, Mode::RWXU);
                }
                fs::open(&path, flags, Mode::empty())
            }
        }
        .map_err(|e| io::Error::new(io::Error::from(e).kind(), format!("{}: {e}", path.display())))?;
        let st = fs::fstat(&fd)?;
        if st.st_uid != geteuid().as_raw() {
            return Err(refuse(&path, "not owned by this user"));
        }
        if Mode::from_raw_mode(st.st_mode).intersects(Mode::RWXG | Mode::RWXO) {
            return Err(refuse(&path, "open to other users"));
        }
        Ok(Dir { fd, path })
    }
}

/// What identifies one version of a file. Every publish is a rename, so the inode alone nearly
/// does; the rest is for filesystems that hand a freed inode straight back.
type Version = (u64, i64, i64, u64);

struct Cached {
    version: Version,
    /// `None`: read it, could not make sense of it, no point reading it again.
    session: Option<Session>,
}

pub enum Change<'a> {
    Set(&'a Session),
    Del(&'a str),
}

pub struct Store {
    pub sockets: Dir,
    pub now: Dir,
    read_only: bool,
    cache: BTreeMap<String, Cached>,
    /// What the other end has been told.
    sent: BTreeMap<String, Session>,
}

impl Store {
    pub fn open(socket_dir: &Path, read_only: bool) -> io::Result<Store> {
        // Same rule as the daemon: trailing slashes go, or ".facts" would land inside.
        let bytes = socket_dir.as_os_str().as_bytes();
        let end = bytes.iter().rposition(|&b| b != b'/').map_or(0, |i| i + 1);
        if end == 0 {
            return Err(refuse(socket_dir, "not a usable socket directory"));
        }
        let mut root = OsString::from_vec(bytes[..end].to_vec());
        root.push(".facts");
        let root = PathBuf::from(root);

        let sockets = Dir::sockets(socket_dir)?;
        let now_path = root.join("now");
        let root = Dir::private(None, root, !read_only)?;
        let now = Dir::private(Some(&root), now_path, !read_only)?;
        Ok(Store { sockets, now, read_only, cache: BTreeMap::new(), sent: BTreeMap::new() })
    }

    /// Look at the directory and report what differs from the last report.
    pub fn scan(&mut self, mut emit: impl FnMut(Change) -> io::Result<()>) -> io::Result<()> {
        let live = self.read()?;
        for name in self.sent.keys().filter(|n| !live.contains_key(*n)) {
            emit(Change::Del(name))?;
        }
        for (name, s) in &live {
            if self.sent.get(name) != Some(s) {
                emit(Change::Set(s))?;
            }
        }
        self.sent = live;
        Ok(())
    }

    // The fields of `stat` have different integer types on different systems.
    #[allow(clippy::unnecessary_cast)]
    fn read(&mut self) -> io::Result<BTreeMap<String, Session>> {
        let mut live = BTreeMap::new();
        let mut seen = BTreeMap::new();
        for entry in fs::Dir::read_from(&self.now.fd)? {
            let entry = entry?;
            let file = entry.file_name();
            // Any bytes but '/' and NUL make a legal session name. JSON wants text, and the app
            // only ever creates text names, so the rest are left out.
            let Ok(name) = file.to_str() else { continue };
            if name == "." || name == ".." || live.len() >= MAX_SESSIONS {
                continue;
            }
            let Ok(st) = fs::statat(&self.now.fd, file, AtFlags::SYMLINK_NOFOLLOW) else { continue };
            if FileType::from_raw_mode(st.st_mode) != FileType::RegularFile || st.st_size as u64 > MAX_FILE_BYTES {
                continue;
            }
            let version = (st.st_ino, st.st_mtime as i64, st.st_mtime_nsec as i64, st.st_size as u64);
            let cached = match self.cache.remove(name) {
                Some(c) if c.version == version => c,
                _ => Cached { version, session: self.load(file, name) },
            };
            if let Some(s) = &cached.session {
                if self.alive(file, s.pid) {
                    live.insert(name.to_owned(), s.clone());
                } else if !self.read_only && older_than(st.st_mtime as i64, GRACE) {
                    let _ = fs::unlinkat(&self.now.fd, file, AtFlags::empty());
                    continue;
                }
            }
            seen.insert(name.to_owned(), cached);
        }
        self.cache = seen;
        Ok(live)
    }

    fn load(&self, file: &CStr, name: &str) -> Option<Session> {
        let flags = OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC;
        let fd = fs::openat(&self.now.fd, file, flags, Mode::empty()).ok()?;
        let mut bytes = Vec::new();
        std::fs::File::from(fd).take(MAX_FILE_BYTES).read_to_end(&mut bytes).ok()?;
        facts::parse(name, &bytes)
    }

    /// A session is its socket and its child process. Either gone, it is over, whatever the file
    /// says: the daemon never cleans up after itself, and a killed one could not.
    fn alive(&self, file: &CStr, pid: i32) -> bool {
        let socket = fs::statat(&self.sockets.fd, file, AtFlags::SYMLINK_NOFOLLOW)
            .is_ok_and(|st| FileType::from_raw_mode(st.st_mode) == FileType::Socket);
        let process = (pid > 0).then(|| Pid::from_raw(pid)).flatten();
        socket && process.is_some_and(|p| !matches!(test_kill_process(p), Err(Errno::SRCH)))
    }
}

fn older_than(mtime_secs: i64, age: Duration) -> bool {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64);
    now.saturating_sub(mtime_secs) > age.as_secs() as i64
}

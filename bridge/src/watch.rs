//! "Something in these directories changed", as one pollable descriptor. The only file that
//! differs by operating system. A wake-up is a hint and carries no detail: the scan that follows
//! looks at everything, so a missed, merged or spurious one costs at most a little time.

use crate::scan::Dir;
use std::io;
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};

#[cfg(any(target_os = "macos", target_os = "freebsd"))]
pub struct Watcher {
    queue: OwnedFd,
    /// Our own copies, so they are open for as long as the queue refers to them.
    _dirs: Vec<OwnedFd>,
}

#[cfg(any(target_os = "macos", target_os = "freebsd"))]
impl Watcher {
    pub fn new(dirs: &[&Dir]) -> io::Result<Watcher> {
        use rustix::event::kqueue::{Event, EventFilter, EventFlags, VnodeEvents, kevent, kqueue};
        use std::os::fd::AsRawFd;

        let queue = kqueue()?;
        let dirs = dirs.iter().map(|d| d.fd.try_clone()).collect::<io::Result<Vec<_>>>()?;
        let add: Vec<Event> = dirs
            .iter()
            .map(|fd| {
                // A directory is "written" when an entry is added, removed or renamed over.
                let filter = EventFilter::Vnode { vnode: fd.as_raw_fd(), flags: VnodeEvents::WRITE };
                Event::new(filter, EventFlags::ADD | EventFlags::CLEAR, std::ptr::null_mut())
            })
            .collect();
        let mut none: [Event; 0] = [];
        // SAFETY: kevent requires the descriptors named in `add` to stay open while the queue
        // holds them. `_dirs` owns them and is dropped together with `queue`.
        unsafe { kevent(&queue, &add, &mut none, None) }?;
        Ok(Watcher { queue, _dirs: dirs })
    }

    /// Forget the wake-ups so far. Call before scanning, so a change during the scan wakes again.
    pub fn drain(&mut self) -> io::Result<()> {
        use rustix::event::kqueue::{Event, kevent};
        let mut got: Vec<Event> = Vec::with_capacity(8);
        // SAFETY: nothing is being added, so there is no descriptor to keep alive.
        unsafe { kevent(&self.queue, &[], rustix::buffer::spare_capacity(&mut got), Some(std::time::Duration::ZERO)) }?;
        Ok(())
    }
}

#[cfg(any(target_os = "macos", target_os = "freebsd"))]
impl AsFd for Watcher {
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.queue.as_fd()
    }
}

#[cfg(target_os = "linux")]
pub struct Watcher {
    inotify: OwnedFd,
}

#[cfg(target_os = "linux")]
impl Watcher {
    pub fn new(dirs: &[&Dir]) -> io::Result<Watcher> {
        use rustix::fs::inotify::{CreateFlags, WatchFlags, add_watch, init};
        let inotify = init(CreateFlags::NONBLOCK | CreateFlags::CLOEXEC)?;
        let events = WatchFlags::MOVED_TO | WatchFlags::MOVED_FROM | WatchFlags::CREATE | WatchFlags::DELETE;
        for d in dirs {
            add_watch(&inotify, &d.path, events | WatchFlags::ONLYDIR)?;
        }
        Ok(Watcher { inotify })
    }

    /// Forget the wake-ups so far. Call before scanning, so a change during the scan wakes again.
    pub fn drain(&mut self) -> io::Result<()> {
        let mut buf = [0u8; 4096];
        loop {
            match rustix::io::read(&self.inotify, &mut buf) {
                Ok(0) | Err(rustix::io::Errno::WOULDBLOCK) => return Ok(()),
                Ok(_) | Err(rustix::io::Errno::INTR) => {}
                Err(e) => return Err(e.into()),
            }
        }
    }
}

#[cfg(target_os = "linux")]
impl AsFd for Watcher {
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.inotify.as_fd()
    }
}

# zmx-bridge

Streams what the zmx sessions on this host say about themselves, one JSON object per line.

```
program ──▶ zmx daemon ──▶ <socket_dir>.facts/now/<session> ──▶ zmx-bridge ──▶ stdout
            src/fork/facts.zig     one small file, replaced whole      watches the directory
```

It is not part of zmx's build: its own toolchain, its own directory, nothing upstream is edited for
it. It keeps no state and listens on nothing. Whoever wants the stream starts one, as a child process
or as `ssh host zmx-bridge`, and it exits when its stdin closes. Access control is whatever let you
start it.

```
zmx-bridge | jq -c .                 # watch this host
zmx-bridge --once | jq .             # what is true right now
ssh somehost zmx-bridge --read-only  # watch another; safe as a forced command
```

## Protocol 1

| line | meaning |
|---|---|
| `{"t":"hello","proto":1,"bridge":"0.1.0","zmx":"0.8.1"}` | First line, always. Forget anything known about this host. |
| `{"t":"set","session":{…}}` | The whole current state of one session. Replaces what was known about it. |
| `{"t":"del","name":"…"}` | The session has ended. |
| `{"t":"ready"}` | Once, after the opening `set`s: every session that exists has been sent. |

State, never events: a `set` is complete in itself, so a reader that drops some and keeps the last is
still right. A burst of changes arrives as its final state; a listener hears at most one update per
30 ms. Readers must ignore `t` values and fields they do not know.

A session:

```json
{
  "name": "work", "pid": 4242, "born": 1792270684, "seq": 15,
  "now":    {"id": "", "state": "blocked", "kind": "question", "app": "claude-code",
             "msg": "Do you prefer red or blue?", "source": "status", "seq": 15, "at": 1792270709568},
  "status": [ …every record, same shape as `now`… ],
  "bell":   {"count": 2, "seq": 3, "at": 0},
  "mark":   {"step": "output_start", "seq": 1, "at": 0},
  "exit":   {"code": 3, "seq": 6, "at": 0},
  "title":  {"text": "Single word reply", "seq": 7, "at": 0},
  "pwd":    {"text": "file://host/path", "seq": 4, "at": 0},
  "notify": {"title": "Claude Code", "body": "Claude needs your permission", "seq": 16, "at": 0}
}
```

Only `name`, `pid`, `born` and `seq` are always present.

- `seq` on a fact is the session's `seq` when that fact last changed. **Unread is `fact.seq` greater
  than the `seq` you last showed the user**, compared as `(born, seq)` so a restarted session starts
  over. Nothing needs clearing, and two viewers cannot disagree about what happened.
- `at` is wall-clock milliseconds on that host. For display.
- `state`: `idle`, `done`, `working`, `error`, `blocked`. `kind` (only with `blocked`):
  `permission`, `question`, `auth`. `progress`: 0-100, only with `working` or `blocked`.

### What the bridge decides

The daemon records; the bridge interprets. A daemon runs the code it started with until its session
ends, while a bridge is replaced at the next reconnect, so opinions live here.

- **`now`** is the one status to show for the session: the record that most needs the user
  (`blocked` > `error` > `working` > `done` > `idle`), then the one nearest the root, then the latest.
- **No OSC 7501 at all?** `now` is inferred from OSC 9;4, marked `"source":"progress"`: a progress
  bar means `working`, its removal means `done`.
- **`idle` ends with its program.** An `idle` record older than the last shell mark is dropped.
- **Alive** means the socket exists and the pid answers. Files of ended sessions are ignored, and
  deleted once they are ten seconds old (not with `--read-only`).
- **Text is defused**: base64 and UTF-8 checked, control characters, direction overrides and other
  invisible characters removed, lengths capped. It is still whatever the program wanted to say.
- Sessions whose names are not UTF-8 are left out.

### Refusals

Exit 2, nothing on stdout, a line on stderr, if the facts directory is a symlink, belongs to someone
else, or is open to other users; if `zmx` cannot be found; or, with `--read-only`, if no daemon has
made the directory yet. Exit 64 for bad arguments.

## Building

```
cargo test            # the integration tests bind unix sockets under /tmp
./dist.sh             # static binaries for Linux and macOS in target/dist/
```

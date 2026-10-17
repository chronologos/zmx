# Facts files, version 1

Each daemon publishes what the program in its pty has told the terminal about itself, as one small
text file. `facts.zig` writes it; `bridge/` reads it. This is the whole contract between them.

## Where

```
<socket_dir>.facts/now/<session>     the current state, always complete
<socket_dir>.facts/tmp/<session>     being written; never read this
```

`<socket_dir>` is what `zmx version` prints, with trailing slashes removed. All three directories
are `0700` and owned by the user; files are `0600`. A writer or reader that finds a directory it
does not own, or a symlink in its place, must refuse to use it.

A file is replaced by `rename(2)`, so a reader never sees half of one. Watch `now/` for entries
arriving; do not watch the files, their inodes change every time.

The daemon never deletes its file. A file whose `pid` is gone, or whose socket is gone, describes a
session that has ended. Readers ignore it and may delete it.

Session names may contain any byte except `/` and NUL. Do not assume UTF-8, and do not print them
unescaped.

## Format

Lines end in `\n`. Columns are separated by one space. The first line is the header; every other
line is one fact:

```
v=1 pid=<int> born=<unix seconds> seq=<int>
<kind> <seq> <at> <value...>
```

- `pid`: the session's child process, as in `zmx list`.
- `born`: when the daemon started. `(born, seq)` orders changes across a restart under the same name.
- header `seq`: goes up by at least one with every change, including removals. Starts at 0.
- fact `seq`: the header `seq` at the moment this fact last changed. Compare it with a remembered
  value to tell whether something is new; nobody has to clear anything.
- `at`: the same moment as wall-clock milliseconds, on the daemon's host. For display only.

A fact that is absent has no line. Readers must skip kinds and header keys they do not know.

| kind | value | source | goes away |
|---|---|---|---|
| `status` | the validated OSC 7501 body, verbatim, e.g. `state=blocked:kind=question:msg=<base64>` | OSC 7501 | see below |
| `progress` | `set`, `error`, `indeterminate`, `pause` or `remove`, then optionally `0`-`100` | OSC 9;4 | never; `remove` is recorded only after one of the others, and means it ended |
| `bell` | count since the daemon started | BEL | never |
| `mark` | `prompt_start`, `input_start`, `output_start` or `command_end` | OSC 133 | full reset |
| `exit` | exit code of the last finished command | OSC 133;D | next `output_start`, full reset |
| `title` | base64 of the title, at most 256 bytes before encoding | OSC 0, 2 | empty title, full reset |
| `pwd` | the URI as sent, e.g. `file://host/path` | OSC 7 | empty or unprintable, full reset |
| `notify` | base64 title (or `-`), base64 body; at most 128 and 512 bytes | OSC 9, 777 | never; only the last is kept |

There is one `status` line per record, oldest change first, at most 64. The record's id is the `id`
key in the body; no `id` means the root record.

- A report replaces the record with the same id. An identical report changes nothing.
- `state=clear` removes the addressed record and everything under it (`a` covers `a/b`, not `ab`).
- A primary `prompt_start` removes `working` and `blocked` records: the shell is back, so the
  program is not running. `idle`, `done` and `error` stay; compare their `seq` with `mark`'s.
- Over 64, the record that changed longest ago is dropped.
- `status` bodies and `pwd` contain no byte at or below 0x20 and no 0x7f.

Everything after `<at>` is chosen by whatever runs in the pty. Treat it as hostile.

## The probe

A program asks `OSC 7501 ; ? ST` to learn whether anyone is listening. The daemon answers, always,
attached or not, and before its reply to anything the program asks afterwards. The query is still
forwarded to attached terminals. If a terminal starts answering too, the daemon must stop forwarding it.

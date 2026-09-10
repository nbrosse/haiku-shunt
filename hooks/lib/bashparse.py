#!/usr/bin/env python3
"""Decide whether a Bash command dumps a file into the model's context.

Only reached when the bash fast-path has already seen a reader command name,
so the interpreter start-up is not on the hot path.

Every segment of the command is examined, not just the first reader: in
`head -5 small; cat big` it is the second one that matters. A reader whose
stdout is redirected, or piped into a filter (grep, wc, ...), is skipped; one
piped only through copies (`| cat`, `| tee f`, `| head -N`) still reaches the
model and is checked, with any `head`/`tail` bound applied.

Emits one JSON object on stdout:
  {"verdict": "check"|"allow", "reason": <reason_code>,
   "files": [{"path": abs, "reader": cmd,
              "bound_lines": <int|null>, "from_line": <int|null>}, ...]}

"check" means: probe these files and apply the thresholds.
"allow" means: stop, nothing in this command puts a file in front of the
model; "reason" says why the first reader found was not a candidate.
"""
import json, os, shlex, sys

READERS = {"cat", "less", "more", "bat"}
BOUNDED = {"head", "tail"}
# Pipe stages that copy stdin to stdout unchanged (tee's operands are outputs).
PASSTHROUGH = READERS | {"tee"}
# Stripped before looking for the real command.
PREFIXES = {"sudo", "env", "command", "builtin", "exec", "nice", "ionice",
            "timeout", "stdbuf", "nohup", "time"}
PREFIX_TAKES_ARG = {"nice": {"-n"}, "ionice": {"-c", "-n"}, "timeout": {"-k", "-s"},
                    "stdbuf": {"-i", "-o", "-e"}}


class Seg:
    __slots__ = ("text", "piped_out", "redirected", "heredoc", "subst", "stdin_file")

    def __init__(self):
        self.text = ""
        self.piped_out = False
        self.redirected = False
        self.heredoc = False
        self.subst = False
        self.stdin_file = None


def scan(cmd):
    """Split on shell operators while respecting quotes, and pull redirections
    out of the word stream so the remainder can be tokenised safely."""
    segs, cur = [], Seg()
    i, n = 0, len(cmd)
    sq = dq = False

    def flush():
        nonlocal cur
        if cur.text.strip() or cur.stdin_file or cur.heredoc:
            segs.append(cur)
        cur = Seg()

    def eat_target(j):
        """Consume whitespace then one word; return (word, new_index)."""
        while j < n and cmd[j] in " \t":
            j += 1
        start, q1, q2 = j, False, False
        while j < n:
            c = cmd[j]
            if c == "'" and not q2:
                q1 = not q1
            elif c == '"' and not q1:
                q2 = not q2
            elif not q1 and not q2 and (c in " \t\n;&|<>"):
                break
            j += 1
        return cmd[start:j], j

    while i < n:
        c = cmd[i]
        if sq:
            cur.text += c
            if c == "'":
                sq = False
            i += 1
            continue
        if dq:
            cur.text += c
            if c == "\\" and i + 1 < n:
                cur.text += cmd[i + 1]
                i += 2
                continue
            if c == '"':
                dq = False
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            cur.text += c + cmd[i + 1]
            i += 2
            continue
        if c == "'":
            sq = True
            cur.text += c
            i += 1
            continue
        if c == '"':
            dq = True
            cur.text += c
            i += 1
            continue
        if c == "`":
            cur.subst = True
            i += 1
            continue
        if c == "$" and i + 1 < n and cmd[i + 1] == "(":
            cur.subst = True
            depth, i = 1, i + 2
            while i < n and depth:
                if cmd[i] == "(":
                    depth += 1
                elif cmd[i] == ")":
                    depth -= 1
                i += 1
            continue
        if cmd.startswith("&>", i):
            cur.redirected = True
            _, i = eat_target(i + 2)
            continue
        if cmd.startswith("<<", i):
            # Heredoc: the body is data, not a file read, and must never be
            # rescanned for commands it happens to mention.
            cur.heredoc = True
            return segs + [cur]
        if c == "<":
            # `cat < big` still dumps the file to stdout.
            tgt, i = eat_target(i + 1)
            cur.stdin_file = tgt
            continue
        if c == ">":
            j = i
            while j < n and cmd[j] == ">":
                j += 1
            prev = cmd[i - 1] if i else ""
            # 2>/dev/null redirects only stderr; stdout still reaches the model.
            fd_is_stderr = prev.isdigit() and prev != "1"
            if fd_is_stderr:
                # drop the trailing fd digit we already appended
                if cur.text.endswith(prev):
                    cur.text = cur.text[:-1]
            else:
                cur.redirected = True
                if cur.text.endswith("1") or cur.text.endswith("&"):
                    cur.text = cur.text[:-1]
            _, i = eat_target(j)
            continue
        if c == "|":
            if cmd.startswith("||", i):
                flush()
                i += 2
                continue
            cur.piped_out = True
            flush()
            i += 1
            continue
        if cmd.startswith("&&", i):
            flush()
            i += 2
            continue
        if c in ";&\n":
            flush()
            i += 1
            continue
        cur.text += c
        i += 1
    flush()
    return segs


def strip_prefixes(words):
    while words:
        w = words[0]
        base = os.path.basename(w)
        if "=" in w and not w.startswith("=") and "/" not in w.split("=")[0]:
            words = words[1:]           # FOO=1 cat f
            continue
        if base in PREFIXES:
            words = words[1:]
            takes = PREFIX_TAKES_ARG.get(base, set())
            while words:
                if words[0] in takes:
                    words = words[2:]
                elif base == "timeout" and words and words[0].replace(".", "").isdigit():
                    words = words[1:]
                    break
                elif words[0].startswith("-"):
                    words = words[1:]
                else:
                    break
            continue
        break
    return words


def parse_bounds(base, args):
    """Return (bound_lines, from_line, operands). bound_lines None == unbounded."""
    counted = base in BOUNDED
    bound = 10 if counted else None   # bare head/tail default
    from_line = None
    operands, i, explicit = [], 0, False
    while i < len(args):
        a = args[i]
        if a == "--":
            operands.extend(args[i + 1:])
            break
        if a.startswith("--"):
            if counted and a.startswith("--lines="):
                v = a.split("=", 1)[1]
                bound, explicit = num_bound(v, base), True
            elif counted and a.startswith("--bytes="):
                bound, explicit = 1, True      # byte-bounded: treat as tiny
            i += 1
            continue
        if a.startswith("-") and len(a) > 1:
            if not counted:
                i += 1          # cat/less/more/bat: every dash-word is a flag
                continue
            if a[1:].lstrip("+-").isdigit() and not a[1].isalpha():
                bound, from_line = num_bound(a[1:], base)          # head -100
                explicit = True
                i += 1
                continue
            if a in ("-n", "-c"):
                if i + 1 < len(args):
                    if a == "-n":
                        bound, from_line = num_bound(args[i + 1], base)
                    else:
                        bound = 1
                    explicit = True
                    i += 2
                    continue
                i += 1
                continue
            if a.startswith("-n"):
                bound, from_line = num_bound(a[2:], base)
                explicit = True
                i += 1
                continue
            if a.startswith("-c"):
                bound, explicit = 1, True
                i += 1
                continue
            if a in ("-f", "-F", "--follow"):
                return "follow", None, []
            i += 1
            continue
        operands.append(a)
        i += 1
    if base in READERS:
        bound = None
    elif not explicit:
        bound = 10
    return bound, from_line, operands


def num_bound(v, base):
    """Returns (bound_lines, from_line).

    `tail -n +N` reads from line N to EOF -- bounded, but by the file length,
    so the caller resolves it. `head -n -N` means all but the last N: unbounded.
    """
    if v.startswith("+"):
        return (None, safe_int(v[1:])) if base == "tail" else (safe_int(v[1:]), None)
    if v.startswith("-"):
        return (None, None)
    return (safe_int(v), None)


def safe_int(v):
    try:
        return int(v)
    except ValueError:
        return None


def out(verdict, reason, files=()):
    print(json.dumps({"verdict": verdict, "reason": reason, "files": list(files)}))
    sys.exit(0)


def words_of(seg):
    """The segment's command words, prefixes stripped. None if unparseable."""
    try:
        return strip_prefixes(shlex.split(seg.text.strip(), posix=True))
    except ValueError:
        return None                              # unbalanced quotes


def through_pipe(stages, i, bound):
    """Follow a reader's stdout down its pipeline. Returns the bound that
    survives to the end if the content still reaches the model, else the
    reason it does not ("piped" into a filter, or "redirected")."""
    while stages[i][0].piped_out:
        i += 1
        if i >= len(stages):
            return "piped"
        seg, words = stages[i]
        if not words or seg.subst or seg.heredoc:
            return "piped"
        base = os.path.basename(words[0])
        if base not in PASSTHROUGH and base not in BOUNDED:
            return "piped"                       # grep, wc, sort...: see Non-goals
        if base != "tee":
            b, from_line, operands = parse_bounds(base, words[1:])
            if b == "follow" or (operands and "-" not in operands):
                return "piped"                   # reads its own files, not stdin
            if base in BOUNDED and from_line is None and b is not None:
                bound = b if bound is None else min(bound, b)
        if seg.redirected:
            return "redirected"
    return bound


def main():
    cmd = sys.stdin.read()
    cwd = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    try:
        stages = [(s, words_of(s)) for s in scan(cmd)]
    except Exception:
        out("allow", "internal_error")

    files, skipped = [], None
    for i, (seg, words) in enumerate(stages):
        if words is None:
            skipped = skipped or "unresolvable_arg"
            continue
        if not words:
            continue
        base = os.path.basename(words[0])

        if base == "cd":
            if len(words) > 1 and "$" not in words[1]:
                cwd = os.path.normpath(os.path.join(cwd, os.path.expanduser(words[1])))
            continue

        if base not in READERS and base not in BOUNDED:
            continue

        # Why this reader never puts a file on the model's stdout, if it doesn't.
        reason, bound, from_line, operands = None, None, None, []
        if seg.heredoc:
            reason = "heredoc"
        elif seg.redirected:
            reason = "redirected"
        elif seg.subst:
            reason = "unresolvable_arg"
        else:
            bound, from_line, operands = parse_bounds(base, words[1:])
            if seg.stdin_file:
                operands = operands + [seg.stdin_file]
            if bound == "follow":
                reason = "not_a_reader_command"  # never block a follow
            elif not operands:
                reason = "no_file_operand"
            elif any(c in o for o in operands for c in "$*?["):
                reason = "unresolvable_arg"      # do not glob in a hook
            elif seg.piped_out:
                bound = through_pipe(stages, i, bound)
                if isinstance(bound, str):
                    reason = bound
        if reason:
            skipped = skipped or reason
            continue

        for o in operands:
            p = os.path.expanduser(o)
            files.append({"path": p if os.path.isabs(p) else os.path.normpath(os.path.join(cwd, p)),
                          "reader": base, "bound_lines": bound, "from_line": from_line})

    if files:
        out("check", "candidate", files)
    out("allow", skipped or "not_a_reader_command")


if __name__ == "__main__":
    main()

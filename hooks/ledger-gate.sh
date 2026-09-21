#!/usr/bin/env bash
# loop-testing ledger-gate — PreToolUse hook (Write | Edit | MultiEdit | Bash).
#
# Raises the cost of faking a VERIFIED verdict in the issue ledger. Per the
# state protocol (references/issue-rules.md §7), an ISSUE may reach VERIFIED
# ONLY by replaying its reproduction steps, with the replay recorded that round
# in runs/round-N.md. This hook denies a write that stamps `VERIFIED` onto an
# ISSUE in docs/looptesting/ISSUES.md when that ISSUE-ID has NO replay footprint
# in ANY runs/round-*.md log — the high-confidence "verified out of thin air"
# case.
#
# DESIGN POSITION (architecture §2.4): this is a cheat-cost raiser, NOT a
# complete gate. It deliberately checks "any round log mentions the ID" rather
# than "this exact round replayed it", to stay conservative — 宁可放过不可误杀
# (prefer a miss over a false-positive). The common accidental and lazy forms of
# a fake verdict are denied; a determined model walks through the front door by
# writing a fake replay line into a round log first. Describe this as a SOFT gate
# that raises the cost of cheating, never as "mechanically prevents" (audit K-04).
#
# WHAT A Bash COMMAND HAS TO BE to count as a ledger write: the ledger has to be
# the thing a writing verb writes. The writer set, in full:
#   * a redirection target (`>`, `>>`, `2>`, `>|`);
#   * an operand of `tee` or `sponge`;
#   * a file operand of an in-place `sed`/`perl`/`ruby` (`-i`, `--in-place`);
#   * the output file of `sort -o` / `--output`, or the OUT positional of
#     `uniq IN OUT` — two entries on the filter list that a flag turns into
#     writers.
# The verb is read after skipping `VAR=val` assignments AND after unwrapping
# wrapper verbs (`command`, `env`, `nice`, `timeout`, `stdbuf`, `nohup`,
# `busybox`, `xargs`, …), which otherwise hide the writer behind them.
#
# That decision is made by LEXING the command (python3 `shlex`, no expansion, no
# grammar, no execution) and comparing operand TOKENS to the ledger path. It is
# not the only path: without python3, past the length cap, when the lexer rejects
# the input, or when a write target is unresolvable, the regex leg further down
# decides instead, and it is weaker. Both legs are target-bound.
#
# A read of the ledger is never a write, however many write-looking tokens share
# the command line — H-01 was that false deny, and the accusation this hook
# prints at a correct action is its most expensive failure mode.
#
# RESIDUAL — these still reach the ledger unseen:
#   * indirection through another interpreter: `bash -c`, `python3 -c`,
#     `ruby -e`, `ed`, and file-copy verbs whose target needs per-verb argument
#     knowledge (`mv`, `cp`, `dd`, `install`, `truncate`);
#   * A REDIRECT WRITTEN INSIDE ANOTHER LANGUAGE. `awk '{print > "ledger"}'`,
#     and the same through perl `open` or ruby `File.write`. The redirect is in
#     the program text, not in the shell, and this gate reads shell. Closing it
#     would mean parsing every embedded language, so it stays here beside
#     `python3 -c` rather than being chased;
#   * a path computed at runtime — a variable, a command substitution, a glob —
#     which is reported as unresolved and never guessed at. A BRACKET glob is
#     worse than the others: `ISSUE[S].md` splits the literal name, so the regex
#     leg cannot see it either and the write is allowed by both legs. The lexer
#     flags it rather than silently reading it as some unrelated file, which is
#     all it can honestly do without expanding the path;
#   * a command past the length cap, or one the lexer REJECTS (a command the
#     shell frequently still runs — see the fallback leg), falls back to the
#     regex leg below, which is weaker: its in-place arm still wants the flag and
#     the path in one unbroken span. Without python3 that leg is all there is.
#   * an in-place script supplied by `-f scriptfile`, whose text is not in the
#     command;
#   * content that never appears in the command at all — `tee ledger < row.txt`,
#     `cp forged.md ledger`. This gate reads command text and nothing else, so
#     there is no version of it that judges these;
#   * a fake replay line written to a round log first — the original design
#     residual, unchanged.
#
# WHERE THIS PREDICATE ACTUALLY STANDS. Do not read any of the above as "closed".
# Two failure directions, and they are not symmetric. The regex predicate this
# replaced OVER-matched: it read a `grep` of the ledger as a write and accused
# the model of faking a verdict, which is the expensive failure, and every such
# false deny found in review is fixed here. The lexer UNDER-matches instead, and
# its tail is long, because a shell has many ways to name a writer indirectly.
# Two families have each been re-cut several times:
#
#   1. Getting the written text where the write group cannot see it — pipeline
#      grouping, brace lists and subshells, here-strings, newlines.
#   2. Naming the writer so the verb lookup misses it — wrappers (`command`,
#      `env`, `timeout`, `xargs`, …), and a listed filter that a flag turns into
#      a writer (`sort -o`, `uniq IN OUT`).
#
# Four review rounds found four holes in the first family; a fifth pass found
# four more in the second in ten minutes. That is not the signature of an
# exhausted family, so assume siblings remain. What is true is that the defaults
# fail safe: text that cannot be placed does NOT earn the downgrade exit, the
# row-dropping exemption needs a real filter chain feeding a writer through a
# pipe, and an unresolvable write target is reported rather than guessed at.
# Treat a new sibling as a bug to fix, not as a shape this comment covers, and
# keep the cheat-cost framing above — a model that wants a fake verdict writes a
# fake replay line and never touches any of this.
#
# Fails OPEN on any parse problem or missing tooling — a gate must never brick a
# session. Escape hatch (humans, not models): LOOP_TESTING_DISABLE_LEDGER_GATE=1.
set -u

if [ "${LOOP_TESTING_DISABLE_LEDGER_GATE:-0}" = "1" ]; then
  cat > /dev/null; exit 0
fi

# Strip NUL bytes before the command substitution: bash warns on stderr about
# them, and a PreToolUse hook that exits 0 with noise on stderr still shows that
# noise to the model. No payload field can legitimately contain one. Both spellings
# go: a raw byte, and the `\u0000` escape that the JSON parsers decode into one.
INPUT=$(cat | tr -d '\000' | sed 's/\\[uU]0000//g')

# --- anchor to the project root (audit HK-7) ----------------------------------
# Same anchoring as stop-gate.sh: the hook cwd is not guaranteed to be the
# project root, and this gate's armed-check (.active) and replay lookup (runs/)
# are cwd-relative. Precedence: $CLAUDE_PROJECT_DIR -> stdin "cwd" -> stay put.
BASE="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$BASE" ] && command -v jq >/dev/null 2>&1; then
  BASE=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
fi
if [ -z "$BASE" ]; then
  BASE=$(printf '%s' "$INPUT" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi
# TWO states, not one — see the note in stop-gate.sh (delta review D1/D2). Here
# the cost of conflating them lands as a FALSE DENY: with no anchor supplied the
# walk-up stopped firing, the toplevel replay footprint went invisible, and a
# correctly-replayed VERIFIED write was refused with the red-line accusation.
ANCHOR_FAILED=0
if [ -n "$BASE" ]; then
  if [ -d "$BASE" ] && cd "$BASE" 2>/dev/null; then :; else ANCHOR_FAILED=1; fi
fi

# --- and up to the git toplevel when the anchor is a subpackage (audit K-14) ---
# Kept identical to stop-gate.sh; see the long note there. Here the cost lands on
# the Bash leg and in the other direction: the ledger OPERAND is recognised by
# path suffix, so it is found from anywhere, while ARMED and the replay lookup
# below are cwd-relative. From a subpackage that meant a VERIFIED write with a
# perfectly good replay at the toplevel was DENIED — H-01's direction, reached
# through the anchor rather than through the lexer.
# Gated on the anchor having RESOLVED, and it records WHETHER it moved — see the
# note in stop-gate.sh for the first (review F3), and ARMED below for the second
# (review F2). The P-05 residual is stated there too and applies here unchanged.
LT_WALKED=0
if [ "$ANCHOR_FAILED" = 0 ] && [ ! -d docs/looptesting ] && command -v git >/dev/null 2>&1; then
  # Budgeted, like the STATE grep below (review F7). This is the only subprocess
  # the walk-up adds to a gate whose header requires every addition to be O(1) or
  # capped: on a stale NFS mount or a hung gitdir an unbounded `git rev-parse`
  # blocks until the platform kills the hook, and a killed Stop hook resolves as
  # ALLOW — a fail-open path inside a fail-closed gate.
  if command -v timeout >/dev/null 2>&1; then
    GTOP=$(timeout 5 git rev-parse --show-toplevel 2>/dev/null)
  else
    GTOP=$(git rev-parse --show-toplevel 2>/dev/null)
  fi
  if [ -n "$GTOP" ] && [ -d "$GTOP/docs/looptesting" ]; then
    if cd "$GTOP" 2>/dev/null; then LT_WALKED=1; fi
  fi
fi

TOOL=""; FILE=""; NEWSTR=""; CONTENT=""; CMD=""; OLDSTR=""
if command -v jq >/dev/null 2>&1; then
  TOOL=$(printf '%s' "$INPUT"    | jq -r '.tool_name // empty'                 2>/dev/null) || TOOL=""
  FILE=$(printf '%s' "$INPUT"    | jq -r '.tool_input.file_path // empty'      2>/dev/null) || FILE=""
  NEWSTR=$(printf '%s' "$INPUT"  | jq -r '.tool_input.new_string // empty'     2>/dev/null) || NEWSTR=""
  CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty'        2>/dev/null) || CONTENT=""
  # MultiEdit: concatenate every edit's new_string so multi-edit writes are seen.
  MULTI=$(printf '%s' "$INPUT"   | jq -r '(.tool_input.edits // [])[].new_string // empty' 2>/dev/null) || MULTI=""
  NEWSTR="$NEWSTR
$MULTI"
  # old_string(s): used only to resolve the ISSUE-ID a minimal VERIFIED edit flips.
  # For MultiEdit, ONLY the edits that actually introduce VERIFIED contribute: a
  # sibling edit's header line used to supply the ID, so the gate denied an issue
  # the call never verified.
  OLDSTR=$(printf '%s' "$INPUT"  | jq -r '.tool_input.old_string // empty'     2>/dev/null) || OLDSTR=""
  MULTIOLD=$(printf '%s' "$INPUT" | jq -r '[(.tool_input.edits // [])[] | select(((.new_string // "") | test("(^|[^A-Za-z0-9_])VERIFIED([^A-Za-z0-9_]|$)"))) | (.old_string // "")] | join("\n")' 2>/dev/null) || MULTIOLD=""
  OLDSTR="$OLDSTR
$MULTIOLD"
  CMD=$(printf '%s' "$INPUT"     | jq -r '.tool_input.command // empty'        2>/dev/null) || CMD=""
elif command -v python3 >/dev/null 2>&1; then
  PARSED=$(printf '%s' "$INPUT" | python3 -c '
import json,sys,shlex,re
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
ti=d.get("tool_input") or {}
multi="\n".join((e or {}).get("new_string","") for e in (ti.get("edits") or []))
_V=re.compile(r"(^|[^A-Za-z0-9_])VERIFIED([^A-Za-z0-9_]|$)")
multiold="\n".join((e or {}).get("old_string","") for e in (ti.get("edits") or [])
                   if _V.search((e or {}).get("new_string","") or ""))
print("TOOL=%s"    % shlex.quote(str(d.get("tool_name",""))))
print("FILE=%s"    % shlex.quote(str(ti.get("file_path",""))))
print("NEWSTR=%s"  % shlex.quote(str(ti.get("new_string",""))+"\n"+multi))
print("OLDSTR=%s"  % shlex.quote(str(ti.get("old_string",""))+"\n"+multiold))
print("CONTENT=%s" % shlex.quote(str(ti.get("content",""))))
print("CMD=%s"     % shlex.quote(str(ti.get("command",""))))
' 2>/dev/null) || PARSED=""
  eval "$PARSED"
else
  echo "loop-testing ledger-gate: no jq or python3; gate inactive for this call." >&2
  exit 0
fi

# The text this tool call would introduce, and whether it targets the ledger.
TEXT=""; TARGETS_LEDGER=0; LT_DIR=""; INPLACE=0
is_issues_path() { case "$1" in */docs/looptesting/ISSUES.md|docs/looptesting/ISSUES.md) return 0 ;; *) return 1 ;; esac; }

case "$TOOL" in
  Write|Edit|MultiEdit)
    if is_issues_path "$FILE"; then
      TARGETS_LEDGER=1
      TEXT="$NEWSTR
$CONTENT"
      LT_DIR="$(dirname "$FILE")"
    fi ;;
  Bash)
    # Prefilter: no mention of the ledger's basename anywhere -> nothing to weigh,
    # and no lexer process for the overwhelming majority of Bash calls.
    if printf '%s' "$CMD" | grep -qaF 'ISSUES.md'; then
      # ARMED does one job: it widens the ledger match to a BARE `ISSUES.md`
      # basename (norm() below, and $LP on the regex leg). That widening is only
      # sound when the anchor IS the project root — there, a bare ISSUES.md in a
      # command is the ledger. After a walk-up it is not: cwd moved to the
      # toplevel while the command was written against a subpackage, so every
      # path ending in ISSUES.md anywhere in the tree became the ledger, whether
      # or not it exists. Measured against v0.14.1: rc 0 there, rc 2 here, on a
      # file belonging to an unrelated project (review F2) — and a false deny is
      # what this file's header calls its most expensive failure mode, printed
      # with an accusation aimed at a model doing correct work.
      # Full `docs/looptesting/ISSUES.md` suffixes are NOT conditioned on ARMED
      # and still match from anywhere, which is what K-14 needed.
      ARMED=0
      if [ "$LT_WALKED" = 0 ] && [ -f docs/looptesting/.active ]; then ARMED=1; fi
      # ---- primary leg: lex, then compare operand TOKENS to the ledger path ----
      # No expansion, no execution, no grammar: shlex hands back shell operators as
      # their own tokens and quoted text as one token, which is exactly the
      # structure the decision needs. `grep -n … ISSUES.md 2>/dev/null` lexes to
      # (grep)(-n)(pat)(ledger)(2)(>)(/dev/null): the redirect target is /dev/null
      # and the ledger is a READ operand of grep. No regex over the raw string can
      # draw that line, which is how H-01 happened.
      LEXED=""
      if command -v python3 >/dev/null 2>&1; then
        LEXED=$(printf '%s' "$CMD" | LG_ARMED="$ARMED" python3 -c '
import sys,os,re,shlex,posixpath
try:
    cmd=sys.stdin.read()
    if len(cmd)>8192:
        print("LG_CAPPED=1"); sys.exit(0)  # too long to lex -> regex leg
    LED="docs/looptesting/ISSUES.md"
    armed=os.environ.get("LG_ARMED")=="1"
    def norm(t):
        x=t
        while x.startswith("./"): x=x[2:]
        if x==LED or x.endswith("/"+LED): return True
        if armed and (x=="ISSUES.md" or x.endswith("/ISSUES.md")): return True
        return False
    def unres(t):
        # `[` matters as much as `*`: a bracket class SPLITS the literal name
        # (ISSUE[S].md), so unlike a star it hides the path from the regex leg too.
        return any(c in t for c in "$`*?[")
    def isip(f):
        if f=="--in-place" or f.startswith("--in-place="): return True
        if f.startswith("--"): return False
        return bool(re.match(r"^-[A-Za-z0-9]*i", f))
    lx=shlex.shlex(cmd, posix=True, punctuation_chars="();<>|&;\n")
    lx.whitespace_split=True
    lx.commenters=""                       # a sed s#a#b# script is not a comment
    # A newline SEPARATES commands; it is not whitespace between words. Treating
    # it as whitespace merged every line of a multi-line call into one segment,
    # so a bare VERIFIED from a neighbouring read became the text of a downgrade
    # on another line and the call was denied. Inside quotes it stays content.
    lx.whitespace=lx.whitespace.replace("\n","")
    toks=list(lx)
    PUNCT=set("();<>|&;\n")
    segs=[]; seps=[]; cur=[]; i=0; n=len(toks)
    while i<n:
        t=toks[i]
        if t and all(c in PUNCT for c in t):
            if ">" in t:
                cur.append(("redir", toks[i+1] if i+1<n else None)); i+=2; continue
            if "<" in t:
                # A here-string carries its CONTENT in the next token, so that
                # token is text being written, not a filename to skip. A heredoc
                # names a delimiter (its body follows as ordinary tokens) and a
                # plain `<` names a file: neither is content. All three mark the
                # segment as taking stdin from a redirect rather than a pipe.
                if t.endswith("<<<"):
                    if i+1<n: cur.append(("word", toks[i+1]))
                cur.append(("stdin", t))
                i+=2; continue
            segs.append(cur); seps.append(t); cur=[]; i+=1; continue
        cur.append(("word",t)); i+=1
    segs.append(cur); seps.append("")
    ASSIGN=re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
    WRAP={"command","env","nice","timeout","stdbuf","nohup","busybox","xargs",
          "setsid","ionice","chrt","sudo","doas","time"}
    VALFLAG={"-u","--unset","-n","--adjustment","-I","--replace","-L","-P","-s",
             "--signal","-d","-E","-a","-k","--kill-after","--max-args","-i","-o","-e"}
    W=IP=UN=0; text=[]; info=[]
    for seg in segs:
        words=[w for k,w in seg if k=="word"]
        j=0
        while j<len(words) and ASSIGN.match(words[j]): j+=1
        # Unwrap verb WRAPPERS. Each of these takes a command as its argument, so
        # the first word was the wrapper and the writer behind it was never
        # classified: `echo ROW | command tee -a ledger` wrote the row. Skip the
        # wrapper, its own flags (and the value of a flag that takes one), any
        # VAR=val it carries, and the leading duration of timeout. Best-effort by
        # design: if a skip goes wrong the verb simply fails to resolve to a
        # writer, which is the behaviour before unwrapping existed — never a new
        # deny. Bounded so a pathological line cannot spin.
        guard=0
        while j<len(words) and posixpath.basename(words[j]) in WRAP and guard<8:
            guard+=1
            w0=posixpath.basename(words[j]); j+=1
            while j<len(words):
                t0=words[j]
                if ASSIGN.match(t0): j+=1; continue
                if t0.startswith("-") and len(t0)>1:
                    j+=1
                    if t0 in VALFLAG and j<len(words): j+=1
                    continue
                if w0=="timeout" and re.match(r"^[0-9]+(\.[0-9]+)?[smhd]?$", t0):
                    j+=1; continue
                break
        verb=posixpath.basename(words[j]) if j<len(words) else ""
        rest=words[j+1:] if j<len(words) else []
        flags=[r for r in rest if r.startswith("-") and len(r)>1]
        ops=[r for r in rest if not (r.startswith("-") and len(r)>1)]
        w=ip=0
        for k,r in seg:
            if k!="redir" or r is None: continue
            if norm(r): w=1
            elif unres(r): UN=1
        if verb in ("tee","sponge"):
            for o in ops:
                # Both replace the whole file from stdin, so both reach every
                # existing row exactly as `sed -i` does and the no-ID rule has to
                # cover them. tee races its own pipeline (it truncates while the
                # upstream reads), but at any size the reader buffers in one go —
                # every real ledger — the race resolves for the writer and the
                # flip lands. Measured, not assumed.
                if norm(o): w=1; ip=1
                elif unres(o): UN=1
        if verb in ("sed","gsed","perl","ruby") and any(isip(f) for f in flags):
            for o in ops:
                if norm(o): w=1; ip=1
                elif unres(o): UN=1
        # A pure FILTER never turns its own arguments into file content: a grep
        # pattern, a sort key, a head count are all selectors. Widening the text
        # of a write to its pipeline would otherwise read `grep -v VERIFIED` as
        # the forgery it is removing — the ordinary way to drop verified rows,
        # drawing the accusation this design exists to avoid. Unknown verbs DO
        # contribute.
        FILTER=("grep","egrep","fgrep","rg","ag","ack","head","tail","sort",
                "uniq","cut","wc","cat","nl","tac","rev","column","comm","join")
        # AUDIT of the FILTER list for verbs that can be made to write a file.
        # sort takes `-o FILE` / `--output=FILE`; uniq takes an OUTPUT positional.
        # Both then replace that file exactly as sponge does. The rest carry no
        # file-output flag: grep/egrep/fgrep/rg/ag/head/tail/cut/wc/cat/nl/tac/
        # rev/column have none; `ack --output` and `join -o` are output FORMATS
        # printed to stdout, and `comm --output-delimiter` is a delimiter. A
        # filter that writes is not a filter for the row-dropping claim either.
        fw=[]
        if verb=="sort":
            # Walk `rest` IN ORDER: the target of a separated -o is the token
            # right after it, not every operand. Taking them all made the ledger
            # read as sort INPUT look like the write target and accused a read.
            k=0
            while k<len(rest):
                t1=rest[k]
                if t1 in ("-o","--output"):
                    if k+1<len(rest): fw.append(rest[k+1]); k+=2; continue
                elif t1.startswith("--output="): fw.append(t1.split("=",1)[1])
                elif t1.startswith("-o") and not t1.startswith("--") and len(t1)>2: fw.append(t1[2:])
                k+=1
        if verb=="uniq" and len(ops)>=2: fw.append(ops[-1])   # uniq IN OUT
        for o in fw:
            if norm(o): w=1; ip=1
            elif unres(o): UN=1
        stdin_redir=any(k=="stdin" for k,_ in seg)
        isfilter=(verb in FILTER) and not fw
        info.append((w,ip,[] if isfilter else ops,verb,isfilter,stdin_redir))
    # Text of a write = the operands of its whole PIPELINE, not of its own segment:
    # in `sed s/…/VERIFIED/ ledger | sponge ledger` the substitution sits one
    # segment upstream of the verb that writes. Only pipes join; `;` and `&&` do
    # not, so a plain READ standing next to a downgrade cannot supply forgery text.
    grp=[]; FO=0
    for k in range(len(segs)):
        grp.append(k)
        if seps[k] not in ("|","|&") or k==len(segs)-1:
            if any(info[m][0] for m in grp):
                W=1
                IP=IP or max(info[m][1] for m in grp)
                for m in grp: text.extend(info[m][2])
                # The row-dropping claim needs three things, not one. Every member
                # must be a filter or the writer; there must be a real filter
                # UPSTREAM of the writer; and the writer must take its input from
                # the pipe. A lone writer satisfied the first test vacuously —
                # `tee ledger <<< row` has no pipeline at all and drops nothing,
                # yet it was granted the claim and its row landed.
                upstream_filter=any(info[m][4] and not info[m][0] for m in grp)
                piped_writer=not any(info[m][0] and info[m][5] for m in grp)
                if upstream_filter and piped_writer and all(
                       info[m][4] or (info[m][0] and info[m][3] in ("tee","sponge"))
                       for m in grp): FO=1
            grp=[]
    print("LG_FILTERONLY=%d" % FO)
    print("LG_WRITE=%d" % W)
    print("LG_INPLACE=%d" % IP)
    print("LG_UNRESOLVED=%d" % UN)
    print("LG_TEXT=%s" % shlex.quote("\n".join(text)))
    print("LG_OK=1")
except Exception:
    # Unlexable (an unbalanced quote, a dangling escape). The shell very often
    # runs these anyway — an apostrophe inside a comment or a heredoc body is
    # ordinary English — so the caller falls back to the regex leg.
    print("LG_LEXFAIL=1")
' 2>/dev/null) || LEXED=""
      fi
      LG_OK=0; LG_WRITE=0; LG_INPLACE=0; LG_UNRESOLVED=0; LG_TEXT=""; LG_LEXFAIL=0; LG_CAPPED=0; LG_FILTERONLY=0
      case "$LEXED" in
        *LG_OK=1*|*LG_LEXFAIL=1*|*LG_CAPPED=1*) eval "$LEXED" 2>/dev/null || LG_OK=0 ;;
      esac

      INTRO_TEXT="$CMD"
      if [ "$LG_OK" = "1" ] && [ "$LG_WRITE" = "1" ]; then
        TARGETS_LEDGER=1
        INTRO_TEXT="$LG_TEXT"
        [ "$LG_INPLACE" = "1" ] && INPLACE=1
      fi
      # ---- fallback leg: no python3, lexer refused, capped, or an unresolved
      # target. Weaker (its in-place arm still wants the flag and the path in one
      # unbroken span) but target-bound, so it never denies a plain read.
      # Routing here is by MECHANISM, not by shape: any lexer exception lands on
      # this leg, whatever raised it. This leg matches the raw string, so it never
      # needs to know why the lexer gave up — which is why an unenumerated way of
      # confusing the lexer cannot become an escape.
      # A command the lexer rejects is FREQUENTLY still a command the shell runs:
      # clearing `commenters` is what lets a hash-delimited sed script through,
      # and it also makes an apostrophe in a trailing comment or a heredoc body
      # read as an unbalanced quote. `… >> ISSUES.md # it's fine` and a heredoc
      # whose body says "doesn't repro" both throw here and both really append.
      # So a lex failure comes here rather than being allowed outright. ----
      if [ "$TARGETS_LEDGER" -eq 0 ] \
         && { [ "$LG_OK" != "1" ] || [ "$LG_LEXFAIL" = "1" ] || [ "$LG_CAPPED" = "1" ] || [ "$LG_UNRESOLVED" = "1" ]; }; then
        if [ "$ARMED" = "1" ]; then LP='(docs/looptesting/)?ISSUES\.md'; else LP='docs/looptesting/ISSUES\.md'; fi
        WB='(^|[^[:alnum:]_])'
        # Whole-token match: ISSUES.md.bak is a different file (`\b` is avoided —
        # BSD grep does not honor it, audit H-07).
        TGT="[\"']?[^[:space:]|;&<>\"']*${LP}([[:space:]\"';&|<>)]|\$)"
        if printf '%s' "$CMD" | grep -qaE "${WB}(sed|gsed|perl|ruby)[[:space:]]+([^;&]*[[:space:]]+)?(-[[:alnum:]]*i[^[:space:]]*|--in-place[^[:space:]]*)([^;&]*[[:space:]]+)?${TGT}"; then
          TARGETS_LEDGER=1; INPLACE=1
        elif printf '%s' "$CMD" | grep -qaE "[0-9]*>>?[[:space:]]*${TGT}|${WB}(tee|sponge)([[:space:]]+-[^[:space:]]+)*[[:space:]]+${TGT}"; then
          TARGETS_LEDGER=1
        fi
      fi
      if [ "$TARGETS_LEDGER" -eq 1 ]; then
        TEXT="$CMD"
        LT_DIR="docs/looptesting"
      fi
    fi ;;
esac

[ "$TARGETS_LEDGER" -eq 1 ] || exit 0

# Does the introduced text set a genuine VERIFIED status token? Match case-
# sensitively — the status token is always uppercase, and `-i` false-DENIED prose
# like "not yet verified" / "could not be VERIFIED" in an OPEN issue's title (HK-2).
# For a file write the ledger row is `### ISSUE-NNN | Pn | STATUS | title`, so the
# status token is anchored to the STATUS column (after a `|`, or the whole minimal
# `FIXED_UNVERIFIED`->`VERIFIED` edit) — a bare "VERIFIED" in the free-text title
# column must NOT trip it, and *_UNVERIFIED (preceded by `_`, not `|`) is excluded.
# For a Bash command VERIFIED can appear in sed/perl substitution syntax
# (s/OPEN/VERIFIED/) rather than a column, so keep a word-boundary match there.
if [ "$TOOL" = "Bash" ]; then
  VLINES=$(printf '%s\n' "$TEXT" | grep -awE 'VERIFIED') || exit 0
else
  STATUS_RE='(^|\|)[[:space:]]*VERIFIED[[:space:]]*($|\|)'
  VLINES=$(printf '%s\n' "$TEXT" | grep -aE "$STATUS_RE") || exit 0
fi

# Which ISSUE is being marked? The ID is the ledger row's LEADING column
# (`### ISSUE-NNN | …`), never an ID cited in the free-text title — a legitimate
# "dup of ISSUE-002" title used to be checked against ISSUE-002's footprint and
# false-denied (audit H-05). Resolution order, first non-empty wins:
#   1. header-form IDs on the VERIFIED lines being introduced;
#   2. header-form IDs in the edit's old_string;
#   3. the ISSUE header enclosing old_string's first line in the target ledger
#      (the minimal "FIXED_UNVERIFIED" -> "VERIFIED" edit carries no ID at all);
#   4. any ID on the VERIFIED lines, then any ID in old_string — for shapes with
#      no row header, e.g. `perl -i -pe 's/OPEN/VERIFIED/ if /ISSUE-014/'`.
# Best-effort — an unresolvable ID falls through to allow (documented residual),
# except for the in-place shape below.
HDR_RE='###[[:space:]]*ISSUE-[0-9]+'
IDS=$(printf '%s\n' "$VLINES" | grep -aoE "$HDR_RE" | grep -aoE 'ISSUE-[0-9]+' | sort -u)
if [ -z "$IDS" ]; then
  IDS=$(printf '%s\n' "$OLDSTR" | grep -aoE "$HDR_RE" | grep -aoE 'ISSUE-[0-9]+' | sort -u)
fi
if [ -z "$IDS" ] && [ "$TOOL" != "Bash" ] && [ -f "$FILE" ]; then
  anchor=$(printf '%s\n' "$OLDSTR" | grep -m1 -a . || true)
  if [ -n "$anchor" ]; then
    ln=$(grep -naF -- "$anchor" "$FILE" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -n "$ln" ]; then
      IDS=$(head -n "$ln" "$FILE" | grep -aoE '^### ISSUE-[0-9]+' | grep -aoE 'ISSUE-[0-9]+' | tail -1)
    fi
  fi
fi
# Steps 4-5 are Bash-only: a shell one-liner has no row header to read
# (`perl -i -pe 's/OPEN/VERIFIED/ if /ISSUE-014/'`), so a bare ID is the best
# available anchor. For an Edit they would re-open exactly the H-05 shape this
# fix closes — a title-cited ID becoming the checked one whenever the file
# lookup above misses — so an unresolvable Edit falls through to allow instead.
if [ -z "$IDS" ] && [ "$TOOL" = "Bash" ]; then
  IDS=$(printf '%s\n' "$VLINES" | grep -aoE 'ISSUE-[0-9]+' | sort -u)
fi
if [ -z "$IDS" ] && [ "$TOOL" = "Bash" ]; then
  IDS=$(printf '%s\n' "$OLDSTR" | grep -aoE 'ISSUE-[0-9]+' | sort -u)
fi

RUNS_DIR="$LT_DIR/runs"
deny() {
  {
    echo "loop-testing ledger-gate DENIED: $1"
    echo "An ISSUE may become VERIFIED only by REPLAYING its reproduction steps,"
    echo "with the replay (command + output) recorded this round in"
    echo "$RUNS_DIR/round-N.md (references/issue-rules.md §7). No such replay"
    echo "record exists for the ID(s) above. Reproduce, record the replay in the"
    echo "round log, THEN set VERIFIED. Weakening/faking verification is a red line."
    echo "(Human escape hatch: LOOP_TESTING_DISABLE_LEDGER_GATE=1.)"
  } >&2
  exit 2
}

# An in-place substitution on the ledger that introduces VERIFIED and names NO
# ISSUE-ID (`sed -i 's/FIXED_UNVERIFIED/VERIFIED/' …ISSUES.md`) can flip every
# pending row at once and used to pass at zero cost because the ID was simply
# unresolvable (audit H-04). It must say which ISSUE it verifies.
#
# The rule is conditioned on VERIFIED being on the REPLACEMENT side. Taking a row
# back to OPEN (`s/VERIFIED/OPEN/`) or dropping it (`/VERIFIED/d`) is what the
# protocol says to do when a re-verification fails, and denying that — with the
# red-line accusation, no less — is a false accusation at correct work. Strip the
# MATCH positions (the LHS of each s/// and each /…/ address that holds the
# token), then ask whether VERIFIED survives; a replacement-side VERIFIED has no
# opening delimiter left in front of it, so it always does.
introduces_verified() {
  local x d
  d=$(printf '\001')   # a delimiter no shell command carries, so sed needs no escaping
  # Rewrite each `s<D>LHS<D>RHS<D>` to just its RHS, fenced by spaces. Keeping the
  # replacement (rather than deleting the match side) is what makes this safe: a
  # half-stripped substitution leaves its closing delimiter behind, and the next
  # pass then reads `…/ VERIFIED/…` as an address and drops a real forgery.
  # A DIGIT may precede the verb: `2s/…/…/`, `0s/…/…/`, `1,$s/…/…/` are addresses,
  # not words. Leaving them out left the substitution unrecognised, and the
  # address rule below then swallowed its replacement as a match position.
  x=$(printf '%s' "$1" | sed -E \
    -e "s${d}(^|[^A-Za-z_])(tr|[sy])/([^/]*)/([^/]*)/${d} \\4 ${d}g" \
    -e "s${d}(^|[^A-Za-z_])(tr|[sy])#([^#]*)#([^#]*)#${d} \\4 ${d}g" \
    -e "s${d}(^|[^A-Za-z_])(tr|[sy]),([^,]*),([^,]*),${d} \\4 ${d}g" \
    -e "s${d}(^|[^A-Za-z_])(tr|[sy])\\|([^|]*)\\|([^|]*)\\|${d} \\4 ${d}g" \
    -e "s${d}/[^/]*VERIFIED[^/]*/([dp!},]|['\"]|\$)${d} ${d}g" \
    -e "s${d}#[^#]*VERIFIED[^#]*#([dp!},]|['\"]|\$)${d} ${d}g" \
    2>/dev/null) || x="$1"
  printf '%s\n' "$x" | grep -qawE 'VERIFIED'
}

# `removes_verified`: the text mentions VERIFIED, and every mention is a match
# position. That is what a downgrade or a deletion LOOKS like, and it is the only
# thing that earns the early exit. Not finding forgery text is NOT the same
# claim: the pipeline grouping guarantees shapes where the written text sits
# outside the write group — `{ cat ledger; echo '…VERIFIED…'; } | tee ledger`
# splits on `;`, so the write group holds only the path — and reading that
# silence as "therefore a downgrade" let the row land.
removes_verified() {
  printf '%s\n' "$1" | grep -qawE 'VERIFIED' && ! introduces_verified "$1"
}

if [ "$INPLACE" -eq 1 ]; then
  if introduces_verified "$INTRO_TEXT"; then
    : # a forgery in plain sight -> the ID rule below, then the footprint check
  elif [ "$LG_FILTERONLY" = "1" ]; then
    exit 0   # every member of the pipeline is a filter: it can only DROP rows
  elif removes_verified "$INTRO_TEXT"; then
    exit 0   # VERIFIED appears, only ever on the match side: a downgrade
  fi
  # Either a forgery, or a write whose text we could not place. Both have to name
  # the ISSUE they verify; an unresolvable one is no longer assumed benign.
  if [ -z "$IDS" ]; then
    deny "an in-place write to ISSUES.md that introduces VERIFIED must name the ISSUE-ID it verifies (e.g. '/ISSUE-NNN/s/FIXED_UNVERIFIED/VERIFIED/')."
  fi
fi

[ -n "$IDS" ] || exit 0   # nothing marked VERIFIED, or ID unresolvable -> allow

# Deny if a to-be-VERIFIED ID has zero footprint across all round logs.
# The ID must appear as a WHOLE id: a substring match let a truncated one ride on
# a longer sibling, so ISSUE-01 passed on ISSUE-012's replay record.
missing=""
for id in $IDS; do
  if ! grep -rqaE "(^|[^A-Za-z0-9_-])${id}([^0-9]|\$)" "$RUNS_DIR" 2>/dev/null; then
    missing="$missing $id"
  fi
done

if [ -n "$missing" ]; then
  deny "marking$missing VERIFIED in ISSUES.md with no replay record in any $RUNS_DIR/round-*.md."
fi

exit 0

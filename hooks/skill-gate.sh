#!/bin/bash
# Skill gate, two PreToolUse hooks in one script:
#   skill-gate.sh          (matcher: Skill) scans a skill with SkillSpector on first use and whenever its
#                          contents change. Blocks HIGH/CRITICAL findings (remembered, so retries are refused
#                          instantly) and scans that fail or time out.
#   skill-gate.sh --guard  (matcher: file and Bash tools) denies access to blocked skills' files and asks you
#                          before Claude touches the gate script or its ledger.
# Approve a reviewed skill (only works from your own terminal, not from Claude's Bash):
#   skill-gate.sh --approve <path-to-skill-dir>
set -u
LEDGER="$HOME/.claude/skill-scan-ledger.json"
SELF="$HOME/.claude/hooks/skill-gate.sh"
SS="${SKILLSPECTOR_BIN:-$HOME/.local/bin/skillspector}"
SCAN_TIMEOUT="${SKILL_GATE_SCAN_TIMEOUT:-540}"
[ -f "$LEDGER" ] || echo '{}' > "$LEDGER"

hash_dir() { (cd "$1" && find . -type f -not -path './.git/*' | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1); }
# record <hash> <dir> <status: approved|blocked> <severity> [findings]
record() {
  local t; t=$(mktemp)
  jq --arg h "$1" --arg d "$2" --arg st "$3" --arg s "$4" --arg f "${5:-}" \
    '.[$h]={dir:$d,status:$st,severity:$s,findings:$f,at:(now|todate)}' "$LEDGER" > "$t" && mv "$t" "$LEDGER"
}
approve_cmd() { printf '~/.claude/hooks/skill-gate.sh --approve %q' "$1"; }
# decide <allow-reason-for-claude> <message-for-user> [deny|ask]
decide() {
  jq -n --arg r "$1" --arg m "$2" --arg d "${3:-deny}" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r},systemMessage:$m}' \
    || { echo "$1" >&2; exit 2; }
  exit 0
}
# block <skill> <dir> <why> <findings>: deny with the copyable approve command for the user
block() {
  local cmd; cmd=$(approve_cmd "$2")
  decide "skill-gate blocked skill '$1': $3. Do not retry this skill, read its files, or try to approve it yourself; approval only works from the user's own terminal. Tell the user it was blocked and give them this command to run after they have reviewed the skill: $cmd" \
"skill-gate blocked skill '$1' ($2): $3.${4:+
$4}
If you have reviewed it and trust this exact version, run in your own terminal:
  $cmd"
}

if [ "${1:-}" = "--approve" ]; then
  d="${2:?usage: skill-gate.sh --approve <skill-dir>}"
  [ -d "$d" ] || { echo "not a directory: $d" >&2; exit 1; }
  # Claude's Bash has no terminal, so requiring one keeps approval in the user's hands.
  if ! { exec 3</dev/tty; } 2>/dev/null; then echo "skill-gate: --approve must be run by you in a terminal" >&2; exit 1; fi
  d=$(cd "$d" && pwd); h=$(hash_dir "$d")
  jq -r --arg h "$h" '.[$h] // empty | "Current status: \(.status // "approved") (\(.severity)) since \(.at)\n\(.findings // "")"' "$LEDGER"
  printf 'Approve this exact version of %s? Type APPROVE: ' "$d" > /dev/tty
  read -r ans <&3
  [ "$ans" = "APPROVE" ] || { echo "not approved"; exit 1; }
  record "$h" "$d" approved manual; echo "approved $d"; exit 0
fi

input=$(cat)

if [ "${1:-}" = "--guard" ]; then
  tool=$(jq -r '.tool_name // empty' <<<"$input")
  targets=$(jq -r '.tool_input | [.file_path, .notebook_path, .path, ((.path // "") + "/" + (.pattern // "")), .pattern, .command] | map(select(. != null)) | .[]' <<<"$input")
  [ -n "$targets" ] || exit 0
  tilde() { printf '~%s' "${1#"$HOME"}"; }
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    # Judge the folder's current contents: once blocked, it stays off limits until this exact version is approved.
    [ "$(jq -r --arg h "$(hash_dir "$d")" '.[$h].status // "unscanned"' "$LEDGER")" = "approved" ] && continue
    if grep -qF -e "$d" -e "$(tilde "$d")" <<<"$targets"; then
      cmd=$(approve_cmd "$d")
      decide "skill-gate: '$d' holds a blocked skill; its files must not be read, run or changed. Tell the user; after review they can approve it with: $cmd" \
"skill-gate denied $tool access to blocked skill folder $d.
To trust it after review, run in your own terminal:
  $cmd"
    fi
  done < <(jq -r '[.[] | select(.status == "blocked") | .dir] | unique | .[]' "$LEDGER")
  # Matches the live install however it is spelled ($HOME/..., ~/..., /Users/...), not copies elsewhere.
  if [ "$tool" != "Read" ] && grep -qF -e ".claude/skill-scan-ledger.json" -e ".claude/hooks/skill-gate.sh" <<<"$targets"; then
    decide "Touching the skill gate's script or ledger needs the user's confirmation." \
      "Claude wants to use $tool on the skill gate's script or ledger." ask
  fi
  exit 0
fi

name=$(jq -r '.tool_input.skill // empty' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
[ -n "$name" ] || exit 0
short="${name##*:}"

dir=""
for c in "$cwd/.claude/skills/$short" "$HOME/.claude/skills/$short"; do
  [ -f "$c/SKILL.md" ] && { dir="$c"; break; }
done
if [ -z "$dir" ] && [ -d "$HOME/.claude/plugins" ]; then
  f=$(find "$HOME/.claude/plugins" -path "*/skills/$short/SKILL.md" 2>/dev/null | head -1)
  [ -n "$f" ] && dir=$(dirname "$f")
fi
if [ -z "$dir" ]; then
  # Not on disk: bundled/built-in skill shipped inside Claude Code, nothing installable to scan.
  echo "skill-gate: '$name' has no skill directory on disk (built-in?); not scanned" >&2
  exit 0
fi
dir=$(cd "$dir" && pwd)

h=$(hash_dir "$dir")
st=$(jq -r --arg h "$h" '.[$h] // empty | .status // "approved"' "$LEDGER")
[ "$st" = "approved" ] && exit 0
if [ "$st" = "blocked" ]; then
  at=$(jq -r --arg h "$h" '.[$h].at' "$LEDGER"); fnd=$(jq -r --arg h "$h" '.[$h].findings' "$LEDGER")
  block "$name" "$dir" "this exact version was already blocked on $at (not rescanned)" "$fnd"
fi

[ -x "$SS" ] || block "$name" "$dir" "skillspector not found at $SS, so it cannot be scanned" ""
out=$(mktemp)
trap 'rm -f "$out"' EXIT
# LLM analysis via the local Claude Code binary (no API key). Runs under a limit shorter than the
# hook's own timeout, so a slow scan produces no report and blocks below rather than timing out the hook.
CLAUDE_BIN=$(command -v claude || find "$HOME/Library/Application Support/Claude/claude-code" -path '*claude.app/Contents/MacOS/claude' -type f 2>/dev/null | sort -V | tail -1)
[ -n "$CLAUDE_BIN" ] || block "$name" "$dir" "claude binary not found, so the LLM scan is impossible" ""
PATH="$(dirname "$CLAUDE_BIN"):$PATH" SKILLSPECTOR_PROVIDER=claude_cli timeout "$SCAN_TIMEOUT" "$SS" scan "$dir" --format json --output "$out" >/dev/null 2>&1
ok=$(jq -r '.execution_successful // false' "$out" 2>/dev/null)
sev=$(jq -r '.risk_assessment.max_issue_severity // "UNKNOWN"' "$out" 2>/dev/null)
findings=$(jq -r '.issues[]? | select(.severity=="HIGH" or .severity=="CRITICAL") | "- [\(.severity)] \(.category) \(.location.file):\(.location.start_line // "?") \(.pattern)"' "$out" 2>/dev/null)
if [ "$ok" != "true" ]; then
  # Not remembered as blocked: a failed scan may succeed next time.
  why="the scan did not complete"
  llm=$(jq -r '.metadata.llm_error // empty' "$out" 2>/dev/null)
  [ -n "$llm" ] && why="$why ($llm If claude is not logged in, run: \"$CLAUDE_BIN\" auth login)"
  [ -s "$out" ] || why="$why (no report: error or ${SCAN_TIMEOUT}s limit reached)"
  block "$name" "$dir" "$why" "$findings"
fi
case "$sev" in
  HIGH|CRITICAL)
    record "$h" "$dir" blocked "$sev" "$findings"
    block "$name" "$dir" "SkillSpector found $sev issues" "$findings" ;;
  *) record "$h" "$dir" approved "$sev"; echo "skill-gate: scanned '$name' (max severity $sev), approved" >&2; exit 0 ;;
esac

#!/usr/bin/env bash
# Keep a TestFlight build of Trio current, without uploading on its own.
#
#   trio-autobuild.sh check    # run by launchd weekly (Sun 04:00): build if needed, then notify
#   trio-autobuild.sh upload   # upload the archive `check` built (you run this)
#   trio-autobuild.sh status   # last upload, pending archive, origin/main
#
# Notifications go to Telegram via $STATE_DIR/telegram.env (copied from watchtower on m2).
# `check` builds our patch branch ($PATCH_BRANCH on the fork) with upstream main merged in,
# in a clone it owns ($CLONE), when upstream main or the patches changed since the last
# upload, or when the last upload is older than $MAX_AGE_DAYS (TestFlight builds expire
# after 90 days). A merge conflict is reported, never built. After a successful build the
# merge is pushed to the fork (a plain push, never forced). The build is then uploaded to
# TestFlight (AUTO_UPLOAD=0 builds only, and leaves the upload to `trio-autobuild.sh upload`).
#
# A build is identified as "<upstream sha>:<patch id>", where the patch id covers the diff
# between upstream main and the build, so merging alone does not look like new patches.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

HERE="$(cd "$(dirname "$0")" && pwd)"
CLONE="${CLONE:-$HOME/repo/Trio-autobuild}"
REMOTE="${REMOTE:-https://github.com/nightscout/Trio.git}"
BRANCH="${BRANCH:-main}"
FORK="${FORK:-git@github.com:yhorie/Trio.git}"
PATCH_BRANCH="${PATCH_BRANCH:-yh/main}"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-60}"
AUTO_UPLOAD="${AUTO_UPLOAD:-1}"
export STATE_DIR="${STATE_DIR:-$HOME/Library/Application Support/trio-autobuild}"
OUT="$CLONE/build/testflight"
mkdir -p "$STATE_DIR"

log() { echo "$(date '+%F %T') $*"; }
notify() {  # notify <title> <message> — Telegram, same TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_IDS convention as the other bots
  log "$1: $2"
  local env="$STATE_DIR/telegram.env" token chats chat
  if [[ ! -f "$env" ]]; then
    log "No $env; notification not sent."
    return 0
  fi
  token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$env" | tr -d '"'"'")
  chats=$(sed -n 's/^TELEGRAM_CHAT_IDS=//p' "$env" | tr -d '"'"' ")
  for chat in ${chats//,/ }; do
    curl -fsS --max-time 20 "https://api.telegram.org/bot$token/sendMessage" \
      --data-urlencode "chat_id=$chat" --data-urlencode "text=$1"$'\n'"$2" >/dev/null \
      || log "Telegram send to $chat failed."
  done
}

lock() {  # one build or upload at a time; they share the clone's DerivedData
  local pid
  if ! mkdir "$STATE_DIR/lock" 2>/dev/null; then
    pid=$(cat "$STATE_DIR/lock/pid" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      log "Another trio-autobuild run (pid $pid) is in progress; skipping."
      exit 0
    fi
    log "Clearing stale lock left by pid ${pid:-unknown}."
    rm -rf "$STATE_DIR/lock"
    mkdir "$STATE_DIR/lock"
  fi
  echo $$ > "$STATE_DIR/lock/pid"
  trap 'rm -rf "$STATE_DIR/lock"' EXIT
}

read_last_upload() {  # sets LAST_SHA LAST_TS LAST_VERSION LAST_BUILD
  LAST_SHA="" LAST_TS=0 LAST_VERSION="" LAST_BUILD=""
  [[ -f "$STATE_DIR/last-upload" ]] && read -r LAST_SHA LAST_TS LAST_VERSION LAST_BUILD < "$STATE_DIR/last-upload"
  return 0
}

patch_id() {  # patch_id <upstream> <rev>: id of what <rev> changes on top of <upstream>
  local id
  id=$(git -C "$CLONE" diff "$1" "$2" | git -C "$CLONE" patch-id --stable | cut -c1-12)
  echo "${id:-none}"
}

pending_sha() { [[ -d "$OUT/Trio.xcarchive" && -f "$OUT/commit" ]] && cat "$OUT/commit" || true; }

explain_failure() {  # explain_failure <log file>...
  if grep -qs errSecInternalComponent "$@"; then
    notify "Trio build failed" "Login keychain is locked. Unlock it and run: trio-autobuild.sh check"
  else
    notify "Trio build failed" "See $STATE_DIR/check.log and $OUT/archive.log"
  fi
}

cmd_check() {
  lock
  if [[ ! -d "$CLONE/.git" ]]; then
    log "Cloning $REMOTE into $CLONE"
    git clone --quiet --branch "$BRANCH" "$REMOTE" "$CLONE"
  fi
  git -C "$CLONE" remote get-url fork >/dev/null 2>&1 || git -C "$CLONE" remote add fork "$FORK"
  git -C "$CLONE" fetch --quiet origin "$BRANCH"
  git -C "$CLONE" fetch --quiet fork "$PATCH_BRANCH"
  local upstream patches key
  upstream=$(git -C "$CLONE" rev-parse "origin/$BRANCH")
  patches=$(git -C "$CLONE" rev-parse "fork/$PATCH_BRANCH")
  key="$upstream:$(patch_id "$(git -C "$CLONE" merge-base "$upstream" "$patches")" "$patches")"
  read_last_upload

  local age_days=$(( ($(date +%s) - LAST_TS) / 86400 ))
  local reason=""
  if [[ "${LAST_SHA%%:*}" != "$upstream" ]]; then
    reason="main moved to ${upstream:0:9}"
  elif [[ "$key" != "$LAST_SHA" ]]; then
    reason="$PATCH_BRANCH changed"
  elif (( age_days >= MAX_AGE_DAYS )); then
    reason="last upload is $age_days days old"
  else
    log "Up to date: ${upstream:0:9} + $PATCH_BRANCH uploaded $age_days days ago."
    return 0
  fi

  if [[ "$(pending_sha)" == "$key" ]]; then
    if [[ "$AUTO_UPLOAD" == 1 ]]; then
      log "Uploading the build a previous run left (its upload failed or was skipped)."
      upload_existing
    else
      notify "Trio build waiting" "${upstream:0:9} + $PATCH_BRANCH is built ($reason). Upload with: trio-autobuild.sh upload"
    fi
    return
  fi

  log "Building ${upstream:0:9} + $PATCH_BRANCH (${patches:0:9}): $reason"
  git -C "$CLONE" checkout --quiet --force --detach "$patches"
  if ! git -C "$CLONE" merge-base --is-ancestor "$upstream" HEAD; then
    if ! git -C "$CLONE" merge --quiet --no-edit -m "Merge $BRANCH ${upstream:0:9} into $PATCH_BRANCH" "$upstream"; then
      local files; files=$(git -C "$CLONE" diff --name-only --diff-filter=U | tr '\n' ' ')
      git -C "$CLONE" merge --abort
      notify "Trio merge conflict" "$PATCH_BRANCH conflicts with main ${upstream:0:9} in: $files. Merge it by hand and push to the fork."
      return 1
    fi
  fi
  git -C "$CLONE" submodule sync --quiet --recursive
  git -C "$CLONE" submodule update --quiet --init --recursive --force

  if ! TRIO_DIR="$CLONE" BUILD_ID="$key" UPLOAD="$AUTO_UPLOAD" "$HERE/testflight.sh"; then
    explain_failure "$OUT/archive.log" "$OUT/export.log"
    return 1
  fi

  if [[ "$(git -C "$CLONE" rev-parse HEAD)" != "$patches" ]]; then
    if git -C "$CLONE" push --quiet fork "HEAD:refs/heads/$PATCH_BRANCH"; then
      log "Pushed the merge to fork/$PATCH_BRANCH."
    else
      log "Could not push the merge to fork/$PATCH_BRANCH; the build is fine, the fork is just behind."
    fi
  fi

  local version build changes last_upstream="${LAST_SHA%%:*}"
  version=$(plutil -extract CFBundleShortVersionString raw "$OUT/Trio.xcarchive/Products/Applications/Trio.app/Info.plist")
  build=$(plutil -extract CFBundleVersion raw "$OUT/Trio.xcarchive/Products/Applications/Trio.app/Info.plist")
  if [[ -n "$last_upstream" && "$last_upstream" != "$upstream" ]] && git -C "$CLONE" cat-file -e "$last_upstream" 2>/dev/null; then
    changes="$(git -C "$CLONE" rev-list --count --no-merges "$last_upstream..$upstream") new upstream commits merged into $PATCH_BRANCH"
  else
    changes="$reason"
  fi
  if [[ "$AUTO_UPLOAD" == 1 ]]; then
    notify "Trio $version ($build) uploaded" "$changes. Install from TestFlight once Apple finishes processing."
  else
    notify "Trio $version ($build) ready" "$changes. Upload with: trio-autobuild.sh upload"
  fi
}

upload_existing() {  # caller holds the lock
  if TRIO_DIR="$CLONE" UPLOAD_EXISTING=1 "$HERE/testflight.sh"; then
    read_last_upload
    notify "Trio uploaded" "$LAST_VERSION ($LAST_BUILD) from ${LAST_SHA:0:9} + $PATCH_BRANCH; install from TestFlight once it finishes processing"
  else
    explain_failure "$OUT/export.log"
    return 1
  fi
}

cmd_upload() {
  lock
  upload_existing
}

cmd_status() {
  read_last_upload
  if [[ -n "$LAST_SHA" ]]; then
    echo "Last upload:  $LAST_VERSION ($LAST_BUILD) from ${LAST_SHA:0:9}, $(( ($(date +%s) - LAST_TS) / 86400 )) days ago"
  else
    echo "Last upload:  none recorded"
  fi
  local p; p=$(pending_sha)
  [[ "$p" == "$LAST_SHA" ]] && p=""  # already uploaded
  if [[ -n "$p" ]]; then echo "Pending:      ${p:0:9} archived, waiting for upload"; else echo "Pending:      nothing"; fi
  [[ -d "$CLONE/.git" ]] && echo "origin/$BRANCH: $(git -C "$CLONE" log -1 --format='%h %ad %s' --date=short "origin/$BRANCH")"
  git -C "$CLONE" rev-parse -q --verify "fork/$PATCH_BRANCH" >/dev/null 2>&1 \
    && echo "$PATCH_BRANCH: $(git -C "$CLONE" rev-list --count --no-merges "origin/$BRANCH..fork/$PATCH_BRANCH") commits on top of $BRANCH"
  local pid; pid=$(cat "$STATE_DIR/lock/pid" 2>/dev/null || true)
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && echo "Running:      pid $pid (check or upload)"
  return 0
}

case "${1:-check}" in
  # Not `cmd_check | tee`: bash 3.2 never fires the lock's EXIT trap inside a pipeline.
  check)  exec > >(tee -a "$STATE_DIR/check.log") 2>&1; cmd_check ;;
  upload) cmd_upload ;;
  status) cmd_status ;;
  *) echo "usage: $0 [check|upload|status]" >&2; exit 2 ;;
esac

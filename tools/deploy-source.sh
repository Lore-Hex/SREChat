#!/usr/bin/env bash
# Ship source to one region and rebuild it.
#
#   tools/deploy-source.sh <ssh-key> <user@host> [label]
#
# Why this exists rather than `tar x` in place: extracting over the existing
# tree only ADDS and OVERWRITES — it never removes a file that was deleted
# upstream. A stale lib/sre_chat/store/config.ex survived every deploy that way,
# defining SREChat.Config a second time. Elixir compiled both, the orphan won
# ("warning: redefining module SREChat.Config"), and the release shipped a
# Config module missing every function added to the real file. That took /me —
# the sign-in endpoint — down across all three regions with an
# UndefinedFunctionError, from source that was byte-identical to local. A
# --no-cache rebuild did not help, because the source really was being compiled;
# it was just being overwritten afterwards.
#
# So: stage, validate, swap. The tree on the host ends up exactly matching the
# tree here, with no survivors.
set -euo pipefail

KEY="${1:?usage: deploy-source.sh <ssh-key> <user@host> [label]}"
TARGET="${2:?usage: deploy-source.sh <ssh-key> <user@host> [label]}"
LABEL="${3:-$TARGET}"

SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o ConnectTimeout=10 -o LogLevel=ERROR -i "$KEY")

# COPYFILE_DISABLE stops macOS tar from emitting ._ AppleDouble files, which
# land in lib/ as ._foo.ex — files the Elixir compiler will happily try to read.
COPYFILE_DISABLE=1 tar czf - lib priv config mix.exs mix.lock Dockerfile agent 2>/dev/null \
  | "${SSH[@]}" "$TARGET" '
    set -euo pipefail
    cd ~/RoachChat
    rm -rf .stage && mkdir .stage && cd .stage
    cat > src.tgz && tar xzf src.tgz && rm src.tgz

    # Refuse to swap in a tree that is obviously broken or truncated.
    test -f lib/sre_chat/config.ex
    test -f lib/sre_chat_web/api_router.ex
    test -d priv/web

    # One file per module, or the compiler silently picks a winner.
    dupes=$(grep -rl "defmodule SREChat.Config" lib/ | wc -l)
    test "$dupes" -eq 1 || { echo "ABORT: SREChat.Config defined in $dupes files"; exit 1; }

    cd ~/RoachChat
    for d in lib priv config agent; do rm -rf "$d" && mv ".stage/$d" "$d"; done
    mv .stage/mix.exs .stage/mix.lock .stage/Dockerfile .
    rm -rf .stage
    find . -name "._*" -delete
  '
echo "$LABEL: source replaced"

"${SSH[@]}" "$TARGET" '
  set -euo pipefail
  cd ~/RoachChat/deploy
  sudo docker compose -f docker-compose.prod.yml build app > /tmp/build.log 2>&1

  # A duplicate module is a silent correctness bug, not a warning to skim past.
  if grep -q "redefining module" /tmp/build.log; then
    echo "ABORT: build redefined a module — a stale orphan is still present"
    grep "redefining module" /tmp/build.log | head -3
    exit 1
  fi

  sudo docker compose -f docker-compose.prod.yml up -d app 2>&1 | tail -1
'
echo "$LABEL: rebuilt and running"

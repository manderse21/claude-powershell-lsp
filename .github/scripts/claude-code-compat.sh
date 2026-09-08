#!/usr/bin/env bash
# claude-code-compat.sh -- install one pinned Claude Code client, register this repository as a
# local marketplace, install the plugin from it, and capture the client's own component inventory.
# The assertion over that inventory lives in tests/assert-claude-code-registration.ps1.
#
# Dispatch 000287, docket P1-3 (review item 4), registration half. Advisory per ruling R-G.
#
# Two arguments arrive as environment variables so the workflow reads as two named steps rather
# than as one step with a positional argument nobody can see:
#   CLAUDE_CODE_VERSION  the exact npm version to install. A pin, never a dist-tag: "latest" moves
#                        under you and a leg pinned to a moving target is not a pin.
#   CLAUDE_CONFIG_DIR    the client's config root, deliberately outside the workspace.
set -euo pipefail

: "${CLAUDE_CODE_VERSION:?CLAUDE_CODE_VERSION must be set to an exact version}"
: "${CLAUDE_CONFIG_DIR:?CLAUDE_CONFIG_DIR must be set, and must be outside the workspace}"
export CLAUDE_CONFIG_DIR

case "$CLAUDE_CODE_VERSION" in
  latest|stable|next|"")
    echo "refusing to run against a dist-tag ('$CLAUDE_CODE_VERSION'): this leg pins exact versions." >&2
    exit 3
    ;;
esac

mkdir -p "$CLAUDE_CONFIG_DIR"
echo "--- installing @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} ---"
npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

# Assert the client that actually got installed is the one asked for. npm can satisfy a request
# from a cache or a mirror, and a leg that reports on a version it did not run is worse than no
# leg: it would put a version number in a compatibility claim that nothing verified.
installed="$(claude --version 2>&1 | head -1)"
echo "client reports: ${installed}"
case "$installed" in
  *"$CLAUDE_CODE_VERSION"*) ;;
  *)
    echo "installed client does not report ${CLAUDE_CODE_VERSION} -- refusing to attribute this run to that version." >&2
    exit 1
    ;;
esac

# `./` and not `.`: the client rejects a bare dot with "Invalid marketplace source format".
echo "--- registering this repository as a local marketplace ---"
claude plugin marketplace add ./
claude plugin marketplace list

echo "--- installing the plugin from it ---"
claude plugin install powershell-lsp@claude-powershell-lsp

out="claude-code-details-${CLAUDE_CODE_VERSION}.txt"
echo "--- capturing the client's own component inventory ---"
claude plugin details powershell-lsp | tee "$out"

echo "--- asserting registration ---"
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass \
  -File ./tests/assert-claude-code-registration.ps1 -DetailsOutput "$out"

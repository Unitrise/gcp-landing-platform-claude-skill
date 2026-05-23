#!/usr/bin/env bash
# install.sh — install the gcp-landing-platform skill into Claude Code
#
# Three ways to run:
#
#   1. From an unzipped local copy:
#        bash gcp-landing-platform/install.sh              # global (default)
#        bash gcp-landing-platform/install.sh --project    # current project only
#
#   2. Piped from GitHub (after you've pushed this skill to your own repo):
#        curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/gcp-landing-platform/install.sh | bash
#        curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/gcp-landing-platform/install.sh | bash -s -- --project
#
#   3. With env-var overrides (lets you keep one install.sh and target many forks):
#        SKILL_REPO_OWNER=talhaviv SKILL_REPO_NAME=claude-skills \
#          curl -fsSL https://raw.githubusercontent.com/talhaviv/claude-skills/main/gcp-landing-platform/install.sh | bash
#
# Flags:
#   --project, -p   Install to ./.claude/skills/ (current directory; only available in this project)
#   --global,  -g   Install to ~/.claude/skills/ (default; available in all projects)
#   --help,    -h   Print this help

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration — edit these once after you fork the skill to your own GitHub
# (Or pass them as environment variables when running the curl one-liner.)
# -----------------------------------------------------------------------------

SKILL_NAME="gcp-landing-platform"
REPO_OWNER="${SKILL_REPO_OWNER:-CHANGE_ME}"   # e.g. talhaviv
REPO_NAME="${SKILL_REPO_NAME:-CHANGE_ME}"     # e.g. claude-skills
REPO_BRANCH="${SKILL_REPO_BRANCH:-main}"

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

SCOPE="global"

for arg in "$@"; do
  case "$arg" in
    --project|-p) SCOPE="project" ;;
    --global|-g)  SCOPE="global" ;;
    -h|--help)
      grep '^# ' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg"
      echo "Run with --help for usage."
      exit 1
      ;;
  esac
done

if [[ "$SCOPE" == "project" ]]; then
  TARGET_BASE="$(pwd)/.claude/skills"
  SCOPE_NOTE="project scope — $(pwd)/.claude/skills/"
else
  TARGET_BASE="$HOME/.claude/skills"
  SCOPE_NOTE="user scope — $HOME/.claude/skills/ (available in every project)"
fi

TARGET="$TARGET_BASE/$SKILL_NAME"

# -----------------------------------------------------------------------------
# Locate the skill source
# Prefer a local copy (script lives next to SKILL.md). Fall back to downloading
# from GitHub when run via curl pipe.
# -----------------------------------------------------------------------------

SOURCE_DIR=""

# Case 1: running from disk — discover script location
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Is the script INSIDE the skill folder (i.e. next to SKILL.md)?
  if [[ -f "$SCRIPT_DIR/SKILL.md" ]]; then
    SOURCE_DIR="$SCRIPT_DIR"
  # Or is it a sibling of the skill folder?
  elif [[ -d "$SCRIPT_DIR/$SKILL_NAME" && -f "$SCRIPT_DIR/$SKILL_NAME/SKILL.md" ]]; then
    SOURCE_DIR="$SCRIPT_DIR/$SKILL_NAME"
  fi
fi

# Case 2: piped from curl — download the repo tarball into a temp dir
if [[ -z "$SOURCE_DIR" ]]; then
  if [[ "$REPO_OWNER" == "CHANGE_ME" || "$REPO_NAME" == "CHANGE_ME" ]]; then
    cat >&2 <<EOF
Error: REPO_OWNER / REPO_NAME are not configured.

To install via curl pipe, either:
  (a) edit install.sh and set REPO_OWNER + REPO_NAME to your fork, OR
  (b) pass them as environment variables on the curl invocation:

      SKILL_REPO_OWNER=<you> SKILL_REPO_NAME=<your-repo> \\
        curl -fsSL https://raw.githubusercontent.com/<you>/<your-repo>/main/gcp-landing-platform/install.sh | bash

To install from a local copy instead, just run:
  bash gcp-landing-platform/install.sh
EOF
    exit 1
  fi

  echo "→ Downloading $SKILL_NAME from github.com/$REPO_OWNER/$REPO_NAME (branch: $REPO_BRANCH)"

  TMP_DIR=$(mktemp -d)
  trap "rm -rf '$TMP_DIR'" EXIT

  TARBALL_URL="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${REPO_BRANCH}"

  if ! curl -fsSL "$TARBALL_URL" | tar -xz --strip-components=1 -C "$TMP_DIR"; then
    echo "Error: failed to download from $TARBALL_URL" >&2
    echo "Check that the repo exists and branch '$REPO_BRANCH' is accessible." >&2
    exit 1
  fi

  if [[ -f "$TMP_DIR/SKILL.md" ]]; then
    SOURCE_DIR="$TMP_DIR"
  elif [[ -d "$TMP_DIR/$SKILL_NAME" && -f "$TMP_DIR/$SKILL_NAME/SKILL.md" ]]; then
    SOURCE_DIR="$TMP_DIR/$SKILL_NAME"
  else
    echo "Error: could not find SKILL.md in the downloaded archive" >&2
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
# Install
# -----------------------------------------------------------------------------

mkdir -p "$TARGET_BASE"

if [[ -d "$TARGET" ]]; then
  echo "→ Existing install at $TARGET — replacing"
  rm -rf "$TARGET"
fi

cp -r "$SOURCE_DIR" "$TARGET"

# Re-apply executable bit on bundled scripts (zip and tar.gz both strip it sometimes)
find "$TARGET/scripts" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
chmod +x "$TARGET/install.sh" 2>/dev/null || true

echo ""
echo "✓ Installed $SKILL_NAME"
echo "  Path:   $TARGET"
echo "  Scope:  $SCOPE_NOTE"
echo ""
echo "Restart Claude Code (or open a fresh session) so the skill is loaded."

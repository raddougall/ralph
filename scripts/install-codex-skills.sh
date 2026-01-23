#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_DIR="$ROOT_DIR/skills"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
DEST_DIR="$CODEX_HOME/skills"

if [ ! -d "$SKILLS_DIR" ]; then
  echo "Skills directory not found: $SKILLS_DIR" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"

echo "Linking skills from $SKILLS_DIR to $DEST_DIR"

for skill_path in "$SKILLS_DIR"/*; do
  [ -d "$skill_path" ] || continue
  skill_name="$(basename "$skill_path")"
  dest_path="$DEST_DIR/$skill_name"

  if [ -L "$dest_path" ]; then
    existing_target="$(readlink "$dest_path")"
    if [ "$existing_target" = "$skill_path" ]; then
      echo "✓ $skill_name already linked"
      continue
    fi
    echo "Skipping $skill_name (symlink exists to $existing_target)" >&2
    continue
  fi

  if [ -e "$dest_path" ]; then
    echo "Skipping $skill_name (destination exists: $dest_path)" >&2
    continue
  fi

  ln -s "$skill_path" "$dest_path"
  echo "✓ linked $skill_name"
done

echo "Done. Restart Codex to pick up new skills."

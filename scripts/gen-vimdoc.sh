#!/usr/bin/env bash
#
# Generate doc/bemtvi-md-table.txt (the vimdoc help file) from
# doc/bemtvi-md-table.md using panvimdoc <https://github.com/kdheepak/panvimdoc>
# (MIT, Dheepak Krishnamurthy). panvimdoc drives pandoc to do all the vimdoc column
# math — right-aligned *tags*, the table of contents, and tw=78 reflow — so the help
# file is never hand-aligned. Edit doc/bemtvi-md-table.md, then run this.
#
# Requires: bash, git, pandoc (>= 3). panvimdoc is fetched on first run into a
# gitignored .panvimdoc/ cache, pinned to the SHA below.
set -euo pipefail

# --- per-plugin settings -----------------------------------------------------
PROJECT="bemtvi-md-table"                    # → :help bemtvi-md-table
DESCRIPTION="Aligned markdown tables for bemtvi"    # header tagline (line 1)
# -----------------------------------------------------------------------------

INPUT="doc/${PROJECT}.md"
OUTPUT="doc/${PROJECT}.txt"

# Pinned panvimdoc revision (bump deliberately to pick up upstream changes).
PANVIMDOC_REF="1f9433df889d4ab3daa5ea52c7069cb489ad47d6"

# Resolve repo root from this script's location so it runs from anywhere.
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CACHE="$ROOT/.panvimdoc"

command -v pandoc >/dev/null 2>&1 || { echo "error: pandoc (>= 3) is required" >&2; exit 1; }

# Fetch/pin panvimdoc into the cache. The cache is used only when it is checked out
# at exactly the pinned commit with no file changed: one left at another revision (a
# pin bump, or a fetch that cloned but failed to check out) or edited since is
# fetched again rather than run. A fetch is assembled in a temporary directory and
# moved into place only once verified.
cache_ok() {
  [ -e "$CACHE/panvimdoc.sh" ] &&
    [ "$(git -C "$CACHE" rev-parse HEAD 2>/dev/null)" = "$PANVIMDOC_REF" ] &&
    [ -z "$(git -C "$CACHE" status --porcelain 2>/dev/null)" ]
}
if ! cache_ok; then
  echo "fetching panvimdoc @ ${PANVIMDOC_REF} into .panvimdoc/ ..."
  TMP="$(mktemp -d "$ROOT/.panvimdoc.tmp.XXXXXX")"
  trap 'rm -rf "$TMP"' EXIT
  git clone --quiet https://github.com/kdheepak/panvimdoc.git "$TMP/panvimdoc"
  git -C "$TMP/panvimdoc" checkout --quiet "$PANVIMDOC_REF"
  if [ "$(git -C "$TMP/panvimdoc" rev-parse HEAD)" != "$PANVIMDOC_REF" ]; then
    echo "error: panvimdoc did not check out at ${PANVIMDOC_REF}" >&2
    exit 1
  fi
  rm -rf "$CACHE"
  mv "$TMP/panvimdoc" "$CACHE"
fi

echo "generating $OUTPUT from $INPUT ..."
bash "$CACHE/panvimdoc.sh" \
  --project-name "$PROJECT" \
  --input-file "$INPUT" \
  --vim-version "bemtvi" \
  --toc true \
  --description "$DESCRIPTION" \
  --title-date-pattern "%Y %B %d" \
  --dedup-subheadings true \
  --demojify true \
  --treesitter true

# panvimdoc runs pandoc's markdown reader, which curls straight quotes into
# typographic ones. Vim help convention is straight quotes, so normalize them
# back (code tokens are already left straight by pandoc, so this only touches
# prose). Em dash (—) and ellipsis (…) are intentional and left as-is.
# (Through a temp file rather than `sed -i`, whose syntax differs between GNU and BSD sed.)
sed "s/\xe2\x80\x99/'/g; s/\xe2\x80\x98/'/g; s/\xe2\x80\x9c/\"/g; s/\xe2\x80\x9d/\"/g" "$OUTPUT" > "$OUTPUT.tmp" && mv "$OUTPUT.tmp" "$OUTPUT"

# panvimdoc's second header line is "For <version>    Last change: <date>". The
# date is non-deterministic (a freshness check would fail the next day) and the
# "For bemtvi" half just restates the description on line 1, so drop the line
# entirely — the output is then reproducible and doesn't say "bemtvi" twice.
sed '2d' "$OUTPUT" > "$OUTPUT.tmp" && mv "$OUTPUT.tmp" "$OUTPUT"

# panvimdoc emits no blank line between the last table-of-contents entry and the
# first body line, so the TOC runs straight into the intro. Insert one blank line
# at that boundary (TOC entries end in "|link|"; the first body line does not).
awk '
  /^Table of Contents/ { seen = 1 }
  seen && !done && prev ~ /\|$/ && $0 !~ /\|$/ && $0 !~ /^[[:space:]]*$/ { print ""; done = 1 }
  { print; prev = $0 }
' "$OUTPUT" > "$OUTPUT.tmp" && mv "$OUTPUT.tmp" "$OUTPUT"

echo "done: $OUTPUT"

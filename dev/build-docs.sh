#!/usr/bin/env bash
set -euo pipefail

echo "🔍 Starting docs build script..."

BOOK_TOML="docs/book.toml"
BRANCH_NAME=${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}
SAFE_BRANCH_NAME=$(echo "$BRANCH_NAME" | tr '/' '-')
REPO_NAME=${GITHUB_REPOSITORY#*/}
if [[ -z "$REPO_NAME" ]]; then
  REPO_NAME=$(basename -s .git "$(git config --get remote.origin.url)")
fi

SITE_URL_LINE="site-url = \"/${REPO_NAME}/${SAFE_BRANCH_NAME}/\""
DOCS_OUT_DIR="docs/_build/${SAFE_BRANCH_NAME}"

echo "📄 Target TOML file: $BOOK_TOML"
echo "🌿 Branch name: $BRANCH_NAME (safe: $SAFE_BRANCH_NAME)"
echo "📦 Repo name: $REPO_NAME"
echo "🔧 site-url line: $SITE_URL_LINE"
echo "📂 Output docs directory: $DOCS_OUT_DIR"

# Step 1: Generate docs folder and book.toml if not exist
if [[ ! -d docs ]] || [[ ! -f "$BOOK_TOML" ]]; then
  echo "🛠 Running 'forge doc' to generate docs folder and book.toml..."
  forge doc
else
  echo "✅ docs folder and book.toml already exist."
fi

# Step 2: Patch book.toml
if grep -q "^\[output.html\]" "$BOOK_TOML"; then
  if grep -q "^site-url" "$BOOK_TOML"; then
    echo "🔁 Replacing existing site-url line..."
    sed -i.bak "s|^site-url = .*|$SITE_URL_LINE|" "$BOOK_TOML"
  else
    echo "➕ Inserting site-url line after [output.html]..."
    awk -v s="$SITE_URL_LINE" '
      /^\[output.html\]/ {
        print
        print s
        next
      }
      { print }
    ' "$BOOK_TOML" > "$BOOK_TOML.tmp" && mv "$BOOK_TOML.tmp" "$BOOK_TOML"
  fi
else
  echo "➕ Adding [output.html] section and site-url..."
  echo "[output.html]" >> "$BOOK_TOML"
  echo "$SITE_URL_LINE" >> "$BOOK_TOML"
fi

# Show patch preview
echo "📋 Preview of patched book.toml:"
head -n 20 "$BOOK_TOML"

# Step 3: Build docs into branch-specific folder
echo "⚙️ Running 'forge doc --build --out $DOCS_OUT_DIR' ..."
forge doc --build --out "$DOCS_OUT_DIR"

echo "✅ Docs successfully built at $DOCS_OUT_DIR"

# List output folder content
echo "📂 Listing $DOCS_OUT_DIR contents:"
ls -la "$DOCS_OUT_DIR"

echo "🔚 Script finished."

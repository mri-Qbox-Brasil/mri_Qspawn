#!/bin/bash
set -e

SCRIPT_NAME=${1:-"package"}

echo "Iniciando build para: $SCRIPT_NAME"

rm -rf dist
mkdir -p "dist/$SCRIPT_NAME"

# Build web (se existir)
if [ -d "web" ]; then
  echo "Building web..."
  cd web
  npm install --prefer-offline --no-audit --no-fund
  npm run build
  cd ..
fi

# Copia arquivos relevantes
echo "Copiando arquivos..."
rsync -av \
  --exclude=".git" \
  --exclude=".github" \
  --exclude=".gitignore" \
  --exclude=".release" \
  --exclude="scripts" \
  --exclude="README.md" \
  --exclude="MANUAL.md" \
  --exclude="CHANGELOG.md" \
  --exclude="node_modules" \
  --exclude="dist" \
  --exclude="web" \
  . "dist/$SCRIPT_NAME"

# Copia apenas o output do build web
if [ -d "web/dist" ]; then
  echo "Copiando web/dist..."
  cp -r web/dist "dist/$SCRIPT_NAME/web"
fi

# Compacta
echo "Compactando..."
cd dist
zip -r "$SCRIPT_NAME.zip" "$SCRIPT_NAME"

echo "Build concluido: dist/$SCRIPT_NAME.zip"

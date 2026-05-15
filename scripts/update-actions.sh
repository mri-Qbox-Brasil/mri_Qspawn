#!/bin/bash
set -e

# Configura git se necessário (em ambiente de CI)
if [ ! -z "$GITHUB_ACTIONS" ]; then
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
fi

echo "🔍 Buscando actions em .github/workflows/..."

# Encontra todas as actions externas usadas nos workflows
ACTIONS=$(grep -rhoE "uses: [^@[:space:]]+@[^[:space:]]+" .github/workflows/*.yml | sed 's/uses: //' | sort -u)

UPDATED=false
BRANCH_NAME="chore/update-actions-$(date +%Y%m)"

for ACTION_FULL in $ACTIONS; do
    # Pula actions locais
    if [[ $ACTION_FULL == ./* ]]; then continue; fi

    ACTION=$(echo $ACTION_FULL | cut -d'@' -f1)
    CURRENT_VERSION=$(echo $ACTION_FULL | cut -d'@' -f2)

    echo "📦 Verificando $ACTION (atual: $CURRENT_VERSION)..."

    # Busca a tag mais recente (tenta release primeiro, depois tags)
    FULL_LATEST_TAG=$(gh api "repos/$ACTION/releases/latest" -q .tag_name 2>/dev/null || gh api "repos/$ACTION/tags" -q '.[0].name' 2>/dev/null)

    if [ -z "$FULL_LATEST_TAG" ] || [ "$FULL_LATEST_TAG" == "null" ]; then
        echo "⚠️ Não foi possível encontrar tags para $ACTION"
        continue
    fi

    # Extrai a versão "fechada" (ex: v4 de v4.1.2 ou 6 de 6.0.1)
    LATEST_TAG=$(echo "$FULL_LATEST_TAG" | grep -oE "^v?[0-9]+")

    if [ "$CURRENT_VERSION" != "$LATEST_TAG" ]; then
        echo "✨ Nova versão fechada encontrada: $LATEST_TAG (baseada em $FULL_LATEST_TAG)"

        # Atualiza em todos os arquivos de workflow
        FILES=$(grep -lE "uses: $ACTION@$CURRENT_VERSION" .github/workflows/*.yml)
        for FILE in $FILES; do
            sed -i "s|uses: $ACTION@$CURRENT_VERSION|uses: $ACTION@$LATEST_TAG|g" "$FILE"
            echo "📝 Atualizado $FILE"
        done
        UPDATED=true
    else
        echo "✅ Já está na versão major mais recente ($LATEST_TAG)."
    fi
done

echo "📦 Buscando a última versão LTS do Node.js..."
LATEST_NODE=$(curl -sL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts != false)] | .[0].version' | grep -oE "^v[0-9]+" | sed 's/v//' 2>/dev/null)

if [ ! -z "$LATEST_NODE" ] && [ "$LATEST_NODE" != "null" ]; then
    echo "✨ Última major version do Node.js encontrada: $LATEST_NODE"

    # Verifica em quais arquivos há 'node-version: XX'
    NODE_FILES=$(grep -lE "node-version:[[:space:]]*['\"]?[0-9]+['\"]?" .github/workflows/*.yml || true)

    for FILE in $NODE_FILES; do
        if [ ! -z "$FILE" ] && [ -f "$FILE" ]; then
            CURRENT_NODE=$(grep -oE "node-version:[[:space:]]*['\"]?[0-9]+['\"]?" "$FILE" | head -1 | grep -oE "[0-9]+")
            if [ ! -z "$CURRENT_NODE" ] && [ "$CURRENT_NODE" != "$LATEST_NODE" ]; then
                sed -i -E "s/node-version:[[:space:]]*['\"]?[0-9]+['\"]?/node-version: $LATEST_NODE/g" "$FILE"
                echo "📝 Node atualizado de $CURRENT_NODE para $LATEST_NODE em $FILE"
                UPDATED=true
            else
                echo "✅ Node já está na versão LTS mais recente ($LATEST_NODE) em $FILE"
            fi
        fi
    done
else
    echo "⚠️ Não foi possível determinar a última versão do Node.js."
fi

if [ "$UPDATED" = true ]; then
    echo "🚀 Criando Pull Request..."

    # Garante que a opção de excluir a branch após o merge esteja ativada no repositório
    echo "⚙️ Configurando o repositório para auto-deletar a branch após o merge..."
    gh repo edit --delete-branch-on-merge || echo "⚠️ Aviso: Permissão insuficiente para alterar configurações do repositório. Ative isso manualmente em Settings > Pull Requests."

    git checkout -b "$BRANCH_NAME"
    git add .github/workflows/*.yml
    git commit -m "chore: update github actions versions [skip ci]"
    git push origin "$BRANCH_NAME" --force

    # Busca membros do time para atribuição (default: merge)
    TEAM_NAME=${PR_TEAM:-"merge"}
    REPO_FULL=$(gh repo view --json nameWithOwner -q .nameWithOwner)
    ORG=$(echo "$REPO_FULL" | cut -d'/' -f1)

    echo "👥 Buscando membros do time '$TEAM_NAME' em '$ORG'..."
    ASSIGNEES=$(gh api "orgs/$ORG/teams/$TEAM_NAME/members" -q '.[].login' | paste -sd "," - || echo "")

    PR_ARGS=(
        --title "chore: update github actions versions [skip ci]"
        --body "Automated update of GitHub Actions versions found in .github/workflows/"
        --base main
        --head "$BRANCH_NAME"
    )

    if [ ! -z "$ASSIGNEES" ]; then
        echo "✅ Atribuindo PR para: $ASSIGNEES"
        PR_ARGS+=(--assignee "$ASSIGNEES")
    else
        echo "⚠️ Nenhum membro encontrado no time '$TEAM_NAME' ou erro na API."
    fi

    gh pr create "${PR_ARGS[@]}"
else
    echo "🎉 Todas as actions estão atualizadas."
fi

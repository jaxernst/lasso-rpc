#!/bin/bash
set -euo pipefail

echo "======================================"
echo "Git History API Key Cleanup Script"
echo "======================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if BFG is installed
if ! command -v bfg &> /dev/null; then
    echo -e "${RED}Error: BFG Repo-Cleaner is not installed${NC}"
    echo "Install with: brew install bfg"
    exit 1
fi

echo -e "${YELLOW}Step 1: Creating backup${NC}"
BACKUP_DIR="../lasso-rpc-backup-$(date +%Y%m%d-%H%M%S)"
git clone --mirror . "$BACKUP_DIR"
echo -e "${GREEN}✓ Backup created at: $BACKUP_DIR${NC}"
echo ""

echo -e "${YELLOW}Step 2: Verifying current state${NC}"
echo "Checking for API keys in current history..."
KEYS_FOUND=0
for key in "REDACTED_DRPC_KEY" \
           "REDACTED_LAVA_KEY" \
           "REDACTED_1RPC_KEY" \
           "REDACTED_ALCHEMY_KEY_1" \
           "REDACTED_CHAINSTACK_KEY"; do
    if git log --all --full-history -p | grep -q "$key"; then
        echo -e "${RED}  Found: $key${NC}"
        KEYS_FOUND=$((KEYS_FOUND + 1))
    fi
done
echo "Total keys found in history: $KEYS_FOUND"
echo ""

if [ $KEYS_FOUND -eq 0 ]; then
    echo -e "${GREEN}No API keys found in history. Nothing to clean!${NC}"
    exit 0
fi

echo -e "${YELLOW}Step 3: Running BFG Repo-Cleaner${NC}"
echo "This will replace all API keys with REDACTED_*_KEY placeholders..."
bfg --replace-text /tmp/bfg-replacements.txt

echo -e "${GREEN}✓ BFG cleanup complete${NC}"
echo ""

echo -e "${YELLOW}Step 4: Cleaning up Git metadata${NC}"
git reflog expire --expire=now --all
git gc --prune=now --aggressive
echo -e "${GREEN}✓ Git metadata cleaned${NC}"
echo ""

echo -e "${YELLOW}Step 5: Verifying cleanup${NC}"
KEYS_REMAINING=0
for key in "REDACTED_DRPC_KEY" \
           "REDACTED_LAVA_KEY" \
           "REDACTED_1RPC_KEY" \
           "REDACTED_ALCHEMY_KEY_1" \
           "REDACTED_CHAINSTACK_KEY"; do
    if git log --all --full-history -p | grep -q "$key"; then
        echo -e "${RED}  Still found: $key${NC}"
        KEYS_REMAINING=$((KEYS_REMAINING + 1))
    fi
done

if [ $KEYS_REMAINING -eq 0 ]; then
    echo -e "${GREEN}✓ All API keys successfully removed from history!${NC}"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "1. Review changes with: git log -p | grep -i REDACTED"
    echo "2. Force push to remote: git push --force --all"
    echo "3. Force push tags: git push --force --tags"
    echo ""
    echo -e "${RED}⚠️  IMPORTANT: After force pushing, rotate ALL these API keys:${NC}"
    echo "   - DRPC API key"
    echo "   - Lava API key"
    echo "   - 1RPC API key"
    echo "   - Alchemy API key"
    echo "   - Chainstack API key"
else
    echo -e "${RED}✗ Warning: $KEYS_REMAINING keys still found in history${NC}"
    echo "Manual intervention may be required."
    exit 1
fi

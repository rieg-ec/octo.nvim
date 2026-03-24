---
name: octo-dev
description: Developing and testing octo.nvim - Neovim plugin for GitHub issues, PRs, and reviews. Use when modifying octo.nvim Lua source code or testing changes visually.
---

## Architecture

octo.nvim is a Neovim plugin written in Lua. Key modules:

- `lua/octo/ui/writers.lua` - Renders PR/issue content into Neovim buffers (comments, threads, diffs, timeline events). This is the core rendering engine.
- `lua/octo/ui/statuscolumn.lua` - Gutter markers (`[`, `┌╴`, `└╴`) for comment blocks. Supports nested reply indentation.
- `lua/octo/ui/signs.lua` - Bridge between comment metadata and statuscolumn/signcolumn placement.
- `lua/octo/ui/colors.lua` - Highlight groups, dynamic color creation from hex values.
- `lua/octo/ui/bubbles.lua` - Bubble/chip rendering for labels, states, users.
- `lua/octo/config.lua` - Configuration schema with defaults and validation.
- `lua/octo/gh/` - GitHub CLI and GraphQL API interaction (fragments, mutations, queries).
- `lua/octo/model/` - Data models (octo-buffer, comment-metadata, thread-metadata).
- `lua/octo/commands.lua` - User-facing `:Octo` commands.
- `lua/octo/reviews/` - Review mode (diff view, thread display).

## Key concepts

- **Virtual text**: Comment headers (author, date, labels like `THREAD COMMENT:`, `REPLY:`) are rendered as virtual text via `nvim_buf_set_extmark`, not as buffer text.
- **Buffer text**: Comment bodies are real editable buffer text written via `write_block()`.
- **comment.replyTo**: Field on `PullRequestReviewComment` that is `vim.NIL` for root thread comments and contains `{id, url}` for replies. Use `utils.is_blank(comment.replyTo)` to distinguish.
- **timeline_indent**: Config value (default 2) controlling indentation multiplier for timeline items.
- **statuscolumn vs signcolumn**: `use_statuscolumn = true` (default) uses the newer Neovim statuscolumn for comment gutter markers and supports nested reply indentation. `use_signcolumn = true` is the legacy fallback. Only enable one.
- **reviewId**: Available on comment metadata (`comment.pullRequestReview.id`). Can be used to group threads by review.

## Testing workflow

### 1. Lua syntax check (always do first)

```bash
luac -p lua/octo/ui/writers.lua
```

### 2. Copy changes to installed plugin

After editing files in `~/cs/octo.nvim`, copy them to the installed plugin directory so nvim picks them up:

```bash
cp lua/octo/ui/writers.lua ~/.local/share/nvim/plugged/octo.nvim/lua/octo/ui/writers.lua
```

### 3. Headless test (fast, no visual)

```bash
nvim --headless -c "luafile /tmp/test_octo.lua" 2>&1
```

Write a Lua script that:
1. Calls `require('octo').setup({ picker = 'telescope' })`
2. Opens a PR: `vim.cmd('Octo pr edit <number> <owner/repo>')`
3. Uses `vim.defer_fn` (8-10s delay) to inspect buffer after loading
4. Checks `vim.api.nvim_buf_get_extmarks(0, -1, ...)` for virtual text content
5. Calls `vim.cmd('qa!')` to exit

### 4. Visual test with agent-tui + puppeteer screenshots

This is the primary testing workflow. It launches nvim in a PTY, drives it via agent-tui, and captures real visual screenshots via the live preview web UI + puppeteer.

#### Step 1: Launch nvim and open a PR

```bash
agent-tui daemon start          # ensure daemon is running
agent-tui run nvim               # launch nvim in a PTY session
sleep 3 && agent-tui press Enter # dismiss any startup errors

# Open a PR with review threads
agent-tui type ":Octo pr edit <number> <owner/repo>"
agent-tui press Enter
sleep 15                         # wait for PR data to load from GitHub

# Navigate to the area you want to verify
agent-tui type ":<line_number>"
agent-tui press Enter
```

**Important**: The first `:Octo` command often lands on the wrong buffer (e.g., alpha screen). If `agent-tui screenshot` shows the wrong content, retry the `:Octo` command.

#### Step 2: Quick text check

```bash
agent-tui screenshot             # text-based screenshot for quick verification
```

Use this to confirm you're on the right buffer and the rendering looks correct before taking the visual screenshot.

#### Step 3: Take a visual PNG screenshot

```bash
# Get the live preview details
agent-tui live start --json      # returns token
agent-tui sessions               # returns session id
```

Then use a puppeteer script to screenshot the live preview web UI:

```javascript
// /tmp/screenshot-proj/capture.mjs
import puppeteer from 'puppeteer';

const token = '<TOKEN>';
const sessionId = '<SESSION_ID>';
const url = `http://127.0.0.1:<PORT>/ui?token=${token}&session=${sessionId}`;

const browser = await puppeteer.launch({ headless: true });
const page = await browser.newPage();
await page.setViewport({ width: 1400, height: 800 });
await page.goto(url, { waitUntil: 'networkidle2', timeout: 15000 });
await new Promise(r => setTimeout(r, 4000));
await page.screenshot({ path: '/tmp/screenshot.png', fullPage: false });
await browser.close();
```

Run it:
```bash
node /tmp/screenshot-proj/capture.mjs
```

**Setup** (first time only):
```bash
mkdir -p /tmp/screenshot-proj
echo '{"type": "module", "dependencies": {"puppeteer": "^24.0.0"}}' > /tmp/screenshot-proj/package.json
npm install --prefix /tmp/screenshot-proj
npx --yes puppeteer browsers install chrome
```

#### Step 4: Attach screenshot to PR description

Do NOT commit screenshots to the repo. Instead, upload them as draft release assets and reference them in the PR body:

```bash
# Create a draft release for screenshots (first time only)
gh release create v0.0.1-screenshots --repo rieg-ec/octo.nvim --draft --title "Screenshots" --notes "PR screenshots"

# Upload the screenshot
gh release upload v0.0.1-screenshots --repo rieg-ec/octo.nvim /tmp/screenshot.png --clobber

# Get the asset URL
gh release view v0.0.1-screenshots --repo rieg-ec/octo.nvim --json assets --jq '.assets[].url'
```

Then reference the URL in the PR body:
```markdown
![feature](https://github.com/rieg-ec/octo.nvim/releases/download/untagged-.../screenshot.png)
```

#### Step 5: Cleanup

```bash
agent-tui kill                   # stop the nvim session
```

### 5. Existing tests (plenary)

```bash
nvim --headless -c "PlenaryBustedDirectory lua/tests/plenary/ {minimal_init = 'lua/tests/minimal_init.vim'}"
```

Note: existing tests cover config, utils, URI, and timeline events - not the writers module.

## writers.lua patterns

When modifying `write_comment()` (around line 1063):

- The function handles multiple `kind` values: `PullRequestReview`, `PullRequestReviewComment`, `PullRequestComment`, `IssueComment`, `DiscussionComment`
- Header is virtual text built in `header_vt` table, rendered via `write_virtual_text()`
- Body is real buffer text written via `write_block(bufnr, content, line, true)`
- Comment metadata is stored via `CommentMetadata:new()` for later save/edit operations
- Do not change body indentation without accounting for the edit/save round-trip (body text must match what gets sent back to GitHub)
- For visual-only indentation, use `virt_text_pos = "inline"` extmarks (does not modify buffer text)
- Author highlight colors can be set dynamically via `colors.create_highlight(hex)` from `lua/octo/ui/colors.lua`

## PR workflow

1. Create a feature branch from `master`
2. Make changes
3. Run `luac -p` syntax check on all modified files
4. Copy changed files to `~/.local/share/nvim/plugged/octo.nvim/`
5. Test visually with agent-tui + puppeteer (see above)
6. Amend the commit if the approach changes; avoid incremental fix commits
7. Push and create PR to the fork repo (rieg-ec/octo.nvim)
8. Do NOT commit screenshots to the repo; use them only for local verification
9. Squash-merge with a clean commit message describing only the final state

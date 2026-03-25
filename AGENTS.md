# octo.nvim fork (rieg-ec)

This is a fork of [pwntester/octo.nvim](https://github.com/pwntester/octo.nvim) - a Neovim plugin for editing and reviewing GitHub issues, PRs, and discussions.

## Project structure

```
lua/octo/
  ui/writers.lua      -- Core rendering: comments, threads, diffs, timeline
  ui/statuscolumn.lua -- Gutter markers for comment blocks (nested replies)
  ui/signs.lua        -- Sign/statuscolumn placement bridge
  ui/colors.lua       -- Highlight groups and dynamic color creation
  ui/bubbles.lua      -- Bubble/chip rendering for labels, states, users
  config.lua          -- Configuration defaults and validation
  commands.lua        -- :Octo command definitions
  gh/                 -- GitHub CLI wrappers (GraphQL fragments, mutations)
  model/              -- Buffer/comment/thread metadata models
  reviews/            -- Review mode (diff view, thread panels)
lua/tests/            -- Plenary-based tests
doc/octo.txt          -- Vim help file
```

## Development guidelines

- This is a Lua-only Neovim plugin. No build step required.
- All rendering goes through `lua/octo/ui/writers.lua`. Comment headers use virtual text; comment bodies are editable buffer text.
- GitHub data comes via `gh` CLI. GraphQL fragments are in `lua/octo/gh/fragments.lua`.
- Run `luac -p <file>` to syntax-check any Lua changes.
- Existing tests: `nvim --headless -c "PlenaryBustedDirectory lua/tests/plenary/ {minimal_init = 'lua/tests/minimal_init.vim'}"`
- Visual testing: use `agent-tui` + puppeteer to run nvim, open PRs, take visual screenshots, and attach them to PRs. Load the `octo-dev` skill for the full workflow.

## Commit discipline

- PRs should be squash-merged with a single clean commit message describing only the final state.
- During development, use `git commit --amend` or `git commit --fixup` instead of adding incremental "fix:" commits when the plan changes within the same PR. The commit history should read as if the final approach was the first approach.
- Only create separate commits for genuinely distinct changes (e.g., a feature commit + a docs commit).
- When squash-merging, the commit message should not mention things that were tried and reverted. Only describe what ended up in the final diff.

## Fork-specific changes

Changes in this fork that differ from upstream:
- Nested reply rendering in PR review threads (shifted gutter, REPLY: label, indented bodies)
- Deterministic reviewer-colored author labels across PR timeline

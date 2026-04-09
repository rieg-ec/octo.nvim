local config = require "octo.config"
local constants = require "octo.constants"
local renderer = require "octo.reviews.renderer"
local utils = require "octo.utils"

local M = {}

local name_counter = 1
---@class ReviewBrowserPanelEntry
---@field kind "summary"|"thread"
---@field id string
---@field label string
---@field summary string
---@field comment_count integer
---@field path? string
---@field basename? string
---@field extension? string
---@field isResolved? boolean
---@field isOutdated? boolean
---@field thread? octo.ReviewThread

---@class ReviewBrowserPanel
---@field review_browser ReviewBrowser
---@field files ReviewBrowserPanelEntry[]
---@field bufid integer
---@field winid integer
---@field render_data RenderData
---@field entry_ranges table<string, { start_line: integer, end_line: integer }>
---@field line_entries table<integer, ReviewBrowserPanelEntry>
local ReviewBrowserPanel = {}
ReviewBrowserPanel.__index = ReviewBrowserPanel

ReviewBrowserPanel.winopts = {
  relativenumber = false,
  number = false,
  list = false,
  winfixwidth = true,
  winfixheight = true,
  foldenable = false,
  spell = false,
  wrap = false,
  cursorline = true,
  cursorlineopt = "line",
  signcolumn = "yes",
  foldmethod = "manual",
  foldcolumn = "0",
  scrollbind = false,
  cursorbind = false,
  diff = false,
  winhl = table.concat({
    "EndOfBuffer:OctoEndOfBuffer",
    "Normal:OctoNormal",
    "WinSeparator:OctoWinSeparator",
    "SignColumn:OctoNormal",
    "StatusLine:OctoStatusLine",
    "StatusLineNC:OctoStatuslineNC",
  }, ","),
}

ReviewBrowserPanel.bufopts = {
  swapfile = false,
  buftype = "nofile",
  modifiable = false,
  filetype = "octo_panel",
  bufhidden = "hide",
}

local function entry_key(entry)
  return entry.id
end

local function compact_entry_label(entry)
  if entry.kind == "summary" then
    return "Review summary"
  end

  local status = entry.isResolved and "✓ " or entry.isOutdated and "! " or "  "
  return status .. entry.label
end

---@param review_browser ReviewBrowser
---@param files ReviewBrowserPanelEntry[]
---@return ReviewBrowserPanel
function ReviewBrowserPanel:new(review_browser, files)
  local this = {
    review_browser = review_browser,
    files = files,
    entry_ranges = {},
    line_entries = {},
  }

  setmetatable(this, self)
  return this
end

function ReviewBrowserPanel:is_open()
  local valid = self.winid and vim.api.nvim_win_is_valid(self.winid)
  if not valid then
    self.winid = nil
  end
  return valid
end

function ReviewBrowserPanel:is_focused()
  return self:is_open() and vim.api.nvim_get_current_win() == self.winid
end

---@param open_if_closed boolean
function ReviewBrowserPanel:focus(open_if_closed)
  if self:is_open() then
    vim.api.nvim_set_current_win(self.winid)
  elseif open_if_closed then
    self:open()
  end
end

function ReviewBrowserPanel:buf_loaded()
  return self.bufid and vim.api.nvim_buf_is_loaded(self.bufid)
end

local function map_panel_action(bufnr, lhs, rhs)
  if lhs and lhs ~= "" then
    vim.keymap.set("n", lhs, rhs, { buffer = bufnr, nowait = true, silent = true })
  end
end

function ReviewBrowserPanel:bind_mappings()
  local mappings = config.values.mappings.file_panel

  map_panel_action(self.bufid, mappings.next_entry.lhs, function()
    self:highlight_next_file()
  end)

  map_panel_action(self.bufid, mappings.prev_entry.lhs, function()
    self:highlight_prev_file()
  end)

  map_panel_action(self.bufid, mappings.select_entry.lhs, function()
    local review = require("octo.reviews").get_current_review()
    if review and review.layout then
      local entry = self:get_file_at_cursor()
      if entry then
        review.layout:set_current_file(entry)
      end
    end
  end)

  map_panel_action(self.bufid, mappings.select_next_entry.lhs, function()
    local layout = require("octo.reviews").get_current_layout()
    if layout then
      layout:select_next_file()
    end
  end)

  map_panel_action(self.bufid, mappings.select_prev_entry.lhs, function()
    local layout = require("octo.reviews").get_current_layout()
    if layout then
      layout:select_prev_file()
    end
  end)

  map_panel_action(self.bufid, mappings.select_first_entry.lhs, function()
    local layout = require("octo.reviews").get_current_layout()
    if layout then
      layout:select_first_file()
    end
  end)

  map_panel_action(self.bufid, mappings.select_last_entry.lhs, function()
    local layout = require("octo.reviews").get_current_layout()
    if layout then
      layout:select_last_file()
    end
  end)

  map_panel_action(self.bufid, mappings.refresh_files.lhs, function()
    local layout = require("octo.reviews").get_current_layout()
    if layout then
      layout:update_files()
    end
  end)

  map_panel_action(self.bufid, mappings.close_review_tab.lhs, function()
    require("octo.reviews").close(vim.api.nvim_get_current_tabpage())
  end)
end

function ReviewBrowserPanel:init_buffer()
  local bn = vim.api.nvim_create_buf(false, false)

  for k, v in pairs(ReviewBrowserPanel.bufopts) do
    vim.api.nvim_set_option_value(k, v, { buf = bn })
  end

  local bufname = "OctoReviewThreads-" .. name_counter
  name_counter = name_counter + 1
  local ok = pcall(vim.api.nvim_buf_set_name, bn, bufname)
  if not ok then
    utils.wipe_named_buffer(bufname)
    vim.api.nvim_buf_set_name(bn, bufname)
  end

  self.bufid = bn
  self.render_data = renderer.RenderData:new(bufname)
  self:bind_mappings()
  self:render()
  self:redraw()
  return bn
end

function ReviewBrowserPanel:open()
  if not self:buf_loaded() then
    self:init_buffer()
  end
  if self:is_open() then
    return
  end

  vim.cmd "vsp"
  vim.cmd "wincmd H"
  vim.cmd("vertical resize " .. config.values.file_panel.size)
  self.winid = vim.api.nvim_get_current_win()
  vim.cmd("buffer " .. self.bufid)

  for k, v in pairs(ReviewBrowserPanel.winopts) do
    vim.api.nvim_set_option_value(k, v, { win = self.winid, scope = "local" })
  end
end

function ReviewBrowserPanel:close()
  if self:is_open() and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    pcall(vim.api.nvim_win_hide, self.winid)
  end
end

function ReviewBrowserPanel:destroy()
  if self:buf_loaded() then
    self:close()
    pcall(vim.api.nvim_buf_delete, self.bufid, { force = true })
  else
    self:close()
  end
end

---@return ReviewBrowserPanelEntry|nil
function ReviewBrowserPanel:get_file_at_cursor()
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(self.winid)
  return self.line_entries[cursor[1]]
end

---@param entry ReviewBrowserPanelEntry
function ReviewBrowserPanel:highlight_file(entry)
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  local range = self.entry_ranges[entry_key(entry)]
  if not range then
    return
  end

  pcall(vim.api.nvim_win_set_cursor, self.winid, { range.start_line, 0 })
  vim.api.nvim_buf_clear_namespace(self.bufid, constants.OCTO_FILE_PANEL_NS, 0, -1)
  vim.api.nvim_buf_set_extmark(self.bufid, constants.OCTO_FILE_PANEL_NS, range.start_line - 1, 0, {
    end_line = range.end_line,
    end_col = 0,
    hl_group = "OctoFilePanelSelectedFile",
  })
end

function ReviewBrowserPanel:highlight_prev_file()
  if not (self:is_open() and self:buf_loaded()) or #self.files == 0 then
    return
  end

  local current = self:get_file_at_cursor() or self.files[1]
  for i, entry in ipairs(self.files) do
    if entry == current then
      local prev_idx = utils.clamp(i - 1, 1, #self.files)
      self:highlight_file(self.files[prev_idx])
      return
    end
  end
end

function ReviewBrowserPanel:highlight_next_file()
  if not (self:is_open() and self:buf_loaded()) or #self.files == 0 then
    return
  end

  local current = self:get_file_at_cursor() or self.files[1]
  for i, entry in ipairs(self.files) do
    if entry == current then
      local next_idx = utils.clamp(i + 1, 1, #self.files)
      self:highlight_file(self.files[next_idx])
      return
    end
  end
end

function ReviewBrowserPanel:render()
  if not self.render_data then
    return
  end

  self.render_data:clear()
  self.entry_ranges = {}
  self.line_entries = {}

  local line_idx = 0
  local lines = self.render_data.lines

  local conf = config.values
  local title = "Review threads"
  local thread_count = math.max(#self.files - 1, 0)
  local count_bubble = string.format("%s%d%s", conf.left_bubble_delimiter, thread_count, conf.right_bubble_delimiter)

  table.insert(lines, title .. " " .. count_bubble)
  line_idx = line_idx + 1

  local review = self.review_browser.selected_review
  local author = review.author and review.author.login or "ghost"
  local details = string.format("%s • %s", author, review.display_date or review.createdAt)
  if review.state and review.state ~= "" then
    details = details .. " • " .. review.state:lower()
  end
  table.insert(lines, details)
  line_idx = line_idx + 1

  for _, entry in ipairs(self.files) do
    local start_line = line_idx + 1
    table.insert(lines, compact_entry_label(entry))
    line_idx = line_idx + 1

    local end_line = start_line
    local key = entry_key(entry)
    self.entry_ranges[key] = { start_line = start_line, end_line = end_line }
    for mapped_line = start_line, end_line do
      self.line_entries[mapped_line] = entry
    end
  end
end

function ReviewBrowserPanel:redraw()
  if self:buf_loaded() then
    renderer.render(self.bufid, self.render_data)
  end
end

M.ReviewBrowserPanel = ReviewBrowserPanel

return M

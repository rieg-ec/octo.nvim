local OctoBuffer = require("octo.model.octo-buffer").OctoBuffer
local ReviewBrowserPanel = require("octo.reviews.review-browser-panel").ReviewBrowserPanel
local config = require "octo.config"
local utils = require "octo.utils"
local writers = require "octo.ui.writers"

local M = {}

---@class ReviewBrowserThreadEntry
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

---@class ReviewBrowserLayout
---@field review_browser ReviewBrowser
---@field file_panel ReviewBrowserPanel
---@field files ReviewBrowserThreadEntry[]
---@field selected_file_idx integer
---@field tabpage integer
---@field left_winid integer
---@field right_winid integer
local ReviewBrowserLayout = {}
ReviewBrowserLayout.__index = ReviewBrowserLayout

---@class ReviewBrowser
---@field id integer
---@field review_id string
---@field selected_review octo.fragments.PullRequestReview & { comment_count: integer }
---@field pull_request PullRequest
---@field threads table<string, octo.ReviewThread>
---@field layout ReviewBrowserLayout
local ReviewBrowser = {}
ReviewBrowser.__index = ReviewBrowser

local function review_author(review)
  return review.author and review.author.login or "ghost"
end

local function format_review_datetime(date_string)
  local timestamp = utils.parse_utc_date(date_string)
  local local_time = os.time()
  local utc_time = os.time(os.date("!*t"))
  local offset = os.difftime(local_time, utc_time)
  return os.date("%Y-%m-%d %H:%M", timestamp + offset)
end

local function normalize_thread(thread)
  if thread.line == vim.NIL then
    thread.line = thread.originalLine
  end

  if thread.startLine == vim.NIL then
    thread.startLine = thread.line
    thread.startDiffSide = thread.diffSide
    thread.originalStartLine = thread.originalLine
  end

  return thread
end

local function thread_start_line(thread)
  return thread.originalStartLine ~= vim.NIL and thread.originalStartLine or thread.originalLine
end

local function thread_end_line(thread)
  return thread.originalLine
end

local function matching_review_comments(thread, review_id)
  local comments = {}
  for _, comment in ipairs(thread.comments.nodes) do
    if comment.pullRequestReview and comment.pullRequestReview.id == review_id then
      table.insert(comments, comment)
    end
  end
  return comments
end

local function comment_summary(comment)
  if not comment or utils.is_blank(comment.body) then
    return ""
  end

  local summary = utils.trim(comment.body:gsub("\r\n", "\n"))
  return summary:gsub("\n.*", "")
end

local function entry_key(entry)
  return entry.id
end

local function detail_bufname(repo, review_id, suffix)
  local safe_review_id = tostring(review_id):gsub("[^%w%-_]", "-")
  local safe_suffix = tostring(suffix):gsub("[^%w%-_]", "-")
  return string.format("octo://%s/review-browser/%s/%s", repo, safe_review_id, safe_suffix)
end

---@param review_browser ReviewBrowser
---@return ReviewBrowserLayout
function ReviewBrowserLayout:new(review_browser)
  local this = {
    review_browser = review_browser,
    files = {},
    selected_file_idx = 1,
  }

  this.file_panel = ReviewBrowserPanel:new(review_browser, this.files)
  setmetatable(this, self)
  return this
end

function ReviewBrowserLayout:init_layout()
  self.right_winid = vim.api.nvim_get_current_win()
  self.file_panel:open()
  self.left_winid = self.file_panel.winid
  if self.right_winid and vim.api.nvim_win_is_valid(self.right_winid) then
    vim.api.nvim_set_current_win(self.right_winid)
  end
end

function ReviewBrowserLayout:open()
  vim.cmd "tab split"
  self.tabpage = vim.api.nvim_get_current_tabpage()
  require("octo.reviews").reviews[tostring(self.tabpage)] = self.review_browser
  self:init_layout()
  self:update_files()
end

function ReviewBrowserLayout:close()
  for _, entry in ipairs(self.files) do
    if entry.buffer and vim.api.nvim_buf_is_valid(entry.buffer.bufnr) then
      pcall(vim.api.nvim_buf_delete, entry.buffer.bufnr, { force = true })
    end
  end

  self.file_panel:destroy()

  if self.tabpage and vim.api.nvim_tabpage_is_valid(self.tabpage) then
    local pagenr = vim.api.nvim_tabpage_get_number(self.tabpage)
    pcall(vim.cmd.tabclose, pagenr)
  end
end

function ReviewBrowserLayout:on_enter() end

function ReviewBrowserLayout:on_leave() end

function ReviewBrowserLayout:on_win_leave() end

function ReviewBrowserLayout:get_current_file()
  if #self.files == 0 then
    return nil
  end
  return self.files[utils.clamp(self.selected_file_idx, 1, #self.files)]
end

local function create_buffer(name, pull_request)
  local existing_bufnr = vim.fn.bufnr(name)
  if existing_bufnr ~= -1 then
    if vim.api.nvim_buf_is_loaded(existing_bufnr) then
      return octo_buffers[existing_bufnr]
    end
    vim.api.nvim_buf_delete(existing_bufnr, { force = true })
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  local ok = pcall(vim.api.nvim_buf_set_name, bufnr, name)
  if not ok then
    utils.wipe_named_buffer(name)
    vim.api.nvim_buf_set_name(bufnr, name)
  end

  return OctoBuffer:new {
    bufnr = bufnr,
    number = pull_request.number,
    repo = pull_request.repo,
  }
end

local function reset_buffer(buffer)
  buffer:clear()
  buffer.commentsMetadata = {}
  buffer.threadsMetadata = {}
end

local function render_summary_buffer(buffer, review)
  reset_buffer(buffer)
  if utils.is_blank(utils.trim(review.body)) then
    writers.write_review_decision(buffer.bufnr, review)
  else
    writers.write_comment(buffer.bufnr, review, "PullRequestReview")
  end
  buffer:render_signs()
  vim.bo[buffer.bufnr].modified = false
  buffer.ready = true
end

local function render_thread_buffer(buffer, thread)
  reset_buffer(buffer)
  writers.write_threads(buffer.bufnr, { thread })
  buffer:render_signs()
  vim.bo[buffer.bufnr].modified = false
  buffer.ready = true
end

function ReviewBrowserLayout:configure_detail_buffer(buffer, entry)
  local bufnr = buffer.bufnr
  if vim.b[bufnr].octo_review_browser_configured then
    return
  end

  buffer:configure()
  if entry.kind == "thread" then
    buffer.use_pull_request_thread_actions = true
  end
  self:apply_detail_mappings(buffer)
  vim.b[bufnr].octo_review_browser_configured = true
end

function ReviewBrowserLayout:apply_detail_mappings(buffer)
  local review_diff_mappings = config.values.mappings.review_diff
  local bufnr = buffer.bufnr

  local function map(lhs, rhs)
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, rhs, { buffer = bufnr, nowait = true, silent = true })
    end
  end

  map(review_diff_mappings.focus_files.lhs, function()
    self.file_panel:focus(true)
  end)
end

function ReviewBrowserLayout:get_or_create_buffer(entry)
  local pull_request = self.review_browser.pull_request
  if entry.kind == "summary" then
    local buffer = create_buffer(detail_bufname(pull_request.repo, self.review_browser.review_id, "summary"), pull_request)
    render_summary_buffer(buffer, self.review_browser.selected_review)
    return buffer
  end

  local buffer = create_buffer(detail_bufname(pull_request.repo, self.review_browser.review_id, entry.thread.id), pull_request)
  render_thread_buffer(buffer, entry.thread)
  return buffer
end

---@param entry ReviewBrowserThreadEntry
---@param focus? "left"|"right"
function ReviewBrowserLayout:set_current_file(entry, focus)
  if not entry then
    return
  end

  for i, current in ipairs(self.files) do
    if entry_key(current) == entry_key(entry) then
      self.selected_file_idx = i
      entry = current
      break
    end
  end

  local buffer = self:get_or_create_buffer(entry)
  entry.buffer = buffer

  if self.right_winid and vim.api.nvim_win_is_valid(self.right_winid) then
    vim.api.nvim_win_set_buf(self.right_winid, buffer.bufnr)
  end

  self:configure_detail_buffer(buffer, entry)
  self.file_panel:highlight_file(entry)

  if entry.kind == "thread" then
    vim.api.nvim_buf_call(buffer.bufnr, function()
      vim.cmd [[setlocal foldmethod=manual]]
      vim.cmd [[normal! zR]]
    end)
  end

  focus = focus or config.values.reviews.focus
  if focus == "left" and self.left_winid and vim.api.nvim_win_is_valid(self.left_winid) then
    vim.api.nvim_set_current_win(self.left_winid)
  elseif self.right_winid and vim.api.nvim_win_is_valid(self.right_winid) then
    vim.api.nvim_set_current_win(self.right_winid)
  end
end

function ReviewBrowserLayout:update_files()
  local current_entry = self:get_current_file()
  local current_key = current_entry and entry_key(current_entry) or nil
  local current_focus = "right"
  local current_win = vim.api.nvim_get_current_win()
  if self.left_winid and current_win == self.left_winid then
    current_focus = "left"
  end

  self.files = self.review_browser:build_entries()
  self.file_panel.files = self.files
  self.file_panel:render()
  self.file_panel:redraw()

  local next_entry = self.files[1]
  if current_key then
    for _, entry in ipairs(self.files) do
      if entry_key(entry) == current_key then
        next_entry = entry
        break
      end
    end
  end

  if next_entry then
    self:set_current_file(next_entry, current_focus)
  end
end

function ReviewBrowserLayout:select_prev_file()
  if #self.files == 0 then
    return
  end
  local prev_idx = (self.selected_file_idx - 2) % #self.files + 1
  self:set_current_file(self.files[prev_idx])
end

function ReviewBrowserLayout:select_next_file()
  if #self.files == 0 then
    return
  end
  local next_idx = self.selected_file_idx % #self.files + 1
  self:set_current_file(self.files[next_idx])
end

function ReviewBrowserLayout:select_first_file()
  if self.files[1] then
    self:set_current_file(self.files[1])
  end
end

function ReviewBrowserLayout:select_last_file()
  if self.files[#self.files] then
    self:set_current_file(self.files[#self.files])
  end
end

function ReviewBrowserLayout:select_next_unviewed_file()
  self:select_next_file()
end

function ReviewBrowserLayout:select_prev_unviewed_file()
  self:select_prev_file()
end

---@param pull_request PullRequest
---@param review octo.fragments.PullRequestReview & { comment_count: integer }
---@return ReviewBrowser
function ReviewBrowser:new(pull_request, review)
  local this = {
    id = -1,
    review_id = review.id,
    selected_review = review,
    pull_request = pull_request,
    threads = {},
  }
  setmetatable(this, self)
  this:update_threads(pull_request.reviewThreads.nodes)
  return this
end

---@param threads octo.ReviewThread[]
function ReviewBrowser:update_threads(threads)
  self.pull_request.reviewThreads.nodes = threads
  self.threads = {}

  for _, thread in ipairs(threads) do
    normalize_thread(thread)
    if #matching_review_comments(thread, self.review_id) > 0 then
      self.threads[thread.id] = thread
    end
  end

  if self.layout then
    self.layout:update_files()
  end
end

---@return ReviewBrowserThreadEntry[]
function ReviewBrowser:build_entries()
  local entries = {
    {
      kind = "summary",
      id = "summary",
      label = "Review summary",
      summary = utils.is_blank(utils.trim(self.selected_review.body)) and utils.state_msg_map[self.selected_review.state]
        or self.selected_review.body,
      comment_count = self.selected_review.comment_count,
    },
  }

  local threads = vim.tbl_values(self.threads)
  table.sort(threads, function(left, right)
    if left.path == right.path then
      local left_line = thread_start_line(left)
      local right_line = thread_start_line(right)
      if left_line == right_line then
        return left.id < right.id
      end
      return left_line < right_line
    end
    return left.path < right.path
  end)

  for _, thread in ipairs(threads) do
    local review_comments = matching_review_comments(thread, self.review_id)
    local start_line = thread_start_line(thread)
    local end_line = thread_end_line(thread)
    local line_range = start_line == end_line and tostring(start_line) or string.format("%d-%d", start_line, end_line)

    table.insert(entries, {
      kind = "thread",
      id = thread.id,
      label = string.format("%s:%s", thread.path, line_range),
      summary = comment_summary(review_comments[1]),
      comment_count = #review_comments,
      path = thread.path,
      basename = utils.path_basename(thread.path),
      extension = utils.path_extension(thread.path),
      isResolved = thread.isResolved,
      isOutdated = thread.isOutdated,
      thread = thread,
    })
  end

  return entries
end

function ReviewBrowser:open()
  self.layout = ReviewBrowserLayout:new(self)
  self.layout:open()
end

function ReviewBrowser:create()
  utils.error "Start or resume a review from the pull request buffer to add review comments"
end

---@param pull_request PullRequest
---@param review octo.fragments.PullRequestReview
function M.open(pull_request, review)
  review.author = review.author or { login = review_author(review) }
  review.comment_count = review.comments and review.comments.totalCount or 0
  review.display_date = format_review_datetime(review.createdAt)

  local browser = ReviewBrowser:new(pull_request, review)
  browser:open()
end

return M

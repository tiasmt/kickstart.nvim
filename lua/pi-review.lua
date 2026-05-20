-- pi-review.nvim
--
-- Neovim plugin for reviewing agent-generated code changes.
-- Works in tandem with the pi-review extension (extension.ts).
--
-- Setup (add to your init.lua):
--   require("pi-review").setup()          -- default keymaps
--   require("pi-review").setup({          -- custom keymaps
--     keymap_comment = "<leader>rc",
--     keymap_list    = "<leader>rl",
--     keymap_submit  = "<leader>rs",
--     keymap_review  = "<leader>rp",
--   })
--
-- Commands:
--   :PiReview          Open the review sidebar: lists all changed files with
--                      comment-status badges and renders existing comments as
--                      virtual text in open buffers.
--   :PiReviewComment   Add a comment on the current line or visual selection.
--   :PiReviewList      Show all pending comments in a floating window.
--   :PiReviewSubmit    Send all comments to the pi agent via RPC and clear session.
--   :PiReviewClear     Discard the current review session without submitting.
--
-- Sidebar badges:
--   ●  (colored)  — file has at least one comment
--   ○  (muted)    — file has not been commented on yet
--
-- Sidebar keymaps (inside the sidebar window):
--   <CR> / l / o  Open the file under the cursor in the editor window
--   R             Re-read the session file and refresh the sidebar
--   q             Close the sidebar
--
-- Diff highlights (applied automatically when a changed file is opened):
--   Added lines  — full-line green background (links to DiffAdd; override PiReviewAdded)
--
-- Change navigation keymaps (default, customisable via setup opts):
--   <leader>n  Go to the next changed range in the current buffer
--   <leader>b  Go to the previous changed range in the current buffer
--
-- Navigation uses the pre-computed changedLines from the review session
-- (written by the pi-review extension).  No extra git subprocess is needed.
--
-- The review session file is expected at <cwd>/.pi/review-session.json.
-- That file is written by /review:start inside pi and updated by this plugin.

local M = {}

-- ---------------------------------------------------------------------------
-- Defaults
-- ---------------------------------------------------------------------------

local DEFAULT_KEYMAP_COMMENT = "<leader>rc"
local DEFAULT_KEYMAP_LIST    = "<leader>rl"
local DEFAULT_KEYMAP_SUBMIT  = "<leader>rs"
local DEFAULT_KEYMAP_REVIEW      = "<leader>rp"  -- toggle the review sidebar
local DEFAULT_KEYMAP_NEXT_CHANGE = "<leader>n"   -- jump to next changed hunk
local DEFAULT_KEYMAP_PREV_CHANGE = "<leader>b"   -- jump to previous changed hunk

-- Width of the sidebar window in columns.
local SIDEBAR_WIDTH = 42

-- Namespace for virtual text extmarks in editor buffers.
local ns = vim.api.nvim_create_namespace("pi_review")

-- Namespace for highlight extmarks inside the sidebar buffer.
local sidebar_ns = vim.api.nvim_create_namespace("pi_review_sidebar")

-- Namespace for git-diff highlight extmarks (added/removed lines).
-- Kept separate from `ns` so diff highlights can be cleared independently.
local diff_ns = vim.api.nvim_create_namespace("pi_review_diff")



-- ---------------------------------------------------------------------------
-- Sidebar state
-- All mutable sidebar state lives here so it is easy to reason about and
-- reset when the window is closed.
-- ---------------------------------------------------------------------------

local sidebar = {
  bufnr    = nil,  -- handle of the scratch buffer backing the sidebar
  winnr    = nil,  -- handle of the sidebar window
  line_map = {},   -- 1-indexed line number → relative file path
                   -- Only set for lines that correspond to a file entry.
}

-- ---------------------------------------------------------------------------
-- State file I/O
-- ---------------------------------------------------------------------------

local function session_path()
  return vim.fn.getcwd() .. "/.pi/review-session.json"
end

local function read_session()
  local path = session_path()
  local f = io.open(path, "r")
  if not f then
    return nil, "No review session file found at " .. path .. ". Run /review:start in pi first."
  end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, raw)
  if not ok then
    return nil, "Failed to parse review-session.json: " .. tostring(data)
  end
  return data, nil
end

local function write_session(session)
  local dir = vim.fn.getcwd() .. "/.pi"
  vim.fn.mkdir(dir, "p")
  local path = session_path()
  local f = io.open(path, "w")
  if not f then
    return "Failed to write " .. path
  end
  f:write(vim.json.encode(session) .. "\n")
  f:close()
  return nil
end

-- ---------------------------------------------------------------------------
-- Virtual text helpers
-- ---------------------------------------------------------------------------

-- Clear all pi-review virtual text from a buffer.
local function clear_virtual_text(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

-- Render all session comments as virtual text in the appropriate buffers.
-- Only buffers that are currently open are updated; others are updated when
-- :PiReview is run again or when the buffer is opened.
local function render_virtual_text(session)
  if not session or not session.comments then return end

  -- Group comments by file for efficiency.
  local by_file = {}
  for _, c in ipairs(session.comments) do
    if not by_file[c.file] then by_file[c.file] = {} end
    table.insert(by_file[c.file], c)
  end

  local cwd = vim.fn.getcwd()
  for rel_path, comments in pairs(by_file) do
    local abs_path = cwd .. "/" .. rel_path
    local bufnr = vim.fn.bufnr(abs_path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
      clear_virtual_text(bufnr)
      for _, c in ipairs(comments) do
        -- Lines in nvim extmarks are 0-based.
        local line0 = c.startLine - 1
        local label = "  pi: " .. c.comment
        vim.api.nvim_buf_set_extmark(bufnr, ns, line0, 0, {
          virt_text     = { { label, "DiagnosticVirtualTextInfo" } },
          virt_text_pos = "eol",
        })
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Diff highlighting
-- ---------------------------------------------------------------------------

-- Find the bufnr whose name exactly matches abs_path among all loaded buffers.
-- vim.fn.bufnr() does Vim-style pattern matching which can silently fail on
-- paths with special characters or when the buffer was opened via a symlink.
-- Iterating with nvim_buf_get_name() is explicit and always correct.
local function find_loaded_bufnr(abs_path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr)
      and vim.api.nvim_buf_get_name(bufnr) == abs_path
    then
      return bufnr
    end
  end
  return -1
end

-- Apply diff highlights to every currently-loaded buffer that belongs to a
-- changed file in the session.
--
-- Uses the pre-computed changedLines ranges written by the pi-review extension
-- — no git subprocess is needed.
--
-- Calling this function multiple times is safe: it clears diff_ns before
-- re-applying, so no duplicate extmarks accumulate.
local function render_diff_highlights(session)
  if not session then return end

  local cwd = vim.fn.getcwd()

  for _, changed_file in ipairs(session.changedFiles or {}) do
    local rel_path = changed_file.path
    local abs_path = cwd .. "/" .. rel_path
    local bufnr    = find_loaded_bufnr(abs_path)
    if bufnr == -1 then goto continue end

    -- Clear any previous diff extmarks for this buffer.
    vim.api.nvim_buf_clear_namespace(bufnr, diff_ns, 0, -1)

    local line_count = vim.api.nvim_buf_line_count(bufnr)

    -- Expand each LineRange and highlight every line within it.
    -- "end" is a Lua keyword, so the JSON key must be accessed via ["end"].
    for _, range in ipairs(changed_file.changedLines or {}) do
      for line1 = range.start, range["end"] do
        if line1 >= 1 and line1 <= line_count then
          vim.api.nvim_buf_set_extmark(bufnr, diff_ns, line1 - 1, 0, {
            line_hl_group = "PiReviewAdded",
            priority      = 10,
          })
        end
      end
    end

    ::continue::
  end
end

-- ---------------------------------------------------------------------------
-- Change navigation
-- ---------------------------------------------------------------------------

-- Return the sorted list of changed-range start line numbers (1-based) for
-- the file currently open in the active buffer, sourced from the review
-- session's pre-computed changedLines.
--
-- Returns nil (with a user notification) when the data is unavailable.
local function change_starts_for_current_file()
  local session, err = read_session()
  if not session then
    vim.notify("pi review: " .. err, vim.log.levels.INFO)
    return nil
  end

  local abs_path = vim.api.nvim_buf_get_name(0)
  local cwd      = vim.fn.getcwd() .. "/"
  if abs_path:sub(1, #cwd) ~= cwd then
    vim.notify("pi review: current file is outside the project root.", vim.log.levels.INFO)
    return nil
  end
  local rel_path = abs_path:sub(#cwd + 1)

  -- Find the ChangedFile entry whose path matches the current buffer.
  for _, changed_file in ipairs(session.changedFiles or {}) do
    if changed_file.path == rel_path then
      local ranges = changed_file.changedLines or {}
      if #ranges == 0 then
        vim.notify("pi review: no changed lines recorded for this file.", vim.log.levels.INFO)
        return nil
      end
      -- changedLines is already sorted and merged by the extension; extract
      -- the start of each range as the navigation target.
      local starts = {}
      for _, range in ipairs(ranges) do
        table.insert(starts, range.start)
      end
      return starts
    end
  end

  vim.notify("pi review: current file is not in the review session.", vim.log.levels.INFO)
  return nil
end

local function goto_next_change()
  local starts = change_starts_for_current_file()
  if not starts then return end

  local cursor_line = vim.fn.line(".")
  for _, line_nr in ipairs(starts) do
    if line_nr > cursor_line then
      vim.cmd(tostring(line_nr))  -- same as typing :N in command mode
      vim.cmd("normal! zz")
      return
    end
  end

  vim.notify("pi review: no more changes after cursor.", vim.log.levels.INFO)
end

local function goto_prev_change()
  local starts = change_starts_for_current_file()
  if not starts then return end

  local cursor_line = vim.fn.line(".")
  for i = #starts, 1, -1 do
    if starts[i] < cursor_line then
      vim.cmd(tostring(starts[i]))  -- same as typing :N in command mode
      vim.cmd("normal! zz")
      return
    end
  end

  vim.notify("pi review: no more changes before cursor.", vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------------
-- UUID generation (Lua, no external deps)
-- ---------------------------------------------------------------------------

local function new_uuid()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  math.randomseed(os.time() + math.random(0, 1000))
  return template:gsub("[xy]", function(c)
    local v = c == "x" and math.random(0, 15) or math.random(8, 11)
    return string.format("%x", v)
  end)
end

-- ---------------------------------------------------------------------------
-- Sidebar — highlight groups
-- Defined with `default = true` so the user can override them in their
-- colorscheme or after/colors autocmd without fighting this plugin.
-- ---------------------------------------------------------------------------

local function setup_highlights()
  -- Commented file badge: bright, draws the eye to reviewed items.
  vim.api.nvim_set_hl(0, "PiReviewCommented",  { link = "DiagnosticInfo", default = true })
  -- Unreviewed file badge: muted so it recedes into the background.
  vim.api.nvim_set_hl(0, "PiReviewUnreviewed", { link = "Comment",        default = true })
  -- Sidebar title.
  vim.api.nvim_set_hl(0, "PiReviewHeader",     { link = "Title",          default = true })
  -- Stats line and decorative separators.
  vim.api.nvim_set_hl(0, "PiReviewMeta",       { link = "Special",        default = true })
  vim.api.nvim_set_hl(0, "PiReviewSeparator",  { link = "NonText",        default = true })
  -- Diff: added lines get a green full-line background (links to DiffAdd so any
  -- colorscheme that themes DiffAdd will automatically look correct here).
  vim.api.nvim_set_hl(0, "PiReviewAdded", { link = "DiffAdd", default = true })
end

-- ---------------------------------------------------------------------------
-- Sidebar — rendering
-- Rebuilds the entire sidebar buffer content from the current session.
-- Called both on initial open and after every comment addition.
-- ---------------------------------------------------------------------------

local function sidebar_render(session)
  if not sidebar.bufnr or not vim.api.nvim_buf_is_valid(sidebar.bufnr) then return end

  -- Build a per-file comment count from the flat comments list.
  local comment_counts = {}
  for _, c in ipairs(session.comments or {}) do
    comment_counts[c.file] = (comment_counts[c.file] or 0) + 1
  end

  local files = session.changedFiles or {}

  local reviewed_count = 0
  for _, f in ipairs(files) do
    if (comment_counts[f] or 0) > 0 then
      reviewed_count = reviewed_count + 1
    end
  end

  -- Reset the line→file mapping; it will be repopulated below.
  sidebar.line_map = {}

  local lines  = {}  -- text content, one string per line
  local hl_ops = {}  -- { line0, col_start, col_end, hl_group }

  local sep = string.rep("─", SIDEBAR_WIDTH - 1)

  -- ── Header ──
  table.insert(lines, " PI REVIEW")
  table.insert(hl_ops, { #lines - 1, 0, -1, "PiReviewHeader" })

  -- ── Stats ──
  local stats = string.format(
    "  %d file%s  ·  %d commented",
    #files,
    #files == 1 and "" or "s",
    reviewed_count
  )
  table.insert(lines, stats)
  table.insert(hl_ops, { #lines - 1, 0, -1, "PiReviewMeta" })

  -- ── Separator ──
  table.insert(lines, sep)
  table.insert(hl_ops, { #lines - 1, 0, -1, "PiReviewSeparator" })

  -- ── One line per changed file ──
  for _, changed_file in ipairs(files) do
    local rel_path    = changed_file.path
    local count       = comment_counts[rel_path] or 0
    local is_reviewed = count > 0

    -- ●  = has comments (filled, colored)
    -- ○  = no comments yet (hollow, muted)
    local icon = is_reviewed and "● " or "○ "
    local hl   = is_reviewed and "PiReviewCommented" or "PiReviewUnreviewed"

    -- Append a parenthetical comment count only when there are comments so
    -- that the number draws attention without cluttering every line.
    local suffix = is_reviewed and (" (" .. count .. ")") or ""

    -- Truncate long paths so they never overflow the sidebar width.
    -- Layout: "  " (2) + icon (2) + path + suffix
    local max_path_len = SIDEBAR_WIDTH - 4 - #suffix
    local display = rel_path
    if #display > max_path_len then
      display = "…" .. display:sub(-(max_path_len - 1))
    end

    table.insert(lines, "  " .. icon .. display .. suffix)
    table.insert(hl_ops, { #lines - 1, 0, -1, hl })

    -- Record the 1-indexed line so activate_line() can look up the path.
    sidebar.line_map[#lines] = rel_path
  end

  -- ── Footer ──
  table.insert(lines, sep)
  table.insert(hl_ops, { #lines - 1, 0, -1, "PiReviewSeparator" })
  table.insert(lines, "  <CR> open  ·  R refresh  ·  q close")
  table.insert(hl_ops, { #lines - 1, 0, -1, "PiReviewSeparator" })

  -- Write all lines at once (avoids flicker).
  vim.bo[sidebar.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(sidebar.bufnr, 0, -1, false, lines)
  vim.bo[sidebar.bufnr].modifiable = false

  -- Apply highlights.
  vim.api.nvim_buf_clear_namespace(sidebar.bufnr, sidebar_ns, 0, -1)
  for _, op in ipairs(hl_ops) do
    vim.api.nvim_buf_add_highlight(sidebar.bufnr, sidebar_ns, op[4], op[1], op[2], op[3])
  end
end

-- ---------------------------------------------------------------------------
-- Sidebar — file navigation
-- ---------------------------------------------------------------------------

-- Open rel_path in the best available editor window (i.e. not the sidebar).
-- If no other window exists, creates a vertical split to the right.
local function sidebar_open_file(rel_path)
  local target_win = nil
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= sidebar.winnr then
      target_win = win
      break
    end
  end

  if not target_win then
    -- The sidebar is the only window; split a new editor pane beside it.
    vim.api.nvim_set_current_win(sidebar.winnr)
    vim.cmd("vsplit")
    target_win = vim.api.nvim_get_current_win()
  end

  local abs_path = vim.fn.getcwd() .. "/" .. rel_path
  vim.api.nvim_set_current_win(target_win)
  vim.cmd("edit " .. vim.fn.fnameescape(abs_path))

  -- Re-render virtual text and diff highlights now that this buffer is loaded.
  local session, _ = read_session()
  if session then
    render_virtual_text(session)
    render_diff_highlights(session)
  end
end

-- Called when the user presses <CR>/l/o inside the sidebar.
local function sidebar_activate_line()
  if not sidebar.winnr or not vim.api.nvim_win_is_valid(sidebar.winnr) then return end
  -- nvim_win_get_cursor returns { row, col }, row is 1-indexed.
  local line1 = vim.api.nvim_win_get_cursor(sidebar.winnr)[1]
  local rel_path = sidebar.line_map[line1]
  if not rel_path then return end  -- header / separator / footer line
  sidebar_open_file(rel_path)
end

-- ---------------------------------------------------------------------------
-- Sidebar — open / close / refresh
-- ---------------------------------------------------------------------------

local function sidebar_close()
  if sidebar.winnr and vim.api.nvim_win_is_valid(sidebar.winnr) then
    vim.api.nvim_win_close(sidebar.winnr, true)
  end
  -- State is also cleared by the BufWipeout autocmd registered in sidebar_open,
  -- but we reset here too in case close is called before the autocmd fires.
  sidebar.winnr    = nil
  sidebar.bufnr    = nil
  sidebar.line_map = {}
end

-- Opens (or focuses) the review sidebar for the given session.
-- Creates a fresh scratch buffer and left-side window if needed.
local function sidebar_open(session)
  setup_highlights()

  -- Create the scratch buffer only if we don't already have a valid one.
  if not sidebar.bufnr or not vim.api.nvim_buf_is_valid(sidebar.bufnr) then
    sidebar.bufnr = vim.api.nvim_create_buf(false, true)  -- unlisted, scratch

    vim.bo[sidebar.bufnr].buftype   = "nofile"
    vim.bo[sidebar.bufnr].bufhidden = "wipe"   -- auto-wipe when window closes
    vim.bo[sidebar.bufnr].swapfile  = false
    vim.bo[sidebar.bufnr].filetype  = "pi-review-sidebar"

    -- When the buffer is wiped (window closed by any means), reset state so
    -- the next call to sidebar_open() builds a fresh buffer and window.
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer   = sidebar.bufnr,
      once     = true,
      callback = function()
        sidebar.winnr    = nil
        sidebar.bufnr    = nil
        sidebar.line_map = {}
      end,
    })
  end

  -- Open the window only if it is not already visible.
  if not sidebar.winnr or not vim.api.nvim_win_is_valid(sidebar.winnr) then
    local cur_win = vim.api.nvim_get_current_win()

    -- `topleft Nvsplit` creates a full-height vertical split on the far left,
    -- consistent with neo-tree's position so both can coexist or swap cleanly.
    vim.cmd("topleft " .. SIDEBAR_WIDTH .. "vsplit")
    sidebar.winnr = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(sidebar.winnr, sidebar.bufnr)

    -- Strip all the UI chrome from the sidebar window.
    local wo = vim.wo[sidebar.winnr]
    wo.number         = false
    wo.relativenumber = false
    wo.signcolumn     = "no"
    wo.foldcolumn     = "0"
    wo.wrap           = false
    wo.winfixwidth    = true   -- prevent layout reflow when other windows resize
    wo.cursorline     = true   -- highlight the row under the cursor for easy tracking

    -- Return focus to whichever editor window was active before we opened.
    vim.api.nvim_set_current_win(cur_win)
  end

  -- Register buffer-local keymaps (idempotent — safe to re-register).
  local buf  = sidebar.bufnr
  local opts = { buffer = buf, nowait = true, silent = true }

  vim.keymap.set("n", "<CR>", sidebar_activate_line,
    vim.tbl_extend("force", opts, { desc = "pi: open file under cursor" }))
  vim.keymap.set("n", "l", sidebar_activate_line,
    vim.tbl_extend("force", opts, { desc = "pi: open file under cursor" }))
  vim.keymap.set("n", "o", sidebar_activate_line,
    vim.tbl_extend("force", opts, { desc = "pi: open file under cursor" }))
  vim.keymap.set("n", "q", sidebar_close,
    vim.tbl_extend("force", opts, { desc = "pi: close review sidebar" }))
  vim.keymap.set("n", "R", function()
    local s, e = read_session()
    if s then
      sidebar_render(s)
      render_virtual_text(s)
      vim.notify("pi review: sidebar refreshed.", vim.log.levels.INFO)
    else
      vim.notify(e, vim.log.levels.WARN)
    end
  end, vim.tbl_extend("force", opts, { desc = "pi: refresh review sidebar" }))

  sidebar_render(session)
end

-- Refresh sidebar content in-place. Called after every comment write.
-- No-op when the sidebar is not currently open, so callers need no guard.
local function sidebar_refresh()
  if not sidebar.bufnr or not vim.api.nvim_buf_is_valid(sidebar.bufnr) then return end
  local session, _ = read_session()
  if session then sidebar_render(session) end
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

-- :PiReview
-- Loads the review session, opens the review sidebar, and renders any
-- existing comments as virtual text in open buffers.
local function cmd_review()
  local session, err = read_session()
  if not session then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  if not session.changedFiles or #session.changedFiles == 0 then
    vim.notify("Review session has no changed files.", vim.log.levels.WARN)
    return
  end

  sidebar_open(session)
  render_virtual_text(session)
  render_diff_highlights(session)

  local n            = #session.comments
  local comment_note = n == 0 and "no comments yet" or (n .. " existing comment(s)")
  vim.notify(
    string.format(
      "pi review: %d file(s) to review, %s. Press <CR> in the sidebar to open a file.",
      #session.changedFiles,
      comment_note
    ),
    vim.log.levels.INFO
  )
end

-- :PiReviewComment
-- Adds a comment on the current line (normal mode) or visual selection.
-- Prompts for the comment text via vim.ui.input.
local function cmd_comment(line1, line2)
  local session, err = read_session()
  if not session then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  -- Resolve the file relative to cwd.
  local abs_path = vim.api.nvim_buf_get_name(0)
  local cwd      = vim.fn.getcwd()
  local rel_path = abs_path
  if rel_path:sub(1, #cwd) == cwd then
    rel_path = rel_path:sub(#cwd + 2)  -- strip leading slash too
  end

  if rel_path == "" then
    vim.notify("Cannot comment on an unnamed buffer.", vim.log.levels.WARN)
    return
  end

  -- Capture the selected lines.
  local selected_lines = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)
  local selected_text  = table.concat(selected_lines, "\n")

  vim.ui.input({ prompt = "Comment: " }, function(input)
    if not input or input == "" then return end

    local comment = {
      id           = new_uuid(),
      file         = rel_path,
      startLine    = line1,
      endLine      = line2,
      selectedText = selected_text,
      comment      = input,
      createdAt    = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }

    table.insert(session.comments, comment)
    local write_err = write_session(session)
    if write_err then
      vim.notify("Failed to save comment: " .. write_err, vim.log.levels.ERROR)
      return
    end

    -- Update virtual text and sidebar immediately.
    render_virtual_text(session)
    sidebar_refresh()

    vim.notify(
      string.format("Comment added (%d total).", #session.comments),
      vim.log.levels.INFO
    )
  end)
end

-- :PiReviewList
-- Shows all pending comments in a floating window.
local function cmd_list()
  local session, err = read_session()
  if not session then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  if #session.comments == 0 then
    vim.notify("No comments yet. Use :PiReviewComment to add one.", vim.log.levels.INFO)
    return
  end

  -- Build display lines.
  local lines = {
    string.format("pi review — %d comment(s)", #session.comments),
    string.rep("─", 60),
  }
  for i, c in ipairs(session.comments) do
    local line_label = c.startLine == c.endLine
      and ("L" .. c.startLine)
      or  ("L" .. c.startLine .. "-" .. c.endLine)
    table.insert(lines, string.format("%d. %s:%s", i, c.file, line_label))
    table.insert(lines, "   " .. c.comment)
    table.insert(lines, "")
  end

  -- Open a scratch floating window.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype    = "nofile"

  local width  = math.min(80, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)
  local row    = math.floor((vim.o.lines   - height) / 2)
  local col    = math.floor((vim.o.columns - width)  / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = "rounded",
    title     = " pi review ",
    title_pos = "center",
  })

  local close = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set("n", "q",     close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })
end

-- :PiReviewSubmit
-- Sends all comments to the pi agent by spawning `pi --mode rpc`, sending
-- a prompt command with the formatted review text, then waiting for agent_end.
local function cmd_submit()
  local session, err = read_session()
  if not session then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  if #session.comments == 0 then
    vim.notify("No comments to submit. Add comments with :PiReviewComment first.", vim.log.levels.WARN)
    return
  end

  if not session.sessionFile or session.sessionFile == vim.NIL then
    vim.notify(
      "No pi session file recorded. Re-run /review:start in pi to capture the session path.",
      vim.log.levels.WARN
    )
    return
  end

  -- Build the review prompt (mirrors formatReviewPrompt in extension.ts).
  local head_short = session.headCommit and session.headCommit:sub(1, 8) or "unknown"
  local parts = {
    string.format(
      "Code review on changes from %s to %s.\nAddress all %d comment(s) below, then commit the fixes.\n",
      session.baseRef,
      head_short,
      #session.comments
    ),
  }
  for _, c in ipairs(session.comments) do
    local line_label = c.startLine == c.endLine
      and ("line " .. c.startLine)
      or  ("lines " .. c.startLine .. "-" .. c.endLine)
    table.insert(parts, string.format("[%s  %s]", c.file, line_label))
    if c.selectedText and c.selectedText:match("%S") then
      table.insert(parts, "```")
      table.insert(parts, (c.selectedText:gsub("%s+$", "")))
      table.insert(parts, "```")
    end
    table.insert(parts, "Comment: " .. c.comment)
    table.insert(parts, "")
  end
  local prompt_text = table.concat(parts, "\n")

  local rpc_command = vim.json.encode({ type = "prompt", message = prompt_text }) .. "\n"

  vim.notify("Submitting review to pi agent...", vim.log.levels.INFO)

  local stderr_buf = {}
  local agent_ended = false

  local job_id = vim.fn.jobstart(
    { "pi", "--mode", "rpc", "--session", session.sessionFile },
    {
      stdin           = "pipe",
      stdout_buffered = false,
      stderr_buffered = false,

      on_stdout = function(_, data)
        for _, line in ipairs(data) do
          if line ~= "" then
            local ok, event = pcall(vim.json.decode, line)
            if ok and event and event.type == "agent_end" then
              agent_ended = true
            end
          end
        end
      end,

      on_stderr = function(_, data)
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(stderr_buf, line) end
        end
      end,

      on_exit = function(_, code)
        vim.schedule(function()
          if code ~= 0 and not agent_ended then
            vim.notify(
              "pi RPC process exited with code " .. code .. ".\n" .. table.concat(stderr_buf, "\n"),
              vim.log.levels.ERROR
            )
          else
            vim.notify("Review submitted. The agent is addressing your comments.", vim.log.levels.INFO)
          end
        end)
      end,
    }
  )

  if job_id <= 0 then
    vim.notify("Failed to start pi. Is it installed and in PATH?", vim.log.levels.ERROR)
    return
  end

  vim.fn.chansend(job_id, rpc_command)
  vim.fn.chanclose(job_id, "stdin")

  -- Delete session file so a fresh review can be started afterwards.
  os.remove(session_path())

  -- Close sidebar and clear all extmarks from open buffers.
  sidebar_close()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      clear_virtual_text(bufnr)
      vim.api.nvim_buf_clear_namespace(bufnr, diff_ns, 0, -1)
    end
  end
end

-- :PiReviewClear
-- Discards the current review session without submitting.
local function cmd_clear()
  local session, err = read_session()
  if not session then
    vim.notify(err .. " Nothing to clear.", vim.log.levels.WARN)
    return
  end

  vim.ui.select(
    { "Yes, discard " .. #session.comments .. " comment(s)", "No, keep the session" },
    { prompt = "Discard review session?" },
    function(choice)
      if not choice or choice:sub(1, 3) ~= "Yes" then return end
      os.remove(session_path())
      sidebar_close()
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
          clear_virtual_text(bufnr)
          vim.api.nvim_buf_clear_namespace(bufnr, diff_ns, 0, -1)
        end
      end
      vim.notify("Review session cleared.", vim.log.levels.INFO)
    end
  )
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup(opts)
  opts = opts or {}
  local keymap_comment     = opts.keymap_comment     or DEFAULT_KEYMAP_COMMENT
  local keymap_list        = opts.keymap_list        or DEFAULT_KEYMAP_LIST
  local keymap_submit      = opts.keymap_submit      or DEFAULT_KEYMAP_SUBMIT
  local keymap_review      = opts.keymap_review      or DEFAULT_KEYMAP_REVIEW
  local keymap_next_change = opts.keymap_next_change or DEFAULT_KEYMAP_NEXT_CHANGE
  local keymap_prev_change = opts.keymap_prev_change or DEFAULT_KEYMAP_PREV_CHANGE

  -- ── Commands ──────────────────────────────────────────────────────────────

  vim.api.nvim_create_user_command("PiReview", function()
    cmd_review()
  end, { desc = "Open pi review sidebar with changed files" })

  -- :PiReviewComment works in both normal mode (current line) and visual mode.
  vim.api.nvim_create_user_command("PiReviewComment", function(cmd_opts)
    cmd_comment(cmd_opts.line1, cmd_opts.line2)
  end, { range = true, desc = "Add a review comment on the current line or selection" })

  vim.api.nvim_create_user_command("PiReviewList", function()
    cmd_list()
  end, { desc = "Show all pending review comments" })

  vim.api.nvim_create_user_command("PiReviewSubmit", function()
    cmd_submit()
  end, { desc = "Submit all review comments to the pi agent" })

  vim.api.nvim_create_user_command("PiReviewClear", function()
    cmd_clear()
  end, { desc = "Discard the current review session" })

  -- ── Keymaps ───────────────────────────────────────────────────────────────

  -- Toggle the sidebar (open if closed, close if open).
  vim.keymap.set("n", keymap_review, function()
    if sidebar.winnr and vim.api.nvim_win_is_valid(sidebar.winnr) then
      sidebar_close()
    else
      cmd_review()
    end
  end, { desc = "pi: toggle review sidebar" })

  -- Normal mode: comment on current line.
  vim.keymap.set("n", keymap_comment, function()
    local line = vim.fn.line(".")
    cmd_comment(line, line)
  end, { desc = "pi: add review comment on current line" })

  -- Visual mode: comment on selected range.
  vim.keymap.set("v", keymap_comment, function()
    -- Exit visual mode first so the '< '> marks are set correctly.
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "x", false)
    local line1 = vim.fn.line("'<")
    local line2 = vim.fn.line("'>")
    cmd_comment(line1, line2)
  end, { desc = "pi: add review comment on selection" })

  vim.keymap.set("n", keymap_list,        cmd_list,         { desc = "pi: list review comments" })
  vim.keymap.set("n", keymap_submit,      cmd_submit,       { desc = "pi: submit review to agent" })
  vim.keymap.set("n", keymap_next_change, goto_next_change, { desc = "pi: go to next change" })
  vim.keymap.set("n", keymap_prev_change, goto_prev_change, { desc = "pi: go to previous change" })
end

return M

-- IDE-style solution/file explorer using neo-tree.
--
-- Why neo-tree over oil or netrw:
--   - Persistent sidebar that does not replace your editing buffer
--   - Native git status decorations per-file
--   - LSP diagnostics shown inline (errors/warnings next to files)
--   - Live filesystem watching — no manual refresh needed
--   - Multiple "sources": filesystem, open buffers, git status
--
-- Key bindings (normal mode, outside the tree):
--   `          Toggle the tree open/closed
--   <leader>bf Reveal the current file in the tree
--
-- Key bindings (inside the tree window):
--   <CR> / l   Open file
--   s          Open in vertical split
--   S          Open in horizontal split
--   t          Open in new tab
--   a          Add file (shows relative path prompt)
--   A          Add directory
--   d          Delete
--   r          Rename
--   y / x / p  Copy / cut / paste
--   H          Toggle hidden files
--   /          Fuzzy-find inside tree
--   [g / ]g    Jump to previous / next git-modified file
--   R          Refresh
--   q          Close tree
--   ?          Show all available mappings

return {
  'nvim-neo-tree/neo-tree.nvim',
  version = '*',
  -- Load at startup so the tree is ready immediately.
  -- Lazy-loading a sidebar panel introduces perceptible delay and layout
  -- jank on the first open; not worth the tiny startup saving.
  lazy = false,
  dependencies = {
    'nvim-lua/plenary.nvim',
    'nvim-tree/nvim-web-devicons',
    'MunifTanjim/nui.nvim',
  },

  keys = {
    { '`',          '<cmd>Neotree toggle<CR>',  desc = 'Toggle file explorer', silent = true },
    { '<leader>bf', '<cmd>Neotree reveal<CR>', desc = '[B]uffer: reveal in [F]ile explorer', silent = true },
  },

  init = function()
    -- When Neovim is invoked with a directory path (e.g. `nvim .`), open
    -- neo-tree automatically instead of netrw's plain listing.
    vim.api.nvim_create_autocmd('BufEnter', {
      group = vim.api.nvim_create_augroup('neotree-open-on-directory', { clear = true }),
      desc = 'Open Neo-tree when Neovim is started with a directory argument',
      once = true,
      callback = function()
        local bufname = vim.api.nvim_buf_get_name(0)
        local stats = (vim.uv or vim.loop).fs_stat(bufname)
        if stats and stats.type == 'directory' then
          require('neo-tree')
        end
      end,
    })
  end,

  opts = {
    -- Close the tree automatically when it becomes the only window.
    -- Prevents being stranded in a tree pane with no editor buffer.
    close_if_last_window = true,

    popup_border_style = 'rounded',
    enable_git_status = true,
    enable_diagnostics = true,

    -- Case-insensitive sort so foo.cs sorts before Foo.Tests.cs
    sort_case_insensitive = true,

    -- ── Shared component configuration ───────────────────────────────────
    default_component_configs = {
      container = {
        enable_character_fade = true,
      },
      indent = {
        indent_size = 2,
        padding = 1,
        with_markers = true,
        indent_marker = '│',
        last_indent_marker = '└',
        highlight = 'NeoTreeIndentMarker',
        -- Expander triangles instead of plain +/- so the tree looks richer
        with_expanders = true,
        expander_collapsed = '',
        expander_expanded = '',
        expander_highlight = 'NeoTreeExpander',
      },
      icon = {
        folder_closed = '',
        folder_open = '',
        folder_empty = '󰜌',
        -- Fallback for files without a specific devicon
        default = '󰈙',
        highlight = 'NeoTreeFileIcon',
      },
      modified = {
        -- Shown next to files with unsaved changes
        symbol = ' ●',
        highlight = 'NeoTreeModified',
      },
      name = {
        trailing_slash = false,
        -- File names inherit the colour of their git status (green=new, red=deleted…)
        use_git_status_colors = true,
        highlight = 'NeoTreeFileName',
      },
      git_status = {
        symbols = {
          -- Matches the glyph set used by popular IDE themes
          added      = '✚',
          modified   = '',
          deleted    = '✖',
          renamed    = '󰁕',
          untracked  = '',
          ignored    = '',
          unstaged   = '󰄱',
          staged     = '',
          conflict   = '',
        },
      },
      diagnostics = {
        symbols = {
          hint  = '󰌵',
          info  = '',
          warn  = '',
          error = '',
        },
        highlights = {
          hint  = 'DiagnosticSignHint',
          info  = 'DiagnosticSignInfo',
          warn  = 'DiagnosticSignWarn',
          error = 'DiagnosticSignError',
        },
      },
    },

    -- ── Tree window layout ────────────────────────────────────────────────
    window = {
      position = 'left',
      width = 35,
      mapping_options = {
        noremap = true,
        nowait = true,
      },
      mappings = {
        ['<space>']       = { 'toggle_node', nowait = false },
        ['<2-LeftMouse>'] = 'open',
        ['<cr>']          = 'open',
        ['l']             = 'open',           -- feels natural for "enter"
        ['<esc>']         = 'cancel',
        -- Preview the file in a float without switching focus
        ['P'] = { 'toggle_preview', config = { use_float = true } },
        -- Splits — uppercase = horizontal, lowercase = vertical (aligns with Vim splits)
        ['S']             = 'open_split',
        ['s']             = 'open_vsplit',
        ['t']             = 'open_tabnew',
        -- Smart window-picker when you have multiple panes open
        ['w']             = 'open_with_window_picker',
        ['C']             = 'close_node',
        ['z']             = 'close_all_nodes',
        -- File operations
        ['a'] = { 'add', config = { show_path = 'relative' } },
        ['A']             = 'add_directory',
        ['d']             = 'delete',
        ['r']             = 'rename',
        ['y']             = 'copy_to_clipboard',
        ['x']             = 'cut_to_clipboard',
        ['p']             = 'paste_from_clipboard',
        ['c']             = 'copy',
        ['m']             = 'move',
        -- Tree management
        ['q']             = 'close_window',
        ['R']             = 'refresh',
        ['?']             = 'show_help',
        ['<']             = 'prev_source',
        ['>']             = 'next_source',
        ['i']             = 'show_file_details',
        ['H']             = 'toggle_hidden',
        ['e']             = 'toggle_auto_expand_width',
      },
    },

    -- ── Filesystem source ─────────────────────────────────────────────────
    filesystem = {
      filtered_items = {
        -- Hidden by default; press H inside tree to reveal
        visible = false,
        hide_dotfiles = true,
        hide_gitignored = true,
        hide_hidden = true,
        hide_by_name = {
          'node_modules',
          '.DS_Store',
          'thumbs.db',
        },
        never_show = {
          '.DS_Store',
          'thumbs.db',
        },
      },
      -- The tree automatically scrolls to and highlights the file you are editing.
      -- This is the "follow active editor" behaviour you see in VS Code / Rider.
      follow_current_file = {
        enabled = true,
        leave_dirs_open = false,
      },
      -- Collapse runs of single-child directories into one line — keeps the
      -- tree compact for deep Java-style or C# namespace layouts.
      group_empty_dirs = true,
      -- Take over directory navigation from netrw
      hijack_netrw_behavior = 'open_default',
      -- Use OS file-watcher so additions/deletions from other processes (git
      -- checkout, dotnet scaffold, etc.) appear without a manual :Neotree refresh.
      use_libuv_file_watcher = true,
      window = {
        mappings = {
          ['<bs>']   = 'navigate_up',
          ['.']      = 'set_root',
          ['H']      = 'toggle_hidden',
          ['/']      = 'fuzzy_finder',
          ['D']      = 'fuzzy_finder_directory',
          ['f']      = 'filter_on_submit',
          ['<C-x>']  = 'clear_filter',
          -- Jump between git hunks directly from the tree
          ['[g']     = 'prev_git_modified',
          [']g']     = 'next_git_modified',
          -- Ordering sub-menu via o-prefix
          ['oc'] = { 'order_by_created',      nowait = false },
          ['od'] = { 'order_by_diagnostics',  nowait = false },
          ['og'] = { 'order_by_git_status',   nowait = false },
          ['om'] = { 'order_by_modified',     nowait = false },
          ['on'] = { 'order_by_name',         nowait = false },
          ['os'] = { 'order_by_size',         nowait = false },
          ['ot'] = { 'order_by_type',         nowait = false },
        },
        fuzzy_finder_mappings = {
          ['<down>'] = 'move_cursor_down',
          ['<C-n>']  = 'move_cursor_down',
          ['<up>']   = 'move_cursor_up',
          ['<C-p>']  = 'move_cursor_up',
        },
      },
    },

    -- ── Open buffers source ───────────────────────────────────────────────
    -- Switch to this source with > to see all open buffers as a tree.
    buffers = {
      follow_current_file = {
        enabled = true,
        leave_dirs_open = false,
      },
      group_empty_dirs = true,
      show_unloaded = true,
      window = {
        mappings = {
          ['bd']   = 'buffer_delete',
          ['<bs>'] = 'navigate_up',
          ['.']    = 'set_root',
          ['od'] = { 'order_by_diagnostics', nowait = false },
          ['om'] = { 'order_by_modified',    nowait = false },
          ['on'] = { 'order_by_name',        nowait = false },
          ['os'] = { 'order_by_size',        nowait = false },
          ['ot'] = { 'order_by_type',        nowait = false },
        },
      },
    },

    -- ── Git status source ─────────────────────────────────────────────────
    -- Switch to this source with > to see only changed files.
    git_status = {
      window = {
        position = 'float',
        mappings = {
          ['A']  = 'git_add_all',
          ['gu'] = 'git_unstage_file',
          ['ga'] = 'git_add_file',
          ['gr'] = 'git_revert_file',
          ['gc'] = 'git_commit',
          ['gp'] = 'git_push',
          ['gg'] = 'git_commit_and_push',
          ['od'] = { 'order_by_diagnostics', nowait = false },
          ['om'] = { 'order_by_modified',    nowait = false },
          ['on'] = { 'order_by_name',        nowait = false },
          ['os'] = { 'order_by_size',        nowait = false },
          ['ot'] = { 'order_by_type',        nowait = false },
        },
      },
    },
  },
}

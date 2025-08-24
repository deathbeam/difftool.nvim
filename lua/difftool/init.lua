local default_config = {
  method = 'builtin',
  rename = {
    detect = false,
    similarity = 0.5,
    max_size = 1024 * 1024,
  },
  highlight = {
    A = 'DiffAdd',
    D = 'DiffDelete',
    M = 'DiffText',
    R = 'DiffChange',
  },
}

local layout = {
  left_win = nil,
  right_win = nil,
}

--- Set up a consistent layout with two diff windows
--- @param with_qf boolean whether to open the quickfix window
local function setup_layout(with_qf)
  if
    layout.left_win
    and vim.api.nvim_win_is_valid(layout.left_win)
    and layout.right_win
    and vim.api.nvim_win_is_valid(layout.right_win)
  then
    return false
  end

  vim.cmd.only()

  -- Save current window as left window
  layout.left_win = vim.api.nvim_get_current_win()

  -- Create right window
  vim.cmd.vsplit()
  layout.right_win = vim.api.nvim_get_current_win()

  -- Create quickfix window
  if with_qf then
    vim.cmd('botright copen')
  end
end

--- Edit a file in a specific window
--- @param winnr number
--- @param file string
local function edit_in(winnr, file)
  vim.api.nvim_win_call(winnr, function()
    local current = vim.fs.abspath(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(winnr)))

    -- Check if the current buffer is already the target file
    if current == (file and vim.fs.abspath(file) or '') then
      return
    end

    -- Read the file into the buffer
    vim.cmd.edit(vim.fn.fnameescape(file))
  end)
end

--- Diff two files
--- @param left_file string
--- @param right_file string
--- @param with_qf boolean? whether to open the quickfix window
local function diff_files(left_file, right_file, with_qf)
  setup_layout(with_qf or false)

  edit_in(layout.left_win, left_file)
  edit_in(layout.right_win, right_file)

  vim.cmd('diffoff!')
  vim.api.nvim_win_call(layout.left_win, vim.cmd.diffthis)
  vim.api.nvim_win_call(layout.right_win, vim.cmd.diffthis)
end

--- Diff two directories using external `diff` command
--- @param left_dir string
--- @param right_dir string
--- @return table[] list of quickfix entries
local function diff_directories_diffr(left_dir, right_dir)
  local output = vim.fn.system({ 'diff', '-qr', left_dir, right_dir })
  local lines = vim.split(output, '\n')
  --- @type table[]
  local qf_entries = {}

  for _, line in ipairs(lines) do
    local added = line:match('^Only in ([^:]+): (.+)$')
    local modified_left, modified_right = line:match('^Files (.+) and (.+) differ$')
    if added then
      local dir, file = line:match('^Only in ([^:]+): (.+)$')
      local status, left, right
      if vim.fn.fnamemodify(dir, ':p') == vim.fn.fnamemodify(left_dir, ':p') then
        status = 'D'
        left = dir .. '/' .. file
        right = right_dir .. '/' .. file
      else
        status = 'A'
        left = left_dir .. '/' .. file
        right = dir .. '/' .. file
      end
      table.insert(qf_entries, {
        filename = right,
        text = status,
        user_data = {
          diff = true,
          rel = file,
          left = left,
          right = right,
        },
      })
    elseif modified_left and modified_right then
      local rel = vim.fn
        .fnamemodify(modified_left, ':~:.')
        :gsub('^' .. vim.fn.fnamemodify(left_dir, ':~:.'), '')
      table.insert(qf_entries, {
        filename = modified_right,
        text = 'M',
        user_data = {
          diff = true,
          rel = rel,
          left = modified_left,
          right = modified_right,
        },
      })
    end
  end
  return qf_entries
end

--- Diff two directories using built-in Lua implementation
--- @param left_dir string
--- @param right_dir string
--- @param opt difftool.opt
--- @return table[] list of quickfix entries
local function diff_directories_builtin(left_dir, right_dir, opt)
  --- Helper to calculate file similarity
  --- @param file1 string
  --- @param file2 string
  --- @return number similarity ratio (0 to 1)
  local function calculate_similarity(file1, file2)
    local size1 = vim.fn.getfsize(file1)
    local size2 = vim.fn.getfsize(file2)

    -- skip empty files or files with vastly different sizes
    if size1 <= 0 or size2 <= 0 or size1 / size2 > 2 or size2 / size1 > 2 then
      return 0
    end

    -- skip large files
    if size1 >= opt.rename.max_size or size2 >= opt.rename.max_size then
      return 0
    end

    -- Safely read files
    local ok1, content1 = pcall(vim.fn.readfile, file1)
    local ok2, content2 = pcall(vim.fn.readfile, file2)
    if not ok1 or not ok2 then
      return 0
    end

    -- count matching lines
    local common_lines = 0
    local total_lines = math.max(#content1, #content2)
    if total_lines == 0 then
      return 0
    end

    --- @type table<string, number>
    local seen = {}

    -- build frequency map of non-empty lines
    for _, line in ipairs(content1) do
      if #line > 0 then
        seen[line] = (seen[line] or 0) + 1
      end
    end

    -- count matching lines
    for _, line in ipairs(content2) do
      if #line > 0 and seen[line] and seen[line] > 0 then
        seen[line] = seen[line] - 1
        common_lines = common_lines + 1
      end
    end

    return common_lines / total_lines
  end

  -- Create a map of all relative paths

  --- @type table<string, {left: string?, right: string?}>
  local all_paths = {}
  --- @type table<string, string>
  local left_only = {}
  --- @type table<string, string>
  local right_only = {}

  -- Helper to process files from a directory
  local function process_files(dir_path, is_left)
    local files = vim.fs.find(function()
      return true
    end, { limit = math.huge, path = dir_path, follow = false })

    for _, full_path in ipairs(files) do
      local rel_path = full_path:sub(#dir_path + 1)
      full_path = vim.fn.resolve(full_path)

      if vim.fn.isdirectory(full_path) == 0 then
        all_paths[rel_path] = all_paths[rel_path] or { left = nil, right = nil }

        if is_left then
          all_paths[rel_path].left = full_path
          if not all_paths[rel_path].right then
            left_only[rel_path] = full_path
          end
        else
          all_paths[rel_path].right = full_path
          if not all_paths[rel_path].left then
            right_only[rel_path] = full_path
          end
        end
      end
    end
  end

  -- Process both directories
  process_files(left_dir, true)
  process_files(right_dir, false)

  --- @type table<string, string>
  local renamed = {}

  -- Detect possible renames
  if opt.rename.detect then
    for left_rel, left_path in pairs(left_only) do
      ---@type {similarity: number, path: string?, rel: string}
      local best_match = { similarity = opt.rename.similarity, path = nil }

      for right_rel, right_path in pairs(right_only) do
        local similarity = calculate_similarity(left_path, right_path)

        if similarity > best_match.similarity then
          best_match = {
            similarity = similarity,
            path = right_path,
            rel = right_rel,
          }
        end
      end

      if best_match.path and best_match.rel then
        renamed[left_rel] = best_match.rel
        all_paths[left_rel].right = best_match.path
        all_paths[best_match.rel] = nil
        left_only[left_rel] = nil
        right_only[best_match.rel] = nil
      end
    end
  end

  --- @type table[]
  local qf_entries = {}

  -- Convert to quickfix entries
  for rel_path, files in pairs(all_paths) do
    local status = 'M' -- Modified (both files exist)
    if not files.left then
      status = 'A' -- Added (only in right)
      files.left = left_dir .. rel_path
    elseif not files.right then
      status = 'D' -- Deleted (only in left)
      files.right = right_dir .. rel_path
    elseif renamed[rel_path] then
      status = 'R' -- Renamed
    end

    table.insert(qf_entries, {
      filename = files.right,
      text = status,
      user_data = {
        diff = true,
        rel = rel_path,
        left = files.left,
        right = files.right,
      },
    })
  end

  return qf_entries
end

--- Diff two directories
--- @param left_dir string
--- @param right_dir string
--- @param opt difftool.opt
local function diff_directories(left_dir, right_dir, opt)
  local qf_entries = nil
  if opt.method == 'diffr' then
    qf_entries = diff_directories_diffr(left_dir, right_dir)
  elseif opt.method == 'builtin' then
    qf_entries = diff_directories_builtin(left_dir, right_dir, opt)
  else
    vim.notify('Unknown diff method: ' .. opt.method, vim.log.levels.ERROR)
    return
  end

  -- Sort entries by filename for consistency
  table.sort(qf_entries, function(a, b)
    return a.user_data.rel < b.user_data.rel
  end)

  vim.fn.setqflist({}, 'r', {
    nr = '$',
    title = 'DiffTool',
    items = qf_entries,
    ---@param info {id: number, start_idx: number, end_idx: number}
    quickfixtextfunc = function(info)
      --- @type table[]
      local items = vim.fn.getqflist({ id = info.id, items = 1 }).items
      local out = {}
      for item = info.start_idx, info.end_idx do
        local entry = items[item]
        table.insert(out, entry.text .. ' ' .. entry.user_data.rel)
      end
      return out
    end,
  })

  setup_layout(true)
  vim.cmd.cfirst()
end

local M = {}

--- @class difftool.opt.rename
--- @inlinedoc
---
--- Whether to detect renames, can be slow on large directories so disable if needed
--- (default: `true`)
--- @field detect boolean
---
--- Minimum similarity for rename detection (0 to 1)
--- (default: `0.5`)
--- @field similarity number
---
--- Maximum file size (in bytes) for rename detection
--- (default: `1024 * 1024`)
--- @field max_size number

--- @class difftool.opt.highlight
--- @inlinedoc
---
--- Highlight group for added files
--- (default: 'DiffAdd')
--- @field A string
---
--- Highlight group for deleted files
--- (default: 'DiffDelete')
--- @field D string
---
--- Highlight group for modified files
--- (default: 'DiffText')
--- @field M string
---
--- Highlight group for renamed files
--- (default: 'DiffChange')
--- @field R string

--- @class difftool.opt
--- @inlinedoc
---
--- Diff method to use, either 'builtin' or 'diffr'
--- (default: 'builtin')
--- @field method string
---
--- Rename detection options (supported only by 'builtin' method)
--- @field rename difftool.opt.rename
---
--- Highlight groups for different diff statuses
--- @field highlight difftool.opt.highlight

--- Diff two files or directories
--- @param left string
--- @param right string
--- @param opt? difftool.opt
function M.diff(left, right, opt)
  if not left or not right then
    vim.notify('Both arguments are required', vim.log.levels.ERROR)
    return
  end

  local config = vim.tbl_deep_extend('force', {}, default_config, opt or {})
  local group = vim.api.nvim_create_augroup('difftool_au', { clear = true })
  local hl_id = vim.api.nvim_create_namespace('difftool_hl')

  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    pattern = 'quickfix',
    callback = function(args)
      vim.api.nvim_buf_clear_namespace(args.buf, hl_id, 0, -1)
      local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)

      -- Map status codes to highlight groups
      for i, line in ipairs(lines) do
        local status = line:match('^(%a) ')

        --- @type string?
        local hl_group = config.highlight[status]

        if hl_group then
          vim.hl.range(args.buf, hl_id, hl_group, { i - 1, 0 }, { i - 1, 1 })
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    pattern = '*',
    callback = function(args)
      --- @type {idx: number, items: table[], size: number}
      local qf_info = vim.fn.getqflist({ idx = 0, items = 1, size = 1 })
      if qf_info.size == 0 then
        return
      end

      local entry = qf_info.items[qf_info.idx]
      if
        not entry
        or not entry.user_data
        or not entry.user_data.diff
        or args.buf ~= entry.bufnr
      then
        return
      end

      vim.schedule(function()
        diff_files(entry.user_data.left, entry.user_data.right, true)
      end)
    end,
  })

  if vim.fn.isdirectory(left) == 1 and vim.fn.isdirectory(right) == 1 then
    diff_directories(left, right, config)
  elseif vim.fn.filereadable(left) == 1 and vim.fn.filereadable(right) == 1 then
    diff_files(left, right)
  else
    vim.notify('Both arguments must be files or directories', vim.log.levels.ERROR)
  end
end

return M

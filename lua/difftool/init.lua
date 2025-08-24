local default_config = {
  method = 'auto',
  rename = {
    detect = false,
    similarity = 0.5,
    chunk_size = 4096,
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

--- Get the path of `path` relative to `base`
--- @param base string
--- @param path string
--- @return string, number
local function relative_path(base, path)
  local rel = vim.fn.fnamemodify(path, ':~:.')
  return rel:gsub('^' .. vim.fn.fnamemodify(base, ':~:.'), '')
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
    local only_dir, only_file = line:match('^Only in ([^:]+): (.+)$')
    local modified_left, modified_right = line:match('^Files (.+) and (.+) differ$')
    if only_dir and only_file then
      local only_path = vim.fs.joinpath(only_dir, only_file)
      --- @type string, string, string
      local status, left, right, rel
      if vim.fs.relpath(left_dir, only_dir) then
        status = 'D'
        rel = vim.fs.joinpath(vim.fs.relpath(left_dir, only_dir), only_file)
        left = only_path
        right = vim.fs.joinpath(right_dir, rel)
      else
        status = 'A'
        rel = vim.fs.joinpath(vim.fs.relpath(right_dir, only_dir), only_file)
        left = vim.fs.joinpath(left_dir, rel)
        right = only_path
      end
      table.insert(qf_entries, {
        filename = right,
        text = status,
        user_data = {
          diff = true,
          rel = rel,
          left = left,
          right = right,
        },
      })
    elseif modified_left and modified_right then
      local rel = vim.fs.relpath(left_dir, modified_left)
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
  -- Helper to read a chunk of a file
  --- @param file string
  --- @param size number
  --- @return string? chunk or nil on error
  local function read_chunk(file, size)
    local fd = io.open(file, 'rb')
    if not fd then
      return nil
    end
    local chunk = fd:read(size)
    fd:close()
    return tostring(chunk)
  end

  --- Helper to calculate file similarity
  --- @param file1 string
  --- @param file2 string
  --- @param chunk_size number
  --- @param chunk_cache table<string, any>
  --- @return number similarity ratio (0 to 1)
  local function calculate_similarity(file1, file2, chunk_size, chunk_cache)
    -- Get or read chunk for file1
    local chunk1 = chunk_cache[file1]
    if not chunk1 then
      chunk1 = read_chunk(file1, chunk_size)
      chunk_cache[file1] = chunk1
    end

    -- Get or read chunk for file2
    local chunk2 = chunk_cache[file2]
    if not chunk2 then
      chunk2 = read_chunk(file2, chunk_size)
      chunk_cache[file2] = chunk2
    end

    if not chunk1 or not chunk2 then
      return 0
    end
    if chunk1 == chunk2 then
      return 1
    end
    local matches = 0
    local len = math.min(#chunk1, #chunk2)
    for i = 1, len do
      if chunk1:sub(i, i) == chunk2:sub(i, i) then
        matches = matches + 1
      end
    end
    return matches / len
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
      local rel_path = vim.fs.relpath(dir_path, full_path)
      if rel_path then
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
  end

  -- Process both directories
  process_files(left_dir, true)
  process_files(right_dir, false)

  --- @type table<string, string>
  local renamed = {}
  --- @type table<string, string>
  local chunk_cache = {}

  -- Detect possible renames
  if opt.rename.detect then
    for left_rel, left_path in pairs(left_only) do
      ---@type {similarity: number, path: string?, rel: string}
      local best_match = { similarity = opt.rename.similarity, path = nil }

      for right_rel, right_path in pairs(right_only) do
        local similarity =
          calculate_similarity(left_path, right_path, opt.rename.chunk_size, chunk_cache)

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
    local status = nil
    if files.left and files.right then
      local similarity = 0
      if opt.rename.detect then
        similarity =
          calculate_similarity(files.left, files.right, opt.rename.chunk_size, chunk_cache)
      else
        similarity = vim.fn.getfsize(files.left) == vim.fn.getfsize(files.right) and 1 or 0
      end
      if similarity < 1 then
        status = renamed[rel_path] and 'R' or 'M'
      end
    elseif files.left then
      status = 'D'
      files.right = right_dir .. rel_path
    elseif files.right then
      status = 'A'
      files.left = left_dir .. rel_path
    end

    if status then
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
  end

  return qf_entries
end

--- Diff two directories
--- @param left_dir string
--- @param right_dir string
--- @param opt difftool.opt
local function diff_directories(left_dir, right_dir, opt)
  local method = opt.method
  if method == 'auto' then
    if not opt.rename.detect and vim.fn.executable('diff') == 1 then
      method = 'diffr'
    else
      method = 'builtin'
    end
  end

  local qf_entries = nil
  if method == 'diffr' then
    qf_entries = diff_directories_diffr(left_dir, right_dir)
  elseif method == 'builtin' then
    qf_entries = diff_directories_builtin(left_dir, right_dir, opt)
  else
    vim.notify('Unknown diff method: ' .. method, vim.log.levels.ERROR)
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
--- Maximum chunk size to read from files for similarity calculation
--- (default: `4096`)
--- @field chunk_size number

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
--- Diff method to use
--- (default: 'auto')
--- @field method 'auto'|'builtin'|'diffr'
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

  left = vim.fs.normalize(left)
  right = vim.fs.normalize(right)

  if vim.fn.isdirectory(left) == 1 and vim.fn.isdirectory(right) == 1 then
    diff_directories(left, right, config)
  elseif vim.fn.filereadable(left) == 1 and vim.fn.filereadable(right) == 1 then
    diff_files(left, right)
  else
    vim.notify('Both arguments must be files or directories', vim.log.levels.ERROR)
  end
end

return M

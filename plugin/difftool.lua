if vim.g.loaded_difftool ~= nil then
  return
end
vim.g.loaded_difftool = true

vim.api.nvim_create_user_command('DiffTool', function(opts)
  if #opts.fargs == 2 then
    require('difftool').open(opts.fargs[1], opts.fargs[2])
  elseif #opts.fargs == 0 then
    require('difftool').close()
  else
    vim.notify('Usage: DiffTool <left> <right>', vim.log.levels.ERROR)
  end
end, { nargs = '*', complete = 'file' })

if vim.g.difftool_replace_diff_mode then
  local function start_diff()
    if not vim.o.diff then
      return
    end
    if vim.fn.argc() == 2 then
      vim.schedule(function()
        vim.api.nvim_cmd({
          cmd = 'DiffTool',
          args = vim.tbl_map(function(arg)
            return arg:gsub('^%w+://', '')
          end, vim.fn.argv()),
        }, {})
      end)
    end
  end

  if vim.v.vim_did_enter > 0 then
    start_diff()
    return
  end
  vim.api.nvim_create_autocmd('VimEnter', {
    callback = start_diff,
  })
end

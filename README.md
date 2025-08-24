# difftool
`DiffTool <left> <right>` command for integration with `git difftool` and `git difftool --dir-diff`.

## Config
```lua
{
    method = 'builtin', -- diff method to use, 'builtin' or 'diffr'
    rename = {
        detect = false, -- whether to detect renames, can be slow on large directories. supported only with builtin method
        similarity = 0.5, -- minimum similarity for rename detection
        max_size = 1024 * 1024, -- maximum file size for rename detection
    },
    highlight = {
        A = 'DiffAdd', -- Added
        D = 'DiffDelete', -- Deleted
        M = 'DiffText', -- Modified
        R = 'DiffChange', -- Renamed
    },
}
```

## Usage
Add this to your `gitconfig`:

```ini
[diff]
    tool = nvim_difftool

[difftool "nvim_difftool"]
    cmd = nvim -c \"DiffTool $LOCAL $REMOTE\"
```

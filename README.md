# difftool
`DiffTool <left> <right>` command for integration with `git difftool` and `git difftool --dir-diff`.

## Config
```lua
{
    method = 'auto', -- diff method to use, 'auto', 'builtin' or 'diffr'
    rename = {
        detect = false, -- whether to detect renames, can be slow on large directories
        similarity = 0.5, -- minimum similarity for rename detection
        chunk_size = 4096, -- maximum chunk size for rename detection
    }
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

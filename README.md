# trash

A PowerShell module to move files to the Windows Recycle Bin, and list, restore, purge or empty its contents.
Works with Windows PowerShell 5.1 and PowerShell 7+ on Windows.

## Install

```powershell
Install-PSResource trash    # or: Install-Module trash
```

## The `trash` command

`trash` takes Unix-style options, similar to `rm` and `gio trash`:

```powershell
trash foo.txt bar\ *.log            # move to Recycle Bin (wildcards supported)
trash -rf build\ missing.txt        # -r/-R/-d are accepted for rm compatibility; -f ignores missing paths
Get-ChildItem *.tmp | trash         # pipeline input
trash --permanent big.iso           # delete directly, bypassing the Recycle Bin

trash -l                            # list Recycle Bin items (--list)
trash -l *.log 'C:\tmp\*'           # filter by Id, name or original path

trash --restore report.docx         # restore to the original location
trash -l *.log | trash --restore

trash --purge 'C:\tmp\*'            # permanently delete matching items (asks first)
trash --purge MWL91K -f             # by Id, without asking

trash -e                            # empty the Recycle Bin (--empty, asks first)
trash -e -f
```

| Option              | Description                                                   |
| ------------------- | ------------------------------------------------------------- |
| `-l`, `--list`      | List Recycle Bin items                                        |
| `--restore`         | Restore items to their original location                      |
| `--purge`           | Permanently delete items from the Recycle Bin                 |
| `-e`, `--empty`     | Empty the Recycle Bin                                         |
| `--permanent`       | Delete directly instead of recycling                          |
| `-f`, `--force`     | Ignore nonexistent paths; do not ask with `--purge`/`--empty` |
| `-n`, `--dry-run`   | Show what would happen (same as `-WhatIf`)                    |
| `-v`, `--verbose`   | Explain what is being done                                    |
| `-h`, `--help`      | Show help                                                     |
| `-r`, `-R`, `-d`    | Accepted for `rm` compatibility, no effect                    |

Short options can be combined (`-rf`), and PowerShell-style spellings such as `-List` or `-WhatIf` also work.
PowerShell consumes a bare `--` and splits unquoted `-name.ext`, so to recycle a file whose name starts with `-`,
write `trash ./-name.ext` or `trash '--' '-name.ext'`.

## Commands

`trash` is a shortcut over these commands, which follow the usual PowerShell conventions
(pipeline input, `-WhatIf`, `-Confirm`):

| Command             | Description                                   |
| ------------------- | --------------------------------------------- |
| `Move-ItemToTrash`  | Move files or directories to the Recycle Bin  |
| `Get-TrashItem`     | List Recycle Bin items                        |
| `Restore-TrashItem` | Restore items to their original location      |
| `Remove-TrashItem`  | Permanently delete items from the Recycle Bin |
| `Clear-Trash`       | Empty the Recycle Bin                         |

```powershell
Get-TrashItem | Where-Object DeletedAt -lt (Get-Date).AddDays(-30) | Remove-TrashItem -Force
```

## Notes

- Files are recycled with `SHFileOperation`. If a file cannot be recycled (too large, network drive, ...),
  Windows asks before deleting it permanently.
- `Get-TrashItem` reads the `$Recycle.Bin\<SID>` folders of the current user on every ready drive.
- Restoring fails if something already exists at the original path.

## License

MIT

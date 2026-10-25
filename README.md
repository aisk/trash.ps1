# trash

A PowerShell module to move files to the Windows Recycle Bin, and list, restore, purge or empty its contents.
Works with Windows PowerShell 5.1 and PowerShell 7+ on Windows.

## Install

```powershell
Install-PSResource trash    # or: Install-Module trash
```

## The `trash` command

```powershell
trash foo.txt bar\ *.log            # move to Recycle Bin (wildcards supported)
Get-ChildItem *.tmp | trash         # pipeline input
trash -Permanent big.iso            # delete directly, bypassing the Recycle Bin

trash -List                         # list Recycle Bin items (alias: -l)
trash -List *.log 'C:\tmp\*'        # filter by Id, name or original path

trash -Restore report.docx          # restore to the original location (alias: -r)
trash -List *.log | trash -Restore

trash -Purge 'C:\tmp\*'             # permanently delete matching items (asks first)
trash -Purge MWL91K -Force          # by Id, without asking

trash -Empty                        # empty the Recycle Bin (alias: -e, asks first)
trash -Empty -Force
```

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

# LiU Backup

A script thrown together to simplify taking a backup of a user's computer before running Erase all contents &
settings or some other major reconfiguration change, while still attempting to maintain a fair level of
user-friendliness in using the tool.

It's a tool to assist with backing up a computer in preparation for reinstallation, transitioning to Jamf Connect, or a
similar major change that **should** be preceded by taking a backup. The tool helps to back up one (or all) users on a
Mac, as well as the `/Library/Application Support` folder, where some software occasionally stores data that may be
desirable to save. The tool is launched by double-clicking on `liu-backup.command`.

> [!IMPORTANT]
> The idea is that this tool can be used as a complement to the user's own backup - not as a replacement.
>
> The purpose is to ensure that, as a technician, you can feel confident that the user's information is properly backed
> up in case the user's own solution proves insufficient. The primary use case for the tool is when a major change to
> the computer needs to be performed, such as reinstallation or any other significant project.
<!-- comment -->
> [!NOTE]
> The tool is not meant to create a full backup of a user's computer, including all installed software, system data and
> the like, but instead selects the locations normally used by a conventional user of macOS, with the addition of the
> Application Support folder sometimes used for licensing and/or important data of certain software. So far, no
> exclusion of cache folders often present here-in, is coded in, and will thus be included.
<!-- comment -->
> [!CAUTION]
> The code hasn't been rigorously tested yet, and might contain bugs and coding errors. Please test thoroughly before
> using in a "live" setting …

## Requirements

- SwiftDialog
- An external media (with enough free space) to run the script off of
- Jamf (optional)

## Description

With its defaults, the script will attempt to create a backup folder at the same path as the backup script is executed
from. The suggestion is therefor to place the script on some external media (i.e. a harddrive or similar device).
The script backups the following paths:

- The selected user's `$HOME` folder (or all users' homes, if selected)
- `/Library/Application Support`
<!-- comment -->
- It also creates a file that lists all non-Apple installed Applications from the `/Applications` folder.

After the backup completes, it asks to either open Self Service to a migration policy in Self Service (in our case for
migrating to Jamf Connect), or to run _Erase All Content and Settings_ (if the hardware is compatible with this feature).

## Process

Here's how the tool works:

1. Initial checks are performed to determine the hardware's properties and capabilities, and also if there is a update
   available for the tool, after which the main window of the tool is displayed.
2. When ready, click "Let's go," and authentication will be requested to perform parts of the process that require
   elevated privileges.
3. To iterate over all files, including those normally protected by macOS privacy settings, the tool requires "Full Disk
   Access." In this step, you are guided to grant the Terminal process extended rights by adding Terminal.app to the
   Full Disk Access section in System Settings.app » Privacy & Security » Full Disk Access.
4. The next step is to choose the source for the backup, i.e., which user (or users) should be backed up.
5. Now, a backup destination is created and assigned, and it is estimated that there is
   enough available space to accommodate the backup.
6. The actual backup is then performed.
7. Final step - here, you are asked if you want to run the assistant for Erase All Contents and Settings, provided that
   the hardware supports it (only hardware with the Apple T2 chip or Apple Silicon-based Macs support this).

Any and all contributions are welcome!

<sub>Ted Jangius, Linköping University</sub>

# Product spec

RAMnotes edits local UTF-8 `.txt` files on Apple Silicon Macs running macOS 27 or later. It has no Dock icon or status item. The direct and App Store builds have the same editing features. See [Build and release](build.md) for update channels.

## Languages

RAMnotes supports English, Spanish, Brazilian Portuguese, German, French, Arabic, Japanese, and Simplified Chinese. Brazilian Portuguese uses the base `pt` locale. The app uses the system or per-app language after relaunch. Missing translations use English. Dates and numbers use the current locale.

The product name, generated filenames, default folder name, and stored keys stay the same in all languages. See [Localization terms](localization-terms.md) for translations.

## Reveal and windows

Manual launch and reopen show the open notes. If none are open, the note list appears. Login launch stays hidden. Closing a note removes it from the open group. Hiding the group preserves its windows and focus order.

Control-Backslash toggles the group. Control-Command-Backslash includes the list and focuses search. Either toggle hides a visible group. By default, a global shortcut or gesture from another active app always reveals its target. Change this behavior in Settings > Windows. Switching apps alone leaves the group as it is.

If a new global shortcut fails to register, the previous shortcut stays active. Menu-bar gestures require precise scrolling and ignore momentum. They work without Accessibility or Input Monitoring permission.

Windows appear on the current Space. RAMnotes restores each frame on a connected display. macOS can require a normal Space when another app uses fullscreen.

## Editing and saving

RAMnotes saves automatically. Only a verified save to the original file clears its edited marker. Blank notes remain until deletion. The editor supports native text Undo, spelling, and Writing Tools.

The editor restores its selection and scroll position when the accepted modification timestamp matches. Any timestamp change can indicate an external edit, even if the text matches. Changes that preserve the timestamp can escape detection.

An external change preserves pending text and waits for composition to finish. The editor then clears Undo and resets to the beginning. Click before typing again. The footer shows the change time until RAMnotes verifies a later local edit. The footer refreshes at midnight, on activation, and when the locale or time zone changes.

Opening a link preserves the selection and Undo history. Recovery text uses note typography and supports a local size override. Repeated accessibility notices preserve focus and announce each change once.

A conflict preserves the file on disk and places local text in a recovery note. Further edits on the same conflicting base can update that recovery note. A missing file stays missing. RAMnotes never selects a replacement folder automatically. If storage is unavailable, the window offers Export. A permission error suspends automatic retries until another edit. If saving and journaling both fail, the editor can hold the only copy. Force quitting can lose that text.

Close, Trash, and folder changes require preservation of pending text. Quit also accepts an exact journaled revision if saving fails. The next launch restores that text. Close Without Saving explicitly discards pending text after confirmation.

## Collection and locations

The collection includes direct text files in the default notes folder and individually registered custom-path notes. The initial folder is `Notes/` in Application Support. Discovery accepts `.txt` in any letter case and skips packages, subfolders, symlinks, and invalid UTF-8. Custom-path notes do not bring sibling files into the collection.

New notes and recovery notes use `rn-word-word-word.txt`. Each word has at most five letters. Words can repeat. Titles use the first nonempty line or, for empty notes, the filename.

Drop files from Finder or choose File > Add Existing Files to register originals in place. RAMnotes rejects folders, symlinks, unsupported encodings, and duplicate file identities. A batch keeps its successful additions.

| Action | Result |
| --- | --- |
| Move To | Moves the original to an unused path. A verified move preserves the note ID and window state. |
| Save a Copy | Verifies a separate file and registers it as a new note. An exact copy of the pending text allows the original window to close. |
| Restore File Access | Requires the original file identity. |
| Locate File | Binds the note to the selected file. A different identity keeps old retained text separate. |
| Remove from List | Forgets an unavailable note and its retained text. The file stays on disk. Save a Copy first to keep unsaved text. |

Removal rechecks a missing original. If the file has returned, the note stays registered.

Changing the default folder offers to move its notes. If you decline, the old notes become custom-path notes. Existing custom-path notes stay in place. When a name already exists, the move adds a numbered suffix starting at ` (2)` and preserves the extension case. Launch, activation, and volume mounts can resume interrupted moves.

## Trash

Moving notes to Trash requires confirmation. Successful moves remove their rows. Failed moves keep their rows and recoverable edits. A batch reports partial success.

If Finder moves a file to Trash, RAMnotes preserves pending text and closes the editor. If RAMnotes cannot preserve the text, the editor stays open. The row stays until Finder restores the file or RAMnotes confirms its disappearance. Use Finder to restore a file. Add it again if RAMnotes removed its row.

## Search and export

Search matches every query word against filenames and text. It ignores case. An empty query lists all notes, most recently edited first by default. Unavailable files can leave results incomplete.

Discovery and opening can request an iCloud download. After eviction, search can reuse cached text if the file identity, size, and modification date still match. Opening the note requests its download again.

Dragging an available row exports the current editor text, including unsaved edits. The drag provides a copy and keeps the original path private. Active composition prevents drag export. A note window can export retained text even when the original is unavailable. Export verifies the destination after writing.

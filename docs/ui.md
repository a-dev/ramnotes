# User interface

## Commands

The Commands button in the note list opens the app menus. Shift-Command-? opens them from an app window.

| Default shortcut | Action |
| --- | --- |
| Command-N | Create a note |
| Command-L | Show the note list |
| Command-F | Find text in the current note |
| Shift-Command-F | Search the collection |
| Command-] or Command-[ | Open the next or previous note |
| Command-Delete | Move the note to Trash |
| Command-=, Command-minus, Command-0 | Increase, decrease, or reset the note font size |
| Command-Comma | Open Settings |
| Escape | Dismiss the current control, then hide the group on the next press |

## Note window

The header contains New Note, Note list, Trash, Background tint, and font size. A blue folder marks a custom-path note. The edited marker indicates unsaved revisions. Tints and font settings stay outside the text file.

Command-click opens a detected link. Open Link and Option-Command-Return also work when the caret is inside a link. A selection can lie inside one link or contain exactly one whole link. A selection that crosses a link boundary partway does not qualify. Composition and Writing Tools disable activation.

After an external change, the footer shows the modification time. VoiceOver reads the full date and time. Click the editor to resume typing. See [Editing and saving](SPEC.md#editing-and-saving) for recovery behavior.

When saving fails, the warning shows the actions available for that note. Export writes the displayed text to a file you choose. Restore File Access requires the original file. Locate File lets you select a new binding. Open Original and Open Recovery navigate between related notes. Close Without Saving asks before it discards the pending text and journal.

Recovery windows show selectable, read-only text with an Export button. Warnings wrap at narrow widths. VoiceOver waits for a pause in typing before announcing a warning.

## Note list

Search and sort controls stay above the rows. Sort by update time, file creation time, or title in either direction. Unknown creation dates sort as oldest. An unsaved edit uses its edit time. Each row shows a preview or search match, location, date, and any tint.

Arrow keys select rows. Command-click toggles a row. Shift-click or Shift-arrow extends a range. Return opens available notes in list order and focuses the last one. Right-click opens actions for that row. Shift-F10 opens actions for the selection.

A row with a file problem shows its warning and an Actions button. Use Open Preserved Text or Save a Copy for retained text. Remove from List applies to the unavailable notes in a selection. A missing default folder directs you to Settings.

The footer shows counts, shortcut status, and results that concern the collection. Individual file problems appear on their rows. Hiding or reopening the list clears temporary action results.

### File panels and Finder

Choose File > Add Existing Files or drop files onto the list. Both actions register the originals. A result sheet lists failures and duplicates. Visible additions become selected. The search query stays in place.

Move To opens a Save panel with the current filename and folder. Choose an unused `.txt` path. Save a Copy opens the new note after verification. Drag a row to Finder to export its current text. See [Collection and locations](SPEC.md#collection-and-locations) for the effect on the original.

## Settings

| Page | Controls |
| --- | --- |
| General | Default notes folder, launch at login, and the Debug language selector. |
| Windows | Keep windows on top, reveal from another active app, global shortcuts, and menu-bar scroll gestures. |
| Appearance | Note typography. The defaults are 18 pt type and 27 pt line height. |
| Shortcuts | In-app command shortcuts. A conflict with another command or global shortcut prevents registration. |
| About | Version and copyright. The direct build also has update controls. |

Quit sits below the sidebar. Tab moves from the selected category to its controls. Changing pages or closing Settings cancels shortcut recording. The horizontal gesture requires the main gesture. Disabling the main gesture preserves the horizontal choice.

## Right-to-left and writing direction

Arabic mirrors window controls, list rows, and directional icons. Paths and filenames keep their character order inside translated sentences. The editor follows the note's writing direction independently of the interface language. Numeric settings accept local digits and ASCII digits.

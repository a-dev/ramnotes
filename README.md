# RAMnotes

Plain-text notes for your Mac.

RAMnotes keeps your notes in small windows on your Mac. Use a note for a quick thought or a checklist beside your work. Press **Control-Backslash** to show or hide your open notes while you work in another app.

Your notes are ordinary `.txt` files. RAMnotes saves your changes automatically, and you can open the files in other text editors.

**[Visit ramnotes.com](https://ramnotes.com/)**

Read [RAM and notes](https://ramnotes.com/articles/ram-and-notes) for the ideas behind the app.

## Your notes beside your work

Open several notes at once. Arrange the windows where you want them. RAMnotes remembers their positions and your place in each note. Hide the windows when you need the space. Use the same shortcut to show them again.

Enable **Always on top** to keep notes visible while you work in other apps. RAMnotes has no Dock icon or menu bar icon.

## Find a note and keep writing

Press **Control-Command-Backslash** to show your open notes and the note list. Use the list to search your notes or create a note.

Use **Command-F** to search within a note. Use **Shift-Command-F** to search your collection. You can change both shortcuts that show or hide your notes in Settings.

## Keep your files where you want them

Use a default notes folder or choose a separate location for any individual note. Use **Move To** to move a note to another folder. To edit an existing text file in place, add it from Finder. Each note can stay in a different folder.

For example, save a note with project instructions in an AI project folder. Add the file to RAMnotes to edit it. Give your AI tools access to the same file as part of the project. RAMnotes saves your changes directly to that file. You do not need to copy the text between RAMnotes and the project.

Editing or moving an added note to the Trash affects the original file.

## Make it comfortable

Choose your font, text size, line spacing, and light or dark appearance. Change your shortcuts in Settings. Choose whether RAMnotes starts when you log in.

## Requirements

RAMnotes runs on **Apple Silicon Macs with macOS 27.0 or later**.

## Install

1. Get the RAMnotes disk image from [ramnotes.com](https://ramnotes.com/).
2. Open the `.dmg` file.
3. Drag **RAMnotes** to **Applications**.
4. Open RAMnotes from **Applications**.

The note list appears when you first open RAMnotes. Choose **New Note** to create a note. Use **Add Existing Files** to add your text files.

Open Settings with the gear button in the note list. Choose your default notes folder there. Enable **Launch at login** if you want RAMnotes to start when you sign in.

## Supported languages

RAMnotes supports these languages:

- English
- Spanish
- Brazilian Portuguese
- German
- French
- Arabic
- Japanese
- Simplified Chinese

RAMnotes uses your Mac's language settings. To choose a different language for RAMnotes, open **System Settings > General > Language & Region > Applications**. Restart RAMnotes after you change the language.

## Current limits

- Notes must be UTF-8 `.txt` files. RAMnotes does not support rich-text formatting or Markdown previews.
- The note list includes files directly in your default folder and files you add individually. It does not scan subfolders.
- RAMnotes has no tags, notebooks, or built-in sync service.
- Changes from another app can go undetected if that app preserves the file's modification timestamp.
- macOS can require a normal desktop Space to show notes over a fullscreen app.
- RAMnotes supports Apple Silicon Macs only. It does not support Intel Macs, iPhone, or iPad.

## Recover unsaved text

If RAMnotes cannot save a note, the note window shows a warning. Use **Export** to save the text to an accessible location. Use **Restore File Access** or **Locate File** when the warning offers those actions.

If another app changes a file while RAMnotes has unsaved edits, RAMnotes preserves those edits in a separate recovery note. Review the original and the recovery note before you delete either file.

## Uninstall

1. Save or export any text that has a save warning.
2. Copy any notes you want to keep to a folder outside RAMnotes' app data.
3. Disable **Launch at login** in RAMnotes Settings if you enabled it.
4. Choose **Quit RAMnotes** in Settings.
5. Move **RAMnotes** from **Applications** to the Trash in Finder.

Moving the app to the Trash leaves its settings and stored data on your Mac. Files you keep in other folders remain in those folders.

The initial default notes folder is inside the app's data container. That container also holds recovery data. Do not delete the container with a cleanup tool unless you first copy the notes and preserve any unsaved text.

## Help and feedback

Visit [ramnotes.com](https://ramnotes.com/) for more about RAMnotes.

To report a problem or suggest an improvement, [open a GitHub issue](https://github.com/a-dev/ramnotes/issues/new). Include your macOS version, RAMnotes version, and the steps that led to the problem. Remove private note text and personal file paths from screenshots and error messages.

## For developers

RAMnotes is open source under the [MIT License](LICENSE).

- [Contribute, build, and test](docs/contribution.md)
- [Documentation index](docs/README.md)
- [Product spec](docs/SPEC.md)
- [Architecture](docs/architecture.md)
- [Build and release](docs/build.md)

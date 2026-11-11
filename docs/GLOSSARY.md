# Glossary

Use these terms consistently in code, UI, and documentation.

| Term | Meaning |
| --- | --- |
| Note | One plain-text `.txt` file. |
| Note window | The window that displays one note. |
| Note list | The window for finding and opening notes. |
| Collection | All tracked notes, including default-folder and custom-path notes. |
| Default notes folder | The folder for new notes. The app lists its direct `.txt` children. |
| Custom-path note | One registered file outside the default folder. The app does not list its siblings. |
| Open note | A note included in group reveal. Hiding preserves this state. Closing clears it. |
| Recovery note | A separate note containing retained text after the original changes or disappears. |
| Journal | A local recovery record containing unsaved text in `Recovery/`. |
| Collection token | A guard valid for the current collection. A default-folder change preserves it. |
| Location revision | A per-note counter that advances after a move or relink. |
| Edit revision | A per-editor counter that advances with each edit. |
| File revision | A fingerprint and modification time for comparison with the editor's base. |
| Retained edit | Unsaved text preserved in the editor or a recovery journal when saving cannot safely complete. |
| Retained edit summary | `RetainedEditSummary`: the application view of a retained edit (identity, original location, text, revision, date, reason). Recovery presentation uses it instead of the journal record. |
| Note list item | A `NoteListItem` holds the verified snapshot, searchable text, update time, and file availability for one row. |
| Collection read snapshot | `CollectionReadSnapshot`: note facts, retained edits, and recovery results from one store read. The coordinator adopts it as one unit. |
| Window state | Frame, open state, tint, font size, and position of one note window, stored by NoteID in `collection-metadata.json`. It never decides whether a note exists. |
| Recovery promotion | A recorded operation that creates a recovery note and prevents duplicate creation after restart. |
| Relink | Explicitly bind a tracked note to a verified file. Matching text alone does not establish identity. |
| Location operation | A move or rename with persisted stages for reconciling filesystem and catalog changes. |

Use note for the file and note window for its window.
Do not call the collection a folder or a recovery note a backup.
Text undo changes editor or search text. Finder owns restoration of trashed files.

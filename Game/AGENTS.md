# Project Instructions — LÖVE 2D Game

## Running & testing the game

LÖVE ships two executables at `C:/Program Files/LOVE/`:

| Binary | Use case |
|---|---|
| `lovec.exe` | **Console build** — prints Lua errors to stdout/stderr. Use this to *check for errors*. |
| `love.exe` | **GUI build** — no console; errors show only as a popup. Use this to *run normally*. |

### Mandatory workflow when changing any `.lua` file

1. **Always run the console build first to detect errors:**
   ```
   "C:/Program Files/LOVE/lovec.exe" .
   ```
   - A syntax/runtime error prints as plain text (e.g. `Error: main.lua:11: unexpected symbol near '/'`) with a Lua stack traceback.
   - Use `timeout 8` so it doesn't hang on the frame loop, e.g.:
     ```
     timeout 8 "C:/Program Files/LOVE/lovec.exe" .
     ```
   - Exit code `124` means the game loaded and ran until the timeout (good — no startup error), not a crash.

2. **Only if `lovec.exe` reports no errors, run the game normally:**
   ```
   "C:/Program Files/LOVE/love.exe" .
   ```

## Error handling

- **Whenever you edit any `.lua` file, run `lovec.exe` first** (console build) to check for errors.
- **If there is an error, fix it and report it clearly** — do not silently ignore it and do not proceed with the original user request until the game loads without error. Always surface the exact error text to the user.
- A non-zero exit code other than `124` (or any error printed to stderr) means a real problem that must be fixed and reported before continuing.

## Other notes

- Entry point is `main.lua`; run `love .` / `lovec .` from the project root.

# Velocitty 1.3.0-hotfix2

Platform fixes for Windows and macOS on top of 1.3.0.

## Windows

- IME input (Chinese, Japanese, Korean) works: the message loop no longer skips the input-method windows, and the candidate window follows the cursor.
- CJK text renders: fonts stored in TrueType collections (`.ttc`, e.g. Microsoft YaHei, MS Gothic, SimSun) now load, localized family names are accepted, and Malgun Gothic is a fallback for Hangul.
- Ctrl+Backspace no longer also deletes the next character.
- Alt+letter no longer beeps; Alt+F4 and Alt+Space work.
- Dragging a selection outside the window no longer leaves it stuck.
- Precision touchpads scroll smoothly instead of a full step per tiny movement.
- Lower typing latency (1 ms timer resolution) and only changed rows are redrawn.

## macOS

- Text no longer fades while typing or when TUIs switch screens (Core Animation cross-fade disabled).
- Holding a key repeats instead of opening the accent popup.
- IME composition: Return and Backspace go to the input method while composing, and the candidate window follows the cursor.
- Colors are tagged sRGB, so themes look right on Display P3 screens.
- Output wakes the event loop immediately and frames follow the display refresh rate.

## Configuration

- Config and font errors are shown inside the window when there is no console, with the line and column of TOML errors.
- Default font size is 12 pt on Windows and macOS.
- `~/.config/velocitty/config.toml` (`%USERPROFILE%\.config\velocitty\config.toml` on Windows) is read when the platform config file does not exist.

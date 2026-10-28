# Third-party notices

Yaya's Calendar is MIT-licensed (see `LICENSE`). It adapts code from the project below. Each adapted
file says so in its header.

## Codenotch

- Source: Codenotch, https://github.com/vinzdg/codenotch (MIT License, Copyright (c) 2026 Vinz).
  Portions of the adapted files are © the author of Yaya's Calendar, under the same MIT License.
- Used in:
  - `Sources/Auth/TokenVault.swift`: non-interactive Keychain access, adapted from
    `Sources/Providers/KeychainPrompt.swift` and `Sources/Providers/KeychainItem.swift`.
  - `Sources/App/MainWindowController.swift`: switching the agent to `.regular` activation while its
    window is open and back to `.accessory` when it closes, after
    `Sources/Settings/SettingsWindowController.swift`.

```
MIT License

Copyright (c) 2026 Vinz

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Portions © the author

Everything else is © the author under the MIT License in `LICENSE`, including code the author first
wrote for other projects and reuses here:

- `Sources/Shared/Local.swift`: the `@Local` property wrapper, from Dailies (same author, MIT).
- `Sources/Store/AppDatabase.swift`: the SQLite plumbing (WAL, forward-only `user_version` migrations, one
  connection), adapted from Deck's store (same author, MIT).
- `Sources/Sync/WakeTriggers.swift`: syncing on wake, unlock, session return and network return, adapted
  from the author's own earlier code.
- `Sources/UI/MadeByFooter.swift`: the "Made by" footer.

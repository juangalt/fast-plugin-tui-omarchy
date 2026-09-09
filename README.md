# Plugin TUI for Omarchy

A terminal UI for the [Omarchy plugin marketplace](https://plugins.omarchy.org),
in the same style as Omarchy's *Install → AUR* picker: fuzzy search, a details
pane, and one keypress to install.

- **Search** by name, id, author or tag
- **Filter** by category (Widgets, Productivity, System, Hardware, …), installed-only, verified-only
- **Sort** by GitHub stars, hearts, views, copies, recently added, recently updated, or name
- **Install / enable / disable / update / remove** plugins through the regular `omarchy plugin` commands
- One 7 MB download, cached for 6 hours — no per-repository requests

It is a single bash script on top of `fzf`, `jq`, `curl` and `gum`, all of which
ship with Omarchy.

## Install

```bash
omarchy plugin add https://github.com/felipegalleguillos/omarchy-plugin-tui.git --enable
```

Enabling the plugin adds a **Plugin TUI** entry to the app launcher
(`SUPER + SPACE`). You can also run it directly:

```bash
~/.config/omarchy/plugins/felipe.plugin-tui/bin/omarchy-plugin-tui
```

### Omarchy menu entry (optional)

To get an *Install → Plugins* row next to *AUR* and *Package*, add this to
`~/.config/omarchy/extensions/omarchy-menu.jsonc` (the menu hot-reloads):

```jsonc
"install.plugins": {"icon":"󰐱","label":"Plugins","action":"xdg-terminal-exec --app-id=org.omarchy.terminal ~/.config/omarchy/plugins/felipe.plugin-tui/bin/omarchy-plugin-tui"},
```

## Keys

Navigation and filters live on `alt`, actions on `ctrl` (plus `enter`).

| Key | Action |
|-----|--------|
| type | fuzzy search over name, id, author and tags |
| `tab` | multi-select |
| `home` / `end` | jump to the top / bottom of the list |
| `alt-s` / `alt-S` | cycle sort (stars → hearts → views → copies → added → updated → name) / pick sort from a list |
| `alt-c` / `alt-C` | cycle category / pick category from a list |
| `alt-i` | toggle installed-only |
| `alt-v` | toggle verified-only |
| `alt-p` | toggle the details pane; `alt-j`/`alt-k`/`alt-d`/`alt-u` scroll it |
| `alt-o` | open the plugin's repository in the browser |
| `alt-h` or `?` | help popup (`esc` closes it) |
| `enter` | install selected plugin(s) — runs `omarchy plugin add <repo> --enable` |
| `ctrl-t` | enable / disable an installed plugin |
| `ctrl-x` | remove an installed plugin |
| `ctrl-o` | update an installed plugin |
| `ctrl-r` | re-download catalog and stats |
| `esc` or `ctrl-q` | quit (`ctrl-c` and `ctrl-g` are ignored; `ctrl-d` just deletes a character) |

When you change the sort, category or a filter, the corresponding value in the
header lights up for about a second so the change is easy to spot.

In the list, `●` marks an enabled plugin and `○` one that is installed but disabled.

Install, remove and update go through the official `omarchy plugin` commands
with their normal confirmations (the untrusted-code warning, the bar-section
picker for bar widgets, the update diff). Set `OMARCHY_PLUGIN_TUI_YES=1` or pass
`--yes` to skip them when batch-installing.

## Data

| Source | What | Cache |
|--------|------|-------|
| `https://plugins.omarchy.org/catalog.json` | names, categories, tags, stars, verification, install command | 6 h |
| `https://api.omarchyplugins.com/v1/stats` | hearts, views, copies | 15 min |

Cache lives in `~/.cache/omarchy-plugin-tui/`. If a download fails the last
cached copy is used and the header says so. Installed state comes from
`omarchy plugin list --json` on every reload.

## Options

```
omarchy-plugin-tui [--refresh] [--yes] [--dry-run]
```

`--dry-run` (or `OMARCHY_PLUGIN_TUI_DRY_RUN=1`) prints the `omarchy plugin`
commands instead of running them. `OMARCHY_PLUGIN_TUI_CATALOG_URL` and
`OMARCHY_PLUGIN_TUI_STATS_URL` point the downloads somewhere else (any URL curl
understands, including `file://`) — used by the tests.

## Development

```bash
git clone https://github.com/felipegalleguillos/omarchy-plugin-tui.git
ln -s "$PWD/omarchy-plugin-tui" ~/.config/omarchy/plugins/felipe.plugin-tui
omarchy-shell shell rescanPlugins
omarchy plugin enable felipe.plugin-tui
```

Headless checks: `bin/omarchy-plugin-tui __rows | head`,
`bin/omarchy-plugin-tui __preview b.okomart`, and
`omarchy-plugin-validate .` (run it on the real directory, not the symlink).

## Limitations

- Built-in `omarchy.*` plugins appear in the catalog but can only be enabled or disabled, not installed or removed.
- Preview images are not shown (no image support in the terminal path).
- Plugin directories whose path contains `@PLUGIN_DIR@` are not supported by the launcher template.

## License

MIT

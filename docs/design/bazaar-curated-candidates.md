# Bazaar curated candidates (from Bluefin)

<!-- bluefin-curated-sha: 725dbf68ccff8ae2ad74300430f984ee9ea8206c -->

Candidate Flatpaks for krytis's Bazaar "Curated" page
([#245](https://github.com/starlit-os/krytis/issues/245)), mirrored from Bluefin's
list. Nothing on this page is shipped yet. It's the pool that #245's own `curated.yaml`
gets picked from.

- **Source:** `system_files/bluefin/etc/bazaar/curated.yaml` in
  [`projectbluefin/common`](https://github.com/projectbluefin/common/blob/main/system_files/bluefin/etc/bazaar/curated.yaml).
  It isn't in dakota, and it isn't in the legacy `ublue-os/bluefin` repo.
- **Snapshot:** common @ `725dbf68` (2026-09-29): 127 apps in 10 sections, listed below in
  Bluefin's section order. The HTML comment above records that SHA.
  `mise run bazaar-recommends-diff` diffs against it.
- **Refreshing:** use the `bluefin-bazaar-recommends` skill
  (`.claude/skills/bluefin-bazaar-recommends/`). Don't edit the list or the marker by hand.
- **Summaries** come from each app's AppStream `<summary>`, read from its Flathub
  packaging repo or its upstream source repo. Entries marked † were written by hand,
  either because no metainfo could be fetched (flathub.org is unreachable from the
  cloud-agent sandbox) or because the lookup found a vendored dependency's metainfo.
  Check a † entry on its Flathub page before quoting it anywhere user-facing.

## Things to settle before picking

These notes come from comparing Bluefin's setup with krytis's. They aren't in the list itself.

- **Bluefin recommends apps that its own hooks then redirect.** The Desktop Development
  entries VS Code, VSCodium, Zed and the JetBrains IDEs are intercepted at install time
  by `etc/bazaar/bazaar.yaml` + `hooks.py`, which steer the user to a Homebrew/`ujust`
  install. krytis has no Homebrew and no hooks, so copying those rows as they are
  would install the sandboxed Flatpak. That is exactly the experience Bluefin is
  warning people away from.
- **krytis already ships some of these natively.** Zed (`elements/desktop/zed.bst`)
  duplicates `dev.zed.Zed`. Equibop (`elements/desktop/equibop.bst`) covers the same
  need as `com.discordapp.Discord`. The #245 wiring plan blocklists both IDs, so they
  can't go on krytis's page (see *Contract with the wiring* below). Zen (`elements/desktop/zen-browser.bst`) sits
  beside the Browsers row. And Bluefin's `app.drey.Warp` is a file-transfer app,
  **not** the Warp terminal in `elements/desktop/warp.bst`.
- **GNOME Shell-only apps don't fit.** Anything that assumes a GNOME session
  (`org.gnome.Mahjongg` is fine; a shell-extension manager wouldn't be) needs a check
  under niri.
- **Proprietary and paid apps are out.** They're struck from the list and recorded
  under *Decided*.
- **Blocklist interplay:** Bluefin's `blocklist.yaml` hides `com.visualstudio.code-oss`,
  editors like Neovim/Vim/Emacs/Helix/micro, Ptyxis, fwupd and Bazaar itself. Any krytis
  blocklist is a separate decision from the curated list.

## Contract with the wiring

The #245 wiring work
([comment](https://github.com/starlit-os/krytis/issues/245#issuecomment-5887731857))
ships krytis's own `curated.yaml` as a skeleton: the rows, banners and section titles.
The curation work owns only the ID list inside each `appids.list`. Every list change
has to satisfy five rules:

1. Every ID resolves: `flatpak remote-info flathub <id>` succeeds. A delisted or renamed
   ID fails silently.
2. No ID is also in krytis's `blocklist.yaml`, because the blocklist wins. It blocks
   Flatpaks krytis already ships natively: `dev.zed.Zed`, `com.discordapp.Discord`,
   `org.vim.Vim` and `org.freedesktop.fwupd`. The last two were agreed in
   [this reply](https://github.com/starlit-os/krytis/issues/245#issuecomment-5888011213).
3. The modern schema only.
4. No `image:` under `banner:` unless branding art lands in the same change.
5. Changing a list touches no other file. If it has to, raise that on #245.

## Currently preinstalled by krytis

These are listed so they can be weighed against the curated page: keep one
preinstalled, or move it to a recommendation. None of them is in Bluefin's curated list
above.

krytis preinstalls Flatpaks through two paths, and they don't install the same set:

| Path | File | What gets it |
|---|---|---|
| Image first boot | `files/flatpak-preinstall/flatpak-preinstall.sh` | Every krytis system, including one reached by `bootc switch`. It installs **only Bazaar**. |
| Live ISO | `live/src/flatpaks`, baked into the squashfs by `live/src/install-flatpaks.sh` | The live session, and installs made from the ISO. The file header says the installer copies them to the target offline (`flatpak_var_path` in `live/src/configure-live-krytis.sh`). |

So a system installed from the ISO has all 12 entries (Bazaar included), while a system that reached krytis by
`bootc switch` has only Bazaar. `live/src/flatpaks` came over with the dakota-iso fork's
Bluefin list. Nothing in `files/` or `elements/`
depends on any entry in it: no MIME default or config references them.
The "no native …" notes below come from the image's `.desktop` inventory:
`grep -E '^/\./usr/share/applications/.*\.desktop' files/fakecap-manifest.tsv`.

| App | Summary | Path | Notes | Links |
|---|---|---|---|---|
| **Bazaar** | Flatpak app store † | image + ISO | The store itself, so it can't be a recommendation. Bluefin's blocklist hides it for that reason. | [Flathub](https://flathub.org/apps/io.github.kolunmi.Bazaar) · `io.github.kolunmi.Bazaar` |
| **adw-gtk3** / **adw-gtk3-dark** | The libadwaita theme ported to GTK 3 | ISO | Runtime extensions, not apps, so they don't fit a curated app row. They theme Flatpak GTK 3 apps; the host copy is `elements/desktop/adw-gtk3.bst`. | [Flathub](https://flathub.org/apps/org.gtk.Gtk3theme.adw-gtk3) · `org.gtk.Gtk3theme.adw-gtk3`, `org.gtk.Gtk3theme.adw-gtk3-dark` |
| **Papers** | Document (PDF) viewer † | ISO | The image has no native PDF viewer, though Zen's built-in viewer can open PDFs. | [Flathub](https://flathub.org/apps/org.gnome.Papers) · `org.gnome.Papers` |
| **Loupe** (Image Viewer) | View images † | ISO | The image has no native image viewer. | [Flathub](https://flathub.org/apps/org.gnome.Loupe) · `org.gnome.Loupe` |
| **Showtime** (Video Player) | Watch videos † | ISO | The image has no native video player. | [Flathub](https://flathub.org/apps/org.gnome.Showtime) · `org.gnome.Showtime` |
| **Sushi** (NautilusPreviewer) | Quick file previews in Nautilus (space bar) † | ISO | Add-on for Nautilus, which krytis ships natively (`gnome-build-meta.bst:core/nautilus.bst`). | [Flathub](https://flathub.org/apps/org.gnome.NautilusPreviewer) · `org.gnome.NautilusPreviewer` |
| **Fonts** | View and install fonts † | ISO | | [Flathub](https://flathub.org/apps/org.gnome.font-viewer) · `org.gnome.font-viewer` |
| **Logs** | View the systemd journal † | ISO | | [Flathub](https://flathub.org/apps/org.gnome.Logs) · `org.gnome.Logs` |
| **Firmware** | Install firmware on devices (fwupd front-end) † | ISO | | [Flathub](https://flathub.org/apps/org.gnome.Firmware) · `org.gnome.Firmware` |
| **Mission Center** | Monitor system resource usage | ISO | | [Flathub](https://flathub.org/apps/io.missioncenter.MissionCenter) · `io.missioncenter.MissionCenter` |
| **Flatseal** | Manage Flatpak permissions | ISO | | [Flathub](https://flathub.org/apps/com.github.tchx84.Flatseal) · `com.github.tchx84.Flatseal` |

### Decided

These were preinstalled on the ISO and have been removed from `live/src/flatpaks`:

| App | Decision | Links |
|---|---|---|
| **Ignition** | Dropped. It manages GNOME-style autostart entries, not niri's `spawn-at-startup`. | [Flathub](https://flathub.org/apps/io.github.flattool.Ignition) · `io.github.flattool.Ignition` |
| **Smile** | Dropped. | [Flathub](https://flathub.org/apps/it.mijorus.smile) · `it.mijorus.smile` |
| **Pinta** | Moves to the curated page: "Bluefin Recommends" or a category, not decided yet. It's a krytis addition, since Bluefin doesn't curate it. | [Flathub](https://flathub.org/apps/com.github.PintaProject.Pinta) · `com.github.PintaProject.Pinta` |

Bluefin candidates rejected for krytis's curated page. These rows stay in *The list* so
it keeps mirroring Bluefin, struck through so a refresh doesn't propose them again:

| App | Decision | Links |
|---|---|---|
| **Damask** | Dropped. | [Flathub](https://flathub.org/apps/app.drey.Damask) · `app.drey.Damask` |
| **Android Studio** | Proprietary: `LicenseRef-proprietary` in its AppStream metadata. | [Flathub](https://flathub.org/apps/com.google.AndroidStudio) · `com.google.AndroidStudio` |
| **CLion** | Proprietary: `LicenseRef-proprietary` in its AppStream metadata. | [Flathub](https://flathub.org/apps/com.jetbrains.CLion) · `com.jetbrains.CLion` |
| **Discord** | Proprietary: `LicenseRef-proprietary` in its AppStream metadata. | [Flathub](https://flathub.org/apps/com.discordapp.Discord) · `com.discordapp.Discord` |
| **Ecosia Browser** | Proprietary: a closed vendor binary from Ecosia's CDN with no source repo. Its declared license couldn't be read from the sandbox. | [Flathub](https://flathub.org/apps/org.ecosia.Browser) · `org.ecosia.Browser` |
| **Google Chrome** | Proprietary: `LicenseRef-proprietary` in its AppStream metadata. | [Flathub](https://flathub.org/apps/com.google.Chrome) · `com.google.Chrome` |
| **Microsoft Edge** | Proprietary: `LicenseRef-proprietary` in its AppStream metadata. | [Flathub](https://flathub.org/apps/com.microsoft.Edge) · `com.microsoft.Edge` |
| **Mozilla VPN** | Paid: MPL-2.0, but it needs a Mozilla VPN subscription. | [Flathub](https://flathub.org/apps/org.mozilla.vpn) · `org.mozilla.vpn` |
| **Obsidian** | Proprietary: `LicenseRef-proprietary` in its AppStream metadata. | [Flathub](https://flathub.org/apps/md.obsidian.Obsidian) · `md.obsidian.Obsidian` |
| **Opera** | Proprietary: `LicenseRef-proprietary` in its AppStream metadata. | [Flathub](https://flathub.org/apps/com.opera.Opera) · `com.opera.Opera` |
| **Plex** | Proprietary: `LicenseRef-proprietary` in its AppStream metadata. | [Flathub](https://flathub.org/apps/tv.plex.PlexDesktop) · `tv.plex.PlexDesktop` |
| **Plexamp** | Proprietary: `LicenseRef-proprietary` in its AppStream metadata. | [Flathub](https://flathub.org/apps/com.plexamp.Plexamp) · `com.plexamp.Plexamp` |
| **Postman** | Proprietary: `LicenseRef-proprietary` in its AppStream metadata. | [Flathub](https://flathub.org/apps/com.getpostman.Postman) · `com.getpostman.Postman` |
| **PyCharm Professional** | Proprietary: `LicenseRef-proprietary` in its AppStream metadata. | [Flathub](https://flathub.org/apps/com.jetbrains.PyCharm-Professional) · `com.jetbrains.PyCharm-Professional` |
| **Slack** | Proprietary: `LicenseRef-proprietary` in its AppStream metadata. | [Flathub](https://flathub.org/apps/com.slack.Slack) · `com.slack.Slack` |
| **Spotify** | Proprietary: `LicenseRef-proprietary` in its AppStream metadata. | [Flathub](https://flathub.org/apps/com.spotify.Client) · `com.spotify.Client` |
| **Steam** | Proprietary: `LicenseRef-proprietary` in its AppStream metadata. | [Flathub](https://flathub.org/apps/com.valvesoftware.Steam) · `com.valvesoftware.Steam` |
| **Steam Link** | Proprietary: `LicenseRef-proprietary` in its AppStream metadata. | [Flathub](https://flathub.org/apps/com.valvesoftware.SteamLink) · `com.valvesoftware.SteamLink` |
| **Visual Studio Code** | Proprietary: `LicenseRef-proprietary` in its AppStream metadata. | [Flathub](https://flathub.org/apps/com.visualstudio.code) · `com.visualstudio.code` |
| **Vivaldi** | Proprietary: `LicenseRef-proprietary` in its AppStream metadata. | [Flathub](https://flathub.org/apps/com.vivaldi.Vivaldi) · `com.vivaldi.Vivaldi` |

Policy: **no proprietary or paid apps** on krytis's curated page. A refresh drops
any new Bluefin pick that fails that rule the same way (see the skill).

Removing an app from `live/src/flatpaks` only affects new ISO builds and the installs
made from them. Systems already installed keep their copy in `/var/lib/flatpak`.

## The list

### Bluefin Recommends (14)

| App | Summary | Links |
|---|---|---|
| ~~**Damask**~~ | ~~Automatically set wallpapers from online sources †~~ **Dropped**, see *Decided* | [Flathub](https://flathub.org/apps/app.drey.Damask) · `app.drey.Damask` |
| **Sitra** | Get fonts from online sources | [Flathub](https://flathub.org/apps/io.github.sitraorg.sitra) · `io.github.sitraorg.sitra` |
| **Speed of Sound** | Voice typing for the Linux desktop | [Flathub](https://flathub.org/apps/io.speedofsound.SpeedOfSound) · `io.speedofsound.SpeedOfSound` |
| **Fotema** | Photo gallery † | [Flathub](https://flathub.org/apps/app.fotema.Fotema) · `app.fotema.Fotema` |
| **Video Trimmer** | Trim videos quickly, losslessly † | [Flathub](https://flathub.org/apps/org.gnome.gitlab.YaLTeR.VideoTrimmer) · `org.gnome.gitlab.YaLTeR.VideoTrimmer` |
| **Whisp** | Minimalist note taking widget | [Flathub](https://flathub.org/apps/io.github.tanaybhomia.Whisp) · `io.github.tanaybhomia.Whisp` |
| **Test Center** | Install and manage experimental app/system builds from a merge request, branch or bundle † | [Flathub](https://flathub.org/apps/cx.modal.TestCenter) · `cx.modal.TestCenter` |
| **Eloquent** | Your proofreading assistant | [Flathub](https://flathub.org/apps/re.sonny.Eloquent) · `re.sonny.Eloquent` |
| **Railway** | Travel with all your train information † | [Flathub](https://flathub.org/apps/de.schmidhuberj.DieBahn) · `de.schmidhuberj.DieBahn` |
| **Pulp** | Skim excessive RSS/Atom feeds † | [Flathub](https://flathub.org/apps/org.gnome.gitlab.cheywood.Pulp) · `org.gnome.gitlab.cheywood.Pulp` |
| **Spedread** | GTK speed reading software: Read like a speedrunner! | [Flathub](https://flathub.org/apps/com.github.Darazaki.Spedread) · `com.github.Darazaki.Spedread` |
| **IceBox** | PDF Maker | [Flathub](https://flathub.org/apps/io.github.pleromix.IceBox) · `io.github.pleromix.IceBox` |
| **File Shredder** | Securely delete files † | [Flathub](https://flathub.org/apps/com.github.ADBeveridge.Raider) · `com.github.ADBeveridge.Raider` |
| **Kasasa** | Snip and pin useful information | [Flathub](https://flathub.org/apps/io.github.kelvinnovais.Kasasa) · `io.github.kelvinnovais.Kasasa` |

### Browsers (7)

| App | Summary | Links |
|---|---|---|
| **Firefox** | Web browser † | [Flathub](https://flathub.org/apps/org.mozilla.firefox) · `org.mozilla.firefox` |
| **Brave** | Chromium-based browser with built-in ad blocking | [Flathub](https://flathub.org/apps/com.brave.Browser) · `com.brave.Browser` |
| ~~**Google Chrome**~~ | ~~The browser built to be yours~~ **Dropped**, see *Decided* | [Flathub](https://flathub.org/apps/com.google.Chrome) · `com.google.Chrome` |
| ~~**Microsoft Edge**~~ | ~~Chromium-based web browser~~ **Dropped**, see *Decided* | [Flathub](https://flathub.org/apps/com.microsoft.Edge) · `com.microsoft.Edge` |
| ~~**Opera**~~ | ~~Your personal browser~~ **Dropped**, see *Decided* | [Flathub](https://flathub.org/apps/com.opera.Opera) · `com.opera.Opera` |
| ~~**Vivaldi**~~ | ~~Feature-packed web browser~~ **Dropped**, see *Decided* | [Flathub](https://flathub.org/apps/com.vivaldi.Vivaldi) · `com.vivaldi.Vivaldi` |
| ~~**Ecosia Browser**~~ | ~~Chromium-based browser from the tree-planting search engine †~~ **Dropped**, see *Decided* | [Flathub](https://flathub.org/apps/org.ecosia.Browser) · `org.ecosia.Browser` |

### Media (12)

| App | Summary | Links |
|---|---|---|
| ~~**Spotify**~~ | ~~Online music streaming service~~ **Dropped**, see *Decided* | [Flathub](https://flathub.org/apps/com.spotify.Client) · `com.spotify.Client` |
| **YTMDesktop** | Free cross platform Desktop Player for YouTube Music | [Flathub](https://flathub.org/apps/app.ytmdesktop.ytmdesktop) · `app.ytmdesktop.ytmdesktop` |
| **Shortwave** | Listen to internet radio † | [Flathub](https://flathub.org/apps/de.haeckerfelix.Shortwave) · `de.haeckerfelix.Shortwave` |
| **Amberol** | Plays music, and nothing else † | [Flathub](https://flathub.org/apps/io.bassi.Amberol) · `io.bassi.Amberol` |
| **VLC** | Media player † | [Flathub](https://flathub.org/apps/org.videolan.VLC) · `org.videolan.VLC` |
| **Easy Effects** | Audio effects for PipeWire applications † | [Flathub](https://flathub.org/apps/com.github.wwmm.easyeffects) · `com.github.wwmm.easyeffects` |
| **JamesDSP** | Open-source audio effect processor for Pipewire | [Flathub](https://flathub.org/apps/me.timschneeberger.jdsp4linux) · `me.timschneeberger.jdsp4linux` |
| **Jellyfin Desktop** | Jellyfin desktop client | [Flathub](https://flathub.org/apps/org.jellyfin.JellyfinDesktop) · `org.jellyfin.JellyfinDesktop` |
| ~~**Plex**~~ | ~~Plex client for desktop computers~~ **Dropped**, see *Decided* | [Flathub](https://flathub.org/apps/tv.plex.PlexDesktop) · `tv.plex.PlexDesktop` |
| ~~**Plexamp**~~ | ~~Beautiful music player for Plex~~ **Dropped**, see *Decided* | [Flathub](https://flathub.org/apps/com.plexamp.Plexamp) · `com.plexamp.Plexamp` |
| **Blanket** | Listen to ambient sounds † | [Flathub](https://flathub.org/apps/com.rafaelmardojai.Blanket) · `com.rafaelmardojai.Blanket` |
| **Parabolic** | Download web video and audio | [Flathub](https://flathub.org/apps/org.nickvision.tubeconverter) · `org.nickvision.tubeconverter` |

### Office & Productivity (14)

| App | Summary | Links |
|---|---|---|
| **Collabora Office** | LibreOffice-based office suite † | [Flathub](https://flathub.org/apps/com.collaboraoffice.Office) · `com.collaboraoffice.Office` |
| **ONLYOFFICE Desktop Editors** | Office productivity suite | [Flathub](https://flathub.org/apps/org.onlyoffice.desktopeditors) · `org.onlyoffice.desktopeditors` |
| ~~**Slack**~~ | ~~Business communication~~ **Dropped**, see *Decided* | [Flathub](https://flathub.org/apps/com.slack.Slack) · `com.slack.Slack` |
| **Blender** | 3D modelling, animation and rendering suite † | [Flathub](https://flathub.org/apps/org.blender.Blender) · `org.blender.Blender` |
| **Exhibit** | 3D model viewer (F3D-based) † | [Flathub](https://flathub.org/apps/io.github.nokse22.Exhibit) · `io.github.nokse22.Exhibit` |
| **GIMP** | Raster image editor † | [Flathub](https://flathub.org/apps/org.gimp.GIMP) · `org.gimp.GIMP` |
| **Inkscape** | Vector graphics editor † | [Flathub](https://flathub.org/apps/org.inkscape.Inkscape) · `org.inkscape.Inkscape` |
| **Krita** | Digital painting † | [Flathub](https://flathub.org/apps/org.kde.krita) · `org.kde.krita` |
| **Upscaler** | Upscale and enhance images † | [Flathub](https://flathub.org/apps/io.gitlab.theevilskeleton.Upscaler) · `io.gitlab.theevilskeleton.Upscaler` |
| **Audacity** | Audacity is the world's most popular audio editing and recording app | [Flathub](https://flathub.org/apps/org.audacityteam.Audacity) · `org.audacityteam.Audacity` |
| **Ardour** | Digital audio workstation † | [Flathub](https://flathub.org/apps/org.ardour.Ardour) · `org.ardour.Ardour` |
| **Planify** | Task manager with Todoist / Nextcloud sync † | [Flathub](https://flathub.org/apps/io.github.alainm23.planify) · `io.github.alainm23.planify` |
| ~~**Obsidian**~~ | ~~Markdown-based knowledge base~~ **Dropped**, see *Decided* | [Flathub](https://flathub.org/apps/md.obsidian.Obsidian) · `md.obsidian.Obsidian` |
| **Logseq** | Connect your notes and knowledge | [Flathub](https://flathub.org/apps/com.logseq.Logseq) · `com.logseq.Logseq` |

### Games (15)

| App | Summary | Links |
|---|---|---|
| ~~**Steam**~~ | ~~Launcher for the Steam software distribution service~~ **Dropped**, see *Decided* | [Flathub](https://flathub.org/apps/com.valvesoftware.Steam) · `com.valvesoftware.Steam` |
| **Heroic** | Play Epic, GOG and Amazon Games | [Flathub](https://flathub.org/apps/com.heroicgameslauncher.hgl) · `com.heroicgameslauncher.hgl` |
| ~~**Discord**~~ | ~~Talk, play, hang out~~ **Dropped**, see *Decided* | [Flathub](https://flathub.org/apps/com.discordapp.Discord) · `com.discordapp.Discord` |
| **Lutris** | Video game preservation platform | [Flathub](https://flathub.org/apps/net.lutris.Lutris) · `net.lutris.Lutris` |
| **ProtonPlus** | Manage Proton, Wine, DXVK, and VKD3D tools for Linux game launchers | [Flathub](https://flathub.org/apps/com.vysp3r.ProtonPlus) · `com.vysp3r.ProtonPlus` |
| **GPU Screen Recorder** | Low-overhead hardware-encoded screen recorder / replay buffer † | [Flathub](https://flathub.org/apps/com.dec05eba.gpu_screen_recorder) · `com.dec05eba.gpu_screen_recorder` |
| **Protontricks** | Apps and fixes for Proton games | [Flathub](https://flathub.org/apps/com.github.Matoking.protontricks) · `com.github.Matoking.protontricks` |
| **OBS Studio** | Live stream and record videos | [Flathub](https://flathub.org/apps/com.obsproject.Studio) · `com.obsproject.Studio` |
| **Boatswain** | Control Elgato Stream Deck devices † | [Flathub](https://flathub.org/apps/com.feaneron.Boatswain) · `com.feaneron.Boatswain` |
| ~~**Steam Link**~~ | ~~Stream games from another computer with Steam~~ **Dropped**, see *Decided* | [Flathub](https://flathub.org/apps/com.valvesoftware.SteamLink) · `com.valvesoftware.SteamLink` |
| **Mahjongg** | Match tiles and clear the board † | [Flathub](https://flathub.org/apps/org.gnome.Mahjongg) · `org.gnome.Mahjongg` |
| **SDL Sopwith** | Classic side-scrolling biplane shoot-'em-up † | [Flathub](https://flathub.org/apps/io.github.fragglet.sdl_sopwith) · `io.github.fragglet.sdl_sopwith` |
| **Sudoku** | Solve puzzles in style | [Flathub](https://flathub.org/apps/io.github.sepehr_rs.Sudoku) · `io.github.sepehr_rs.Sudoku` |
| **Battle for Wesnoth** | Turn-based fantasy strategy game † | [Flathub](https://flathub.org/apps/org.wesnoth.Wesnoth) · `org.wesnoth.Wesnoth` |
| **Threadbare** | Endless Access game about learning to make games † | [Flathub](https://flathub.org/apps/org.endlessaccess.threadbare) · `org.endlessaccess.threadbare` |

### Utilities (19)

| App | Summary | Links |
|---|---|---|
| **Warp** | Fast and secure file transfer (magic-wormhole) † | [Flathub](https://flathub.org/apps/app.drey.Warp) · `app.drey.Warp` |
| **LocalSend** | Share files to nearby devices | [Flathub](https://flathub.org/apps/org.localsend.localsend_app) · `org.localsend.localsend_app` |
| **SyncThingy** | SyncThingy = Syncthing + simple tray indicator | [Flathub](https://flathub.org/apps/com.github.zocker_160.SyncThingy) · `com.github.zocker_160.SyncThingy` |
| **Apostrophe** | Markdown editor † | [Flathub](https://flathub.org/apps/org.gnome.gitlab.somas.Apostrophe) · `org.gnome.gitlab.somas.Apostrophe` |
| **Save Desktop** | Save your desktop configuration | [Flathub](https://flathub.org/apps/io.github.vikdevelop.SaveDesktop) · `io.github.vikdevelop.SaveDesktop` |
| **Pika Backup** | Borg-based backups † | [Flathub](https://flathub.org/apps/org.gnome.World.PikaBackup) · `org.gnome.World.PikaBackup` |
| **Ente Auth** | Open-source, cross-platform 2FA authenticator † | [Flathub](https://flathub.org/apps/io.ente.auth) · `io.ente.auth` |
| **Clapgrep** | Search through all your files, including PDFs and office documents † | [Flathub](https://flathub.org/apps/de.leopoldluley.Clapgrep) · `de.leopoldluley.Clapgrep` |
| **Fedora Media Writer** | Create a Fedora live USB drive | [Flathub](https://flathub.org/apps/org.fedoraproject.MediaWriter) · `org.fedoraproject.MediaWriter` |
| **Raspberry Pi Imager** | Raspberry Pi Imaging utility | [Flathub](https://flathub.org/apps/org.raspberrypi.rpi-imager) · `org.raspberrypi.rpi-imager` |
| **Cameractrls** | Camera controls for Linux | [Flathub](https://flathub.org/apps/hu.irl.cameractrls) · `hu.irl.cameractrls` |
| **Decoder** | Scan and generate QR codes † | [Flathub](https://flathub.org/apps/com.belmoussaoui.Decoder) · `com.belmoussaoui.Decoder` |
| **Constrict** | Compress videos to a target file size † | [Flathub](https://flathub.org/apps/io.github.wartybix.Constrict) · `io.github.wartybix.Constrict` |
| **Switcheroo** | Convert and manipulate images † | [Flathub](https://flathub.org/apps/io.gitlab.adhami3310.Converter) · `io.gitlab.adhami3310.Converter` |
| **Pigment** | Get color palettes from images | [Flathub](https://flathub.org/apps/com.jeffser.Pigment) · `com.jeffser.Pigment` |
| **Eyedropper** | Pick and format colours † | [Flathub](https://flathub.org/apps/com.github.finefindus.eyedropper) · `com.github.finefindus.eyedropper` |
| **SysD Manager** | A user-friendly application to manage systemd's units | [Flathub](https://flathub.org/apps/io.github.plrigaux.sysd-manager) · `io.github.plrigaux.sysd-manager` |
| ~~**Mozilla VPN**~~ | ~~A fast, secure and easy to use VPN. Built by the makers of Firefox~~ **Dropped**, see *Decided* | [Flathub](https://flathub.org/apps/org.mozilla.vpn) · `org.mozilla.vpn` |
| **RClone Manager** | Browse and sync cloud storage | [Flathub](https://flathub.org/apps/io.github.zarestia_dev.rclone-manager) · `io.github.zarestia_dev.rclone-manager` |

### Sustainability & Education (12)

| App | Summary | Links |
|---|---|---|
| **Endless Key** | Offline library of educational content for learners † | [Flathub](https://flathub.org/apps/org.endlessos.Key) · `org.endlessos.Key` |
| **Memorize** | Study flashcards | [Flathub](https://flathub.org/apps/io.github.david_swift.Flashcards) · `io.github.david_swift.Flashcards` |
| **Keypunch** | Practise your typing skills † | [Flathub](https://flathub.org/apps/no.bragefuglseth.Keypunch) · `no.bragefuglseth.Keypunch` |
| **Tux Paint** | Drawing program for children † | [Flathub](https://flathub.org/apps/org.tuxpaint.Tuxpaint) · `org.tuxpaint.Tuxpaint` |
| **Memorado** | Memorise with spaced-repetition flashcards † | [Flathub](https://flathub.org/apps/im.bernard.Memorado) · `im.bernard.Memorado` |
| **Egghead** | Learn while having fun | [Flathub](https://flathub.org/apps/io.github.josephmawa.Egghead) · `io.github.josephmawa.Egghead` |
| **Nucleus** | Explore the periodic table † | [Flathub](https://flathub.org/apps/page.codeberg.lo_vely.Nucleus) · `page.codeberg.lo_vely.Nucleus` |
| **TurboWarp** | Make games, animations, and stories | [Flathub](https://flathub.org/apps/org.turbowarp.TurboWarp) · `org.turbowarp.TurboWarp` |
| **RISC-V Adventure** | A quest through the layers of computer architecture (simulated RISC-V processor) † | [Flathub](https://flathub.org/apps/io.github.GGalya1.RiscvAdventure) · `io.github.GGalya1.RiscvAdventure` |
| **Museum of All Things** | Explore an infinite 3D museum | [Flathub](https://flathub.org/apps/as.may.moat) · `as.may.moat` |
| **Multiplication Puzzle** | Practise times tables with a puzzle game † | [Flathub](https://flathub.org/apps/app.drey.MultiplicationPuzzle) · `app.drey.MultiplicationPuzzle` |
| **Spelling Bee** | Learn new English words | [Flathub](https://flathub.org/apps/io.github.josephmawa.SpellingBee) · `io.github.josephmawa.SpellingBee` |

### AI and Machine Learning (4)

| App | Summary | Links |
|---|---|---|
| **Alpaca** | Chat with AI models | [Flathub](https://flathub.org/apps/com.jeffser.Alpaca) · `com.jeffser.Alpaca` |
| **Newelle** | AI chatbot | [Flathub](https://flathub.org/apps/io.github.qwersyk.Newelle) · `io.github.qwersyk.Newelle` |
| **Jan** | Private offline AI assistant | [Flathub](https://flathub.org/apps/ai.jan.Jan) · `ai.jan.Jan` |
| **Whis** | Turn speech into text | [Flathub](https://flathub.org/apps/ink.whis.Whis) · `ink.whis.Whis` |

### Desktop Development (17)

| App | Summary | Links |
|---|---|---|
| **Gitte** | Git GUI client † | [Flathub](https://flathub.org/apps/de.wwwtech.gitte) · `de.wwwtech.gitte` |
| **Zed** | High-performance code editor | [Flathub](https://flathub.org/apps/dev.zed.Zed) · `dev.zed.Zed` |
| ~~**Visual Studio Code**~~ | ~~Code editing. Redefined~~ **Dropped**, see *Decided* | [Flathub](https://flathub.org/apps/com.visualstudio.code) · `com.visualstudio.code` |
| **VSCodium** | Telemetry-less code editing | [Flathub](https://flathub.org/apps/com.vscodium.codium) · `com.vscodium.codium` |
| **IntelliJ IDEA** | Java and Kotlin IDE | [Flathub](https://flathub.org/apps/com.jetbrains.IntelliJ-IDEA-Community) · `com.jetbrains.IntelliJ-IDEA-Community` |
| ~~**PyCharm Professional**~~ | ~~Python IDE (proprietary, paid)~~ **Dropped**, see *Decided* | [Flathub](https://flathub.org/apps/com.jetbrains.PyCharm-Professional) · `com.jetbrains.PyCharm-Professional` |
| ~~**CLion**~~ | ~~A cross-platform IDE for C and C++~~ **Dropped**, see *Decided* | [Flathub](https://flathub.org/apps/com.jetbrains.CLion) · `com.jetbrains.CLion` |
| ~~**Android Studio**~~ | ~~IDE for Android app development~~ **Dropped**, see *Decided* | [Flathub](https://flathub.org/apps/com.google.AndroidStudio) · `com.google.AndroidStudio` |
| **Builder** | IDE for GNOME / Flatpak development † | [Flathub](https://flathub.org/apps/org.gnome.Builder) · `org.gnome.Builder` |
| **Arduino IDE v2** | Open-source electronics prototyping platform | [Flathub](https://flathub.org/apps/cc.arduino.IDE2) · `cc.arduino.IDE2` |
| **Brief** | Browse command-line cheatsheets | [Flathub](https://flathub.org/apps/io.github.shonebinu.Brief) · `io.github.shonebinu.Brief` |
| **Icon Library** | Find the right icon to use † | [Flathub](https://flathub.org/apps/org.gnome.design.IconLibrary) · `org.gnome.design.IconLibrary` |
| **Embellish** | Install nerd fonts | [Flathub](https://flathub.org/apps/io.github.getnf.embellish) · `io.github.getnf.embellish` |
| **Collision** | Check hashes for your files † | [Flathub](https://flathub.org/apps/dev.geopjr.Collision) · `dev.geopjr.Collision` |
| **Elastic** | Design spring animations † | [Flathub](https://flathub.org/apps/app.drey.Elastic) · `app.drey.Elastic` |
| **ASCII Draw** | Sketch diagrams in ASCII † | [Flathub](https://flathub.org/apps/io.github.nokse22.asciidraw) · `io.github.nokse22.asciidraw` |
| **Concessio** | Understand file permissions | [Flathub](https://flathub.org/apps/io.github.ronniedroid.concessio) · `io.github.ronniedroid.concessio` |

### Cloud Native Development (13)

| App | Summary | Links |
|---|---|---|
| **Podman Desktop** | Manage Podman and other container engines from one UI † | [Flathub](https://flathub.org/apps/io.podman_desktop.PodmanDesktop) · `io.podman_desktop.PodmanDesktop` |
| **Headlamp** | Kubernetes UI † | [Flathub](https://flathub.org/apps/io.kinvolk.Headlamp) · `io.kinvolk.Headlamp` |
| **Freelens** | Free IDE for Kubernetes | [Flathub](https://flathub.org/apps/app.freelens.Freelens) · `app.freelens.Freelens` |
| ~~**Postman**~~ | ~~Platform for building and using APIs~~ **Dropped**, see *Decided* | [Flathub](https://flathub.org/apps/com.getpostman.Postman) · `com.getpostman.Postman` |
| **DBeaver Community** | Free Universal Database Tool | [Flathub](https://flathub.org/apps/io.dbeaver.DBeaverCommunity) · `io.dbeaver.DBeaverCommunity` |
| **Codd** | Lightweight PostgreSQL client | [Flathub](https://flathub.org/apps/io.github.anil_e.Codd) · `io.github.anil_e.Codd` |
| **Dev Toolbox** | Dev tools at your fingertips | [Flathub](https://flathub.org/apps/me.iepure.devtoolbox) · `me.iepure.devtoolbox` |
| **Forge Sparks** | Git forge (GitHub/Gitea/Forgejo) notifications † | [Flathub](https://flathub.org/apps/com.mardojai.ForgeSparks) · `com.mardojai.ForgeSparks` |
| **SSH Pilot** | Manage your servers with ease | [Flathub](https://flathub.org/apps/io.github.mfat.sshpilot) · `io.github.mfat.sshpilot` |
| **RustConn** | Manage SSH, RDP, and VNC connections | [Flathub](https://flathub.org/apps/io.github.totoshko88.RustConn) · `io.github.totoshko88.RustConn` |
| **Carabiner** | Create and manage network tunnels | [Flathub](https://flathub.org/apps/io.github.sugarycandybar.Carabiner) · `io.github.sugarycandybar.Carabiner` |
| **Digger** | Modern, advanced DNS lookup tool | [Flathub](https://flathub.org/apps/io.github.tobagin.digger) · `io.github.tobagin.digger` |
| **Echo** | Ping websites | [Flathub](https://flathub.org/apps/io.github.lo2dev.Echo) · `io.github.lo2dev.Echo` |

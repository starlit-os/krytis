kind: manual

variables:
  strip-binaries: ""

# fdsdk 26.08's ncurses added a `ghostty` entry to its own terminfo database,
# so /usr/share/terminfo/g/ghostty is now installed by two elements and
# oci/krytis/runtime.bst fails to stage with `[overlaps]: Non-whitelisted
# overlaps detected` (project.conf makes overlaps fatal). ghostty's copy wins:
# it is compiled from the terminfo source shipped with this exact ghostty
# release, whereas ncurses carries a snapshot of the upstream terminfo
# database that lags whatever the terminal actually implements.
#
# Only this one path collides. ghostty also installs
# /usr/share/terminfo/x/xterm-ghostty, which ncurses does not ship —
# verified with `bst artifact list-contents` on both artifacts, so the
# whitelist is one entry rather than a glob over the terminfo tree.
public:
  bst:
    overlap-whitelist:
    - /usr/share/terminfo/g/ghostty

build-depends:
  - desktop/zig.bst
  - freedesktop-sdk.bst:components/tar.bst
  - freedesktop-sdk.bst:components/gzip.bst
  # grep + sed: the zon hash rewrite in stage 2. The sandbox has neither by default.
  - freedesktop-sdk.bst:components/grep.bst
  - freedesktop-sdk.bst:components/sed.bst
  - freedesktop-sdk.bst:components/gettext.bst
  - freedesktop-sdk.bst:components/pkg-config.bst

depends:
  - gnome-build-meta.bst:sdk/gtk.bst
  - gnome-build-meta.bst:sdk/libadwaita.bst
  - desktop/gtk4-layer-shell.bst
  - freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

sources:
  # Ghostty source tarball
  - kind: tar
    url: ghostty_releases:1.4.0/ghostty-1.4.0.tar.gz
    ref: cb188ac6c3a8278d5fd7bfef15d8c017104c87f638b5560eb38024a71ae0f005

  # Zig package dependencies — generated, do not hand-edit.
  # Regenerate with the element's `-update` mise task.
  - kind: remote
    url: ghostty_deps:libxev-819ffa180ca20e31c7eded74e2e1aceb1eab557f.tar.gz
    ref: 42993af02089811fc26ea90deabbe8a60fb469059dd5947f1debf57c560c3f36
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:vaxis-6fd944a27fb3d6f596e981076381a3131f2448b4.tar.gz
    ref: 39d50c983da3dc952c9449c5ef7aadd49142758376ab09149d6212a49c37e16a
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:z2d-40af3e84a4e15a9f31d126b3f281f23ce6a3dae5.tar.gz
    ref: fdaca4e2789bb8b781eef2cc76eab5ef3490d8cceec699e40d1cc96b53ad3f74
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:zig_objc-3352c12a868f8787ab71bf2ca6eab9fcfb635c52.tar.gz
    ref: 5a27d67c016031c51b260744909cceedad9f307d2f93569cb1c81ac91b45f178
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:zig_js-3c23860e47fdcdc5af805efb7fd0bdac5fd3e9bc.tar.gz
    ref: a2ff488a244301f4e59469a5232aad6869b01acc50f7d7ed2647c029a57d4b3b
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:uucode-ea62149739404a73c202b48a33bf6dd2af4bd9b0.tar.gz
    ref: f37c4071a217853450d084cb9c12b6d4b68f887eb9cb42fe77a84f86056eacbf
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:zig_wayland-27dda01712ddf3cb46ebd93380d88b01a7c828f8.tar.gz
    ref: c7d268d7c0dcecfeb209d0ccf2b04364d1541722c5e53e4c5bbd3eaa481847a4
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:zf-87153bb86b75d21fbac897b738f316d449f5d0c9.tar.gz
    ref: 56174bcd35fbeab7fd5501bdfa7175fd0474c88d733a6455050977075b8da50a
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:gobject-2026-10-02-38-1.tar.zst
    ref: 400fa7fd7bb7d29ec5348e14c70785a23f96926546afc6f02f7086c66b362ba4
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:wayland-9cb3d7aa9dc995ffafdbdef7ab86a949d0fb0e7d.tar.gz
    ref: ea4191d68e437677e51f3aacde27829810144e931d397a327dc6035e2c39c50d
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:N-V-__8AAFdWDwA0ktbNUi9pFBHCRN4weXIgIfCrVjfGxqgA.tar.gz
    ref: dd2df14ab5f41038257aaedcc4b5fb9ac0ee018f3f0f94af9097028e60d33223
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:plasma_wayland_protocols-12207e0851c12acdeee0991e893e0132fc87bb763969a585dc16ecca33e88334c566.tar.gz
    ref: 5c58ba214acd8e6bca3426dc08b022c46a8dd997b29a1b3e28badf71c20df441
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:JetBrainsMono-2.304.tar.gz
    ref: c57a691e8b82ad098b5963f3959032e4038f391087af7715885ba59046105cc4
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:NerdFontsSymbolsOnly-3.4.0.tar.gz
    ref: 1164d1b956d4bde248d7b2f0998c43cc94f5202431a1564a793895b1e73b0d04
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:ghostty-themes-release-20261019-151001-86a776d.tgz
    ref: ab2513e316372c45c9f86e3e511aebdbfa6c39fa03c210096b19152fe288505b
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:breakpad-b99f444ba5f6b98cac261cbb391d8766b34a5918.tar.gz
    ref: 6cca98943d1a990766cef61077c09aff5938063fe17a1efe1228e5412b6d6ad9
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:DearBindings_v0.17_ImGui_v1.92.5-docking.tar.gz
    ref: 8bfec500e00926f679853ee23d67cc392d3c3181733ca4704738651d3f70baa3
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:N-V-__8AAEbOfQBnvcFcCX2W5z7tDaN8vaNZGamEQtNOe0UI.tar.gz
    ref: c816c20e8c75f3e15ae867350e79925502d1a6a85938bb1a73b8927e5f31f9cb
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:N-V-__8AAOgqbADacob-q2_DMQlmgaG4xKHRuW-6PJ4oJzMZ.tar.xz
    ref: 4f7b554a38cdf78c033f666c8871f3749e14a094f65a07f630c91ed0b43d35e3
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:freetype-1220b81f6ecfb3fd222f76cf9106fecfa6554ab07ec7fdc4124b9bb063ae2adf969d.tar.gz
    ref: 427201f5d5151670d05c1f5b45bef5dda1f2e7dd971ef54f0feaaa7ffd2ab90c
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:glslang-12201278a1a05c0ce0b6eb6026c65cd3e9247aa041b1c260324bf29cee559dd23ba1.tar.gz
    ref: 14a2edbb509cb3e51a9a53e3f5e435dbf5971604b4b833e63e6076e8c0a997b5
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:gtk4-layer-shell-1.1.0.tar.gz
    ref: 98284281260a5eef5b4f63a55f16c4bf6a788a1020a6db037ecb0f71fa336988
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:wayland-protocols-258d8f88f2c8c25a830c6316f87d23ce1a0f12d9.tar.gz
    ref: 5cedcadde81b75e60f23e5e83b5dd2b8eb4efb9f8f79bd7a347d148aeb0530f8
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:harfbuzz-11.0.0.tar.xz
    ref: f16351bafe214725fe2c1d5b59f0d93e49905a4b247899fb90d70cff953a2b9b
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:highway-66486a10623fa0d72fe91260f96c892e41aceb06.tar.gz
    ref: 87d4f8893ef4e08f224973608ffebf94268a81380ba79c12e8841968c80aa212
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:gettext-0.24.tar.gz
    ref: c918503d593d70daf4844d175a13d816afacb667c06fba1ec9dcd5002c1518b7
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:libpng-1220aa013f0c83da3fb64ea6d327f9173fa008d10e28bc9349eac3463457723b1c66.tar.gz
    ref: fecc95b46cf05e8e3fc8a414750e0ba5aad00d89e9fdf175e94ff041caf1a03a
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:libxml2-2.11.5.tar.gz
    ref: 6c28059e2e3eeb42b5b4b16489e3916a6346c1095a74fee3bc65cdc5d89a6215
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:oniguruma-1220c15e72eadd0d9085a8af134904d9a0f5dfcbed5f606ad60edc60ebeccd9706bb.tar.gz
    ref: 001aa1202e78448f4c0bf1a48c76e556876b36f16d92ce3207eccfd61d99f2a0
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:sentry-1220446be831adcca918167647c06c7b825849fa3fba5f22da394667974537a9c77e.tar.gz
    ref: 2ac6497cc8d61a8d31093e47addb8c9b2c45b16b0705bb334a835b6423c318df
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:spirv_cross-1220fb3b5586e8be67bc3feb34cbe749cf42a60d628d2953632c2f8141302748c8da.tar.gz
    ref: b52b6fcfc45e7fa69b1f06a1362c155473444e2cc09995556b156c53ba6657e3
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:translate_c-02ff0c523fb92a38939b04d0145c4a9602a74d56.tar.gz
    ref: e344433bcce14759529e58ea600e67d7c39846b1775b122f88db7cb4dad58591
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:wuffs-7411f488fe2e2c205c3d3b3d28638b7356522930.tar.gz
    ref: 17877d346f7988651d6c62e45b2e3b05c86809a6442c5e34612374b2a9719a1c
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:pixels-12207ff340169c7d40c570b4b6a97db614fe47e0d83b5801a932dcd44917424c8806.tar.gz
    ref: 55e83b16d091082502bf149bf457f31f42092c5982650e3ffbae7b48871bf11a
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:zlib-1220fed0c74e1019b3ee29edae2051788b080cd96e90d56836eea857b0b966742efb.tar.gz
    ref: 17e88863f3600672ab49182f217281b6fc4d3c762bde361935e436a95214d05c
    directory: zig-deps

  - kind: remote
    url: github_files:ThomasDickey/esctest2/archive/2798f12149a19c3295e9b4853ab2da4b2eff1b2b.tar.gz
    ref: 04b01a8343045a6801ea9a2a849b339e1b41179197102363a43fab13b25a2e1e
    directory: zig-deps

  - kind: remote
    url: github_files:sergot/zigimg/archive/c701c9f99779d7ddf594dcc6da8f858fd277d61f.tar.gz
    ref: c716c6f262e03291b3801bfd399aec70f3c65069d4ca462ba7362273f88fea66
    directory: zig-deps-git

  - kind: remote
    url: github_files:jacobsandlund/uucode/archive/ea62149739404a73c202b48a33bf6dd2af4bd9b0.tar.gz
    ref: f37c4071a217853450d084cb9c12b6d4b68f887eb9cb42fe77a84f86056eacbf
    directory: zig-deps-git

  - kind: remote
    url: github_files:hendriknielaender/zBench/archive/f12a2262bcd9d300207890555c577da5e29de453.tar.gz
    ref: 8a6038e43c947b35ed10561712d563b8f12bb55762dd3bc41922c1589d4bff98
    directory: zig-deps

  - kind: remote
    url: github_files:rockorager/libvaxis/archive/6fd944a27fb3d6f596e981076381a3131f2448b4.tar.gz
    ref: 39d50c983da3dc952c9449c5ef7aadd49142758376ab09149d6212a49c37e16a
    directory: zig-deps-git

  - kind: remote
    url: codeberg_files:ziglang/arocc/archive/d0c8c4d9c55daa7ef6e40cf0f630a5b5e900989b.tar.gz
    ref: 42f5ac4d1fb7c55ad4073dc462b02d485ace4da6d7fc29b35acfa99e28f2cb7d
    directory: zig-deps-git

  - kind: remote
    url: github_files:kristoff-it/zine/archive/acf07577b158475c7d54f3461c3348b8a0a6a6d3.tar.gz
    ref: 0fb4b3c9078a777233e7a69b7e692562612d0eea726fe9eb415be4733c41eab4
    directory: zig-deps-git

  - kind: remote
    url: github_files:zigtools/lsp-kit/archive/ec325a3c33d1da7708cf513355208f74d9560580.tar.gz
    ref: 4d3ac8f16a6a6f15a487f8086a4a684b4b85941d658ec496460103a0ca974244
    directory: zig-deps-git

  - kind: remote
    url: github_files:kristoff-it/scripty/archive/4b815a13e2456e5552c7ce43759f69e40ffdc702.tar.gz
    ref: e2a280629f0daab81d93986f5b841b56f1d311769197983737797abf9bcb7a04
    directory: zig-deps-git

  - kind: remote
    url: github_files:kristoff-it/tracy/archive/67d2d89e351048c76fc6d161e0ac09d8a831dc60.tar.gz
    ref: a54d405e7ffadcc5f2e441b361226666e61df1acf3ac18045f2771df0cf26b3f
    directory: zig-deps-git

  - kind: remote
    url: github_files:kristoff-it/mime/archive/a2ed0cba3b1463217168034ffed8c1604e72598d.tar.gz
    ref: fba12453efe9e788644cc3e6fe5c04be25ef4d4f21c4f82e995b9640b71bb383
    directory: zig-deps-git

  - kind: remote
    url: github_files:allyourcodebase/wuffs/archive/6fd35cb51e90c4f69c64f3a2c28eb8aa36dc9c8b.tar.gz
    ref: 33ce38e46298e2a0f06a4782e87da0c6429771a851647d97227935e0653594df
    directory: zig-deps-git

  - kind: remote
    url: hexops_files:hexops/xcode-frameworks/archive/8a1cfb373587ea4c9bb1468b7c986462d8d4e10e.tar.gz
    ref: 4111e053c455a694fb3c42a74cd12c1c18f1808c3e2cdc4be7e08e85451a27e5
    directory: zig-deps-git

  - kind: remote
    url: github_files:kristoff-it/superhtml/archive/32cff9e05c65904d557db94118b81e5b0d407208.tar.gz
    ref: e6ee5b4e4dc0f2b34d723d3efdf728d7f38f1b8503375e5e70836cea08f3a967
    directory: zig-deps-git

  - kind: remote
    url: github_files:rockorager/zeit/archive/fdaad9c5884f41a3640c768f4f9fc116e763c321.tar.gz
    ref: 5fa9c91f6061d4a3631c4caa393b1b60dfd8071c390407880955ba1565445f06
    directory: zig-deps-git

  - kind: remote
    url: github_files:neurocyte/flow-syntax/archive/12a8e42b8b9b71166090c773f0fd9a7bddebab58.tar.gz
    ref: 918007fd4ecf447260ddb424c90fe13fb044317ac723a2b143c36be1649a7ca2
    directory: zig-deps-git

  - kind: remote
    url: github_files:kristoff-it/ziggy/archive/0fdd57cbb052e7aa5930b3ed960ea3450f9dc2b0.tar.gz
    ref: b2d2de9d1b826493561145142ea9338fb3a1b2c80639d28365832991082360e3
    directory: zig-deps-git

  - kind: remote
    url: github_files:kristoff-it/supermd/archive/93b67c047438e534997c764708019ce54d7f0d82.tar.gz
    ref: d487a86fc7c22f4adac1783178b8dfc7d5fbb6d0132014e62447530ef44429c2
    directory: zig-deps-git

  - kind: remote
    url: codeberg_files:ziglang/translate-c/archive/7a1a9fdc4ab00835748a6657ecbb835e3d5d45f7.tar.gz
    ref: 78e6203bcb15abbc98f9563834764669dd586b215f5f282b9862009dccd61d4f
    directory: zig-deps-git

  - kind: remote
    url: github_files:google/wuffs-mirror-release-c/archive/90e4d81a6a8b7b601e8e568da32a105d7f7705e5.tar.gz
    ref: ddbebc8fb7405e7a9177efdfbdf0df18ad02b607311d9e604959c7c0f6236af4
    directory: zig-deps

  - kind: remote
    url: github_files:ziglibs/known-folders/archive/175f5596b3d2ee3c658282bb07885580895a0e73.tar.gz
    ref: e8cbc5bd80098895cd23c92cc1b8b2c1c549b74bfebb247ff2f8bdf3c2396c4d
    directory: zig-deps-git

  - kind: remote
    url: github_files:neurocyte/tree-sitter/releases/download/master-70dbb6fa9d998bcf599c3aaeecac7479e9ee3f0c/source.tar.gz
    ref: d743120a53fdfeba5c2cf6c57474007b06161fe480e84cce6d32e1cddb515ef5
    directory: zig-deps

  - kind: remote
    url: github_files:neurocyte/cbor/archive/66c28df31b8e4448dac7edf063417f2234d6f3c9.tar.gz
    ref: 7789c1d0667ad6e628417f135d60fe8d495902ddbb9e15bccf5c4974a47c6397
    directory: zig-deps-git

  - kind: remote
    url: github_files:kristoff-it/cmark-gfm/archive/cd0aba87cc89f0c8aa9393e59505db271ea30239.tar.gz
    ref: ba6059c5f070e06f23391d0bd23276510603b5d5b575cb8070b4a0924e9a91ae
    directory: zig-deps-git

  - kind: remote
    url: codeberg_files:ziglang/translate-c/archive/42f630117deffd5318b4a6ceffbd366dd0af8cee.tar.gz
    ref: 4fa6d8926f4bc7104f2326d432e599dfd082c95a95d3ad1a882dcde360837e38
    directory: zig-deps-git

  - kind: remote
    url: github_files:Vexu/arocc/archive/5f5a050569a95ecc40a426f0c3666ae7ef987ede.tar.gz
    ref: e20b49a13049e8ef5aa1d798a70d8fc02b691fe44c7c78928aae3d363a1deb7e
    directory: zig-deps-git

  - kind: remote
    url: github_files:ziglibs/known-folders/archive/bafef170a73c064dc706fcfbdc2e406a35681a9c.tar.gz
    ref: 49646c665c936b6c63bfc3b8dd970a165d59f380a1c2f4d0552963c942df9ccf
    directory: zig-deps-git

  - kind: remote
    url: github_files:zigtools/lsp-kit/archive/c46ac866dda11ab58e4ba71ed0d8ba21f43e81db.tar.gz
    ref: e9ddd03a2cc9eed59e6115de8a5e2d044b2b8e58196fb681e33c8c90ed338a0c
    directory: zig-deps-git

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v33.0.2/wasmtime-v33.0.2-aarch64-android-c-api.tar.xz
    ref: b00f098e61aebd88b747a028807ee3e469f50545336ead87bacf8672e790c67f
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v33.0.2/wasmtime-v33.0.2-aarch64-linux-c-api.tar.xz
    ref: 5ff5061f8267a81866737dcbf01af06d18b56b688009f8b6e190c005f2518c11
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v33.0.2/wasmtime-v33.0.2-aarch64-macos-c-api.tar.xz
    ref: 5c2d4292d0cdb76720d65703843d45380f3c1ccb45a9275bf05c74d969601f90
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v33.0.2/wasmtime-v33.0.2-aarch64-musl-c-api.tar.xz
    ref: 8c6a82c837c5ca1357c630aa23591d92752183360aaaed77121f51969e45b0f2
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v33.0.2/wasmtime-v33.0.2-aarch64-windows-c-api.zip
    ref: 643569a1788a302fb7f8af8fbd80bd9f3d495ab0a0ceecbddaf79fbec632dead
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v33.0.2/wasmtime-v33.0.2-armv7-linux-c-api.tar.xz
    ref: 2add0bd91e89d136e1531a0555658484326d42ad09383170403aa8e389d8b322
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v33.0.2/wasmtime-v33.0.2-i686-linux-c-api.tar.xz
    ref: 704aa4bde8405676c07fd14415008aa92dda8db7c65f7b355e729246d1bfadf2
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v33.0.2/wasmtime-v33.0.2-i686-windows-c-api.zip
    ref: 2c2f446fca3baa569dcfcd24e9a5bcfa0ae68a0319791d47bbe4f608d147c4f6
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v33.0.2/wasmtime-v33.0.2-riscv64gc-linux-c-api.tar.xz
    ref: ddcaa803e7e2a0c5fd355f95af99b426b936c5748ec2c3f51eba3f768a45c98a
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v33.0.2/wasmtime-v33.0.2-s390x-linux-c-api.tar.xz
    ref: f7daae5561c34b98dafe9741be11d6b410b0fc125c86b751e14152df37066086
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v33.0.2/wasmtime-v33.0.2-x86_64-android-c-api.tar.xz
    ref: d8d5bbade9c75530c5c96cdac3624b20dd0f488bcf8cc25051a5e41d86d93824
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v33.0.2/wasmtime-v33.0.2-x86_64-linux-c-api.tar.xz
    ref: c14d213a8d6e4f9cdfa61aeab956da587a8f83ec668250e99eec9a9213c602a7
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v33.0.2/wasmtime-v33.0.2-x86_64-macos-c-api.tar.xz
    ref: c93a94914e9e7bdac4df62a389dd8c6c9fd048ddfe5e0bb848f65a1a1e51cc16
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v33.0.2/wasmtime-v33.0.2-x86_64-mingw-c-api.zip
    ref: 7d036116620397753e4db40bfb3fcbc4cb52f279e9e81a4803a45b512ea8d3cc
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v33.0.2/wasmtime-v33.0.2-x86_64-musl-c-api.tar.xz
    ref: c5a8a470027f1f24ba57ce3f01aa8e6365faad0c93b8f0f210629971cde035ea
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v33.0.2/wasmtime-v33.0.2-x86_64-windows-c-api.zip
    ref: 5409c8737199c46223ada72a24d1aba83547c6f71b78cc2d94e9c4d126d1e962
    directory: zig-deps

  - kind: remote
    url: github_files:ziglibs/known-folders/archive/ab5cf5feb936fa3b72c95d3ad0c0c67791937ba1.tar.gz
    ref: 55a2380907da5e30a3a9991d73d5b4a1372a2c2bd508da4dad96c127a10625e9
    directory: zig-deps-git

  - kind: remote
    url: github_files:zigtools/lsp-kit/archive/fe98e895ca3bd1b39965ab30f0f252f7b7e83ee6.tar.gz
    ref: 46c57bad1922899bfae68e2d30a363061242dc2e808d6f27fc92ea8fe74c92db
    directory: zig-deps-git

  - kind: remote
    url: github_files:kristoff-it/scripty/archive/50dbab8945440089384f26ec165d870c29555247.tar.gz
    ref: 18325156728c48236270812947b4a1d24f9767899c771ddd21bfdb99b581fd30
    directory: zig-deps-git

  - kind: remote
    url: github_files:tree-sitter/zig-tree-sitter/archive/b4b72c903e69998fc88e27e154a5e3cc9166551b.tar.gz
    ref: 692a84a5fb85447bafff1203d272adfdf6d2a8602429157860f60a941cf27420
    directory: zig-deps-git

  - kind: remote
    url: github_files:kristoff-it/zig-afl-kit/archive/8ef04d1db48650345dca68da1e1b8f2615125c40.tar.gz
    ref: f422e6e7cad24bc346e3ca0e9e805d6b14a61089c048033d86887348ff0ef2be
    directory: zig-deps-git

  - kind: remote
    url: github_files:tree-sitter/tree-sitter-c/archive/refs/tags/v0.23.4.tar.gz
    ref: b66c5043e26d84e5f17a059af71b157bcf202221069ed220aa1696d7d1d28a7a
    directory: zig-deps

  - kind: remote
    url: github_files:tree-sitter/tree-sitter/archive/521da2b0a7e8815efbcf1e4b98e5ac16113c5763.tar.gz
    ref: 186bda14dd88c132005a0f578bf6522f155e1cf8a47b9ed68a10d584f03162c3
    directory: zig-deps-git

  - kind: remote
    url: github_files:allyourcodebase/AFLplusplus/archive/a52f1376e2d49720c39e4abf4aa4944afbf82191.tar.gz
    ref: 2814ce96a48d202a4ec0674996fd79c8391404736cd5f66c3e7cedef2a0646c5
    directory: zig-deps-git

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v29.0.1/wasmtime-v29.0.1-aarch64-android-c-api.tar.xz
    ref: aeda605be1c71ee9a96e3cd305e2c8f0295ba5ca62341c7140017fad3c9e9713
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v29.0.1/wasmtime-v29.0.1-aarch64-linux-c-api.tar.xz
    ref: 7ab76595f765d60ba14c498ec25506e519213c4ba783f52a7bec5370b09ace6d
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v29.0.1/wasmtime-v29.0.1-aarch64-macos-c-api.tar.xz
    ref: 3aa840ba24f14107bc7dd9b82b1b7b31ece8ea472e06820251ac76cafa8722c0
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v29.0.1/wasmtime-v29.0.1-riscv64gc-linux-c-api.tar.xz
    ref: fe69445a8b268276a4fff7e8a7de315abcd88aa5978337e790356d64e741b96c
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v29.0.1/wasmtime-v29.0.1-s390x-linux-c-api.tar.xz
    ref: 727ffe77f6b1a2b1f3ed5260a9d0000a33e45eea9b79fba929f1535f5af4cd03
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v29.0.1/wasmtime-v29.0.1-x86_64-android-c-api.tar.xz
    ref: b7a6a5adfb7cc5eeb5e3651a5dd60ec77c8827c8a689976c6c90bfe0b909a235
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v29.0.1/wasmtime-v29.0.1-x86_64-linux-c-api.tar.xz
    ref: 27871520e02193badd5a83e16a5009c45371ec5ec9e1df8342b4a17efc3e35b6
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v29.0.1/wasmtime-v29.0.1-x86_64-macos-c-api.tar.xz
    ref: 24fbf0845402437c5857b99d78583177a85a025c91d99a937c1e2c11ec09fcad
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v29.0.1/wasmtime-v29.0.1-x86_64-mingw-c-api.zip
    ref: 8371821d3da010417a686e7401459edbb54a32a388ed12aac64d412414625826
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v29.0.1/wasmtime-v29.0.1-x86_64-musl-c-api.tar.xz
    ref: 20f12b08e5ab564cf78aec02bffb154def8069d3b8654e04f94a31926cb9096f
    directory: zig-deps

  - kind: remote
    url: github_files:bytecodealliance/wasmtime/releases/download/v29.0.1/wasmtime-v29.0.1-x86_64-windows-c-api.zip
    ref: c5d85f7d912f8d2ab80a0d875398e3601de0e4e32c0d5370e2a67dc89fb0625f
    directory: zig-deps

  - kind: remote
    url: github_files:tree-sitter/zig-tree-sitter/archive/refs/tags/v0.25.0.tar.gz
    ref: b6bb1f813bfa0029eb2337041de2ea5c1407315d8870a2bae738e52262ad2613
    directory: zig-deps

  - kind: remote
    url: github_files:AFLplusplus/AFLplusplus/archive/v4.21c.tar.gz
    ref: 11f7c77d37cff6e7f65ac7cc55bab7901e0c6208e845a38764394d04ed567b30
    directory: zig-deps

  - kind: remote
    url: github_files:tree-sitter/tree-sitter/archive/refs/tags/v0.25.0.tar.gz
    ref: 3729e98e54a41a4c03f4f6c0be580d14ed88c113d75acf15397b16e05cf91129
    directory: zig-deps

config:
  build-commands:
    # Stage 1: Set up Zig cache
    - |
      export ZIG_GLOBAL_CACHE_DIR="/tmp/zig-cache"
      export ZIG_LIB_DIR="%{libdir}/zig"
      mkdir -p "$ZIG_GLOBAL_CACHE_DIR/p"

    # Stage 2: populate it from the staged dep tarballs. `zig fetch` computes
    # the content hash `zig build` expects, for git-declared deps as well as
    # plain tarballs. Do NOT hand-place git deps under p/<hash>: since Zig 0.16
    # such entries are ignored and the dep is re-fetched over the network,
    # which cannot work in the offline sandbox (same as seance.bst/falcond.bst).
    #
    # The cache location comes from ZIG_GLOBAL_CACHE_DIR alone. Zig 0.17 moved
    # package management into the build runner, and `zig fetch` there rejects
    # `--global-cache-dir` ("unrecognized parameter"), so neither command
    # passes it; the exported variable is honoured by both.
    #
    # A failed fetch warns instead of stopping. Some staged tarballs can't be
    # fetched on their own under Zig 0.17: tree-sitter v0.25.0 ships a
    # pre-0.14 build.zig.zon (`.name = "tree-sitter"`, a string, where 0.17
    # wants an enum literal). A dep like that can only work if `zig build` never
    # resolves it, such as a lazy dep for another target. If a dep the build
    # needs is missing, `zig build` fails trying to reach the network and
    # names it. Read the WARNING lines first.
    - |
      export ZIG_GLOBAL_CACHE_DIR="/tmp/zig-cache"
      export ZIG_LIB_DIR="%{libdir}/zig"
      for dep in zig-deps/* zig-deps-git/*; do
        echo "Fetching: $dep"
        zig fetch "$dep" || echo "WARNING: zig fetch failed for $dep" >&2
      done

    # Stage 3: write the zig build step to a script, so install-commands
    # stays one line (see the note there).
    - |
      cat > /tmp/zig-build.sh <<'BUILD'
      export ZIG_GLOBAL_CACHE_DIR="/tmp/zig-cache"
      export ZIG_LIB_DIR="%{libdir}/zig"
      run() {
        if ! "$@" 2>/tmp/zig-build.err; then
          cat /tmp/zig-build.err >&2
          echo "=== '$*' failed; its error lines: ===" >&2
          grep -n 'error' /tmp/zig-build.err | head -n 15 >&2
          exit 1
        fi
        cat /tmp/zig-build.err >&2
      }
      # Resolve the whole package tree first, one job at a time. With the
      # default parallelism, zig build's own package fetch under Zig 0.17
      # produced hash mismatches for a *different* set of deps on every CI
      # run (glslang, spirv-cross, breakpad, libxml2 and others), plus a
      # missing translate_c module (#1452). The set changing between runs
      # with identical inputs points at a race, not at wrong hashes, so
      # the declared hashes are left alone.
      run zig build --fetch=all -j1
      run env DESTDIR="$1" zig build \
        --prefix /usr \
        -Doptimize=ReleaseFast \
        -Dcpu=baseline \
        -Dpie=true \
        -Demit-docs=false \
        -Dversion-string=1.4.0
      BUILD

  install-commands:
    # Kept to one short line on purpose: on failure BuildStream prints only the
    # last 20 log lines, and with a long inline command those 20 are just its
    # echo. The script prints the errors last instead.
    - sh /tmp/zig-build.sh "%{install-root}"

kind: collect_initial_scripts

# Must build-depend on the element the image actually composes from, not on an
# inner stack: this plugin walks the dep tree it is given and silently collects
# nothing from anything outside it. oci/krytis/image.bst stages
# oci/krytis/filesystem.bst (-> runtime.bst -> stack.bst) into /layer, so
# stack.bst is the root that matches the image. Depending on base-system + bootc
# alone skipped every preset, sysusers and tmpfiles fragment contributed by
# stacks/{codecs,desktop,dev-tools}.bst, core/linux-cachyos.bst and
# core/initramfs.bst. See docs/skills/bst.md § collect_initial_scripts must
# build-depend on the element the image composes from (#934).
build-depends:
  - oci/krytis/stack.bst

config:
  path: /initial_scripts

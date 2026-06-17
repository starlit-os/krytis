kind: manual

sources:
- kind: local
  path: files/os-release

depends:
  - freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ""

environment:
  NAME: "StarlitOS"
  HOME_URL: "https://github.com/starlit-os/krytis"
  SUPPORT_URL: "https://github.com/starlit-os/krytis/issues"
  DOCUMENTATION_URL: "https://github.com/starlit-os/krytis"
  ID: "krytis"
  VERSION_ID: "Krytis"
  VERSION: "%{freedesktop-sdk-flatpak-branch}"

config:
  build-commands:
  - mkdir -p "%{install-root}%{indep-libdir}/"
  - |
    cat > "%{install-root}%{indep-libdir}/os-release" <<EOF
    NAME="${NAME}"
    PRETTY_NAME="${NAME} ${VERSION_ID}"
    VERSION="${VERSION}"
    VERSION_ID="${VERSION_ID}"
    BASE_OS_NAME="Freedesktop SDK ${VERSION}"
    ID="${ID}"
    ID_LIKE="org.freedesktop.platform"
    CPE_NAME="cpe:/o:starlit-os:krytis"
    HOME_URL="${HOME_URL}"
    SUPPORT_URL="${SUPPORT_URL}"
    BUG_REPORT_URL="${SUPPORT_URL}"
    DOCUMENTATION_URL="${DOCUMENTATION_URL}"
    DEFAULT_HOSTNAME="krytis"
    EOF
  - mkdir -p "%{install-root}%{sysconfdir}/"
  - ln -sf ../usr/lib/os-release "%{install-root}%{sysconfdir}/os-release"
  - |
    cat > "%{install-root}%{indep-libdir}/system-release" <<EOF
    Freedesktop SDK release %{freedesktop-sdk-flatpak-branch} (Flatpak runtime)
    EOF
  - ln -sf ../usr/lib/system-release "%{install-root}%{sysconfdir}/system-release"
  - install -Dm0644 issue "%{install-root}%{sysconfdir}/issue"

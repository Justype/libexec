# The oldest glibc condatainer supports. A binary needs a glibc at least as new as the one it was built on.
FROM almalinux:8

RUN dnf -y install dnf-plugins-core epel-release \
 && dnf config-manager --set-enabled powertools \
 && dnf -y install \
      gcc-toolset-12 make git curl tar xz bzip2 gzip patch file findutils which diffutils \
      autoconf automake libtool pkgconf-pkg-config gettext python39 patchelf \
      libseccomp-devel \
      zlib-devel libzstd-devel lz4-devel xz-devel lzo-devel libarchive-devel \
 && dnf clean all

# meson and ninja for libfuse 3. They do not depend on the image's packages.
RUN python3.9 -m pip install --no-cache-dir meson ninja

ENV BASH_ENV=/opt/rh/gcc-toolset-12/enable
WORKDIR /work

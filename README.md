# Packer

A small archive utility in ruby.

## Functionality

- print out the list of files contents, and their total uncompressed size
- print out archive size
- compress
- encrypt using passphrase

## Compression Backends

- [zip](https://infozip.sourceforge.net/Zip.html)
- [bz2 (bzip2)](https://sourceware.org/bzip2/)
- [7z (7-Zip)](https://www.7-zip.org/)
- [ouch](https://github.com/vrmiguel/ouch)
- [xz](https://tukaani.org/xz/)
- [zstd](https://github.com/facebook/zstd)
- [atool](https://www.nongnu.org/atool/)

## Encryption Backends

- [kryptor](https://github.com/samuel-lucas6/Kryptor)
- [age](https://age-encryption.org/)
- [gpg](https://gnupg.org/)
- [openssl](https://www.openssl.org/)
- [picocrypt](https://github.com/HACKERALERT/Picocrypt)

## Information Backends

- [tree](https://gitlab.com/OldManProgrammer/unix-tree)
- [du (GNU coreutils)](https://www.gnu.org/software/coreutils/)
- [gdu](https://github.com/dundee/gdu)

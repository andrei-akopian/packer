# Packer

A small Ruby gem for creating, compressing, encrypting, and timestamping archives on Unix systems. Runtime dependencies are Ruby's standard library and the relevant CLI utilities already installed on your system. Encryption is via symmetric keys (passphrases) and handled by the encryption utility you select.

Intended usage is for creating at rest archives of files, to be stored in locations you distrust. For example cheap cloud storage providers.

Alternative CLI tools like [`ouch`](https://github.com/ouch-org/ouch), [`atool`](https://www.nongnu.org/atool/), [`picocrypt`](https://github.com/Picocrypt/CLI) focus on either compression and encryption. Packer combines them into a single utility. For encrypted drives see [VeraCrypt](https://veracrypt.io/en/Downloads.html), or stock OS disk encryption software. For GUI try [Keka](https://www.keka.io/en/).

> [!WARNING]
> This tool is LLM generated, and hasn't been thoroughly reviewed.

![GIF demo showing the tool in use.](./assets/demo.gif)

[Link (this) repository on Github](https://github.com/andrei-akopian/packer). Licensed under [MIT License](./LICENSE.md)

## Functionality

- Archive formats: (e.g. `tar.gz`, `zip`, `7z`), provided by `ouch`, `atool` or other tools already installed on your system.
  - Compression levels: `none`, `min`, `some`, and `max`. Different formats have different compression level systems, these defaults hide them under a single API.
- Encryption backends: `age`, `gpg`, `openssl`, `kryptor`, or `picocrypt`.
- Automatic decryption and unpacking: `packer --decompress archive.tar.gz`.
- Detached timestamps via RFC 3161 timestamp authorities or OpenTimestamps.
- Tools like `tree` or `du` auto print archive contents and its size. You can copy their output for record keeping.

## Installation

Build and install from a checkout:

```bash
gem build packer-cli.gemspec
gem install ./packer-cli-2.1.0.gem
packer --help
```

The gem installs the `packer` executable. The original `packer.rb` command is
kept as a compatibility launcher for existing checkouts.

## Requirements

- Ruby 2.7 or newer
- RubyGems
- One or more backend tools installed on your `PATH`:
  - **compression:** `tar`, `zip`/`unzip`, `7z`/`7za`, `ouch`, `atool`
  - **encryption:** `age`, `gpg`, `openssl`, `kryptor`, `picocrypt`
  - **timestamping:** `openssl` and `curl` for RFC 3161; `ots` (`opentimestamps-client`) for OpenTimestamps
  - **info:** `tree`, `du`, `gdu`

Run `packer --list` to see which formats and providers are currently available.

## Usage

> [!TIP]
> It is recommended to `mv packer.rb ~/.local/bin/packer` and `chmod +x ~/.local/bin/packer`.

When in doubt:

```bash
packer --list      # installed formats, providers, and levels
packer --help      # full usage and examples
```

### Compression

```bash
# Default format and level (zip / balanced)
packer ~/Documents

# Choose format and level
packer -c tar.gz -l max ~/Documents

# Compress with a specific output name
packer -c zip -o backup ~/Documents

# Encrypt as well (plain archive is kept alongside the encrypted file)
packer -c tar.gz -e age -o backup ~/Documents

# Timestamp the final encrypted archive using both services
packer -c tar.gz -e age --timestamp both -o backup ~/Documents
```

### Timestamps

```bash
# OpenTimestamps (Bitcoin-calendar based, initially pending confirmation)
packer --timestamp ots ~/Documents

# RFC 3161 through DigiCert (default), Sectigo, or GlobalSign
packer --timestamp rfc3161 --tsa-url sectigo ~/Documents

# Verify any adjacent proof(s); the archive file must be present
packer --verify-timestamp backup.tar.gz.age
```

Packer timestamps the final deliverable (the encrypted file when encryption is
enabled), and writes detached sidecars: `<archive>.tsr` for RFC 3161 and
`<archive>.ots` for OpenTimestamps. RFC 3161 sends only a SHA-256 digest to the
authority, not the archive contents. OpenTimestamps uses remote calendars and
its proof may remain pending until a Bitcoin block confirms the commitment.
Network, authority, or calendar failures are reported as warnings; the archive
is kept, and Packer exits non-zero if any requested proof could not be obtained.
Timestamping is optional and does not replace a cryptographic signature: it
proves that these exact bytes existed no later than the recorded time, but does
not identify who created them.

The standard layout is one immutable final archive plus detached proof files.
Do not zip the archive and proof together after timestamping: doing so creates
a new outer file that the proof does not cover. If you need one transferable
bundle, place the archive and its sidecars together in a separate delivery
container, while retaining the proof's association with the exact archived
file. Packer avoids a second full-size ZIP copy, so timestamping itself uses
only small sidecars rather than another package-sized intermediate.

RFC 3161 authorities can be unavailable or change endpoints. The default is
DigiCert; `--tsa-url` accepts the `digicert`, `sectigo`, and `globalsign`
presets, or any compatible RFC 3161 HTTP(S) endpoint. Packer verifies the
returned token with the system CA store and checks that it matches the archive
before saving it. Keep both the archive and its detached proof for later
verification.

The preset names and RFC 3161 URLs are maintained in
`config/timestamp_authorities.yml`. Add an authority there to make it available
as a `--tsa-url` preset, or pass a compatible URL directly.

### Compression levels

for `-l <level>`

| Level | Meaning                                 |
|-------|-----------------------------------------|
| none  | store / no compression                  |
| min   | fast, low compression                   |
| some  | balanced (default)                      |
| max   | best compression, usually slower        |

Not every backend supports every level. If the first available provider cannot
honour a level, the script prints a warning, uses the provider's default, and
tells you which formats support the requested level.

### Encryption

```bash
packer -c zip -e age -o backup ~/Documents     # age passphrase
packer -c tar.gz -e gpg -o backup ~/Documents  # gpg symmetric
packer -c xz -e openssl -o backup ~/Documents  # openssl AES-256-CBC
```

The encrypted file is named `backup.tar.gz.age`, `backup.tar.gz.gpg`, etc., so the
compression format is self-describing.

### Decompression

```bash
# Plain archive
packer --decompress backup.tar.gz

# Encrypted archive (you will be prompted for the passphrase)
packer --decompress backup.tar.gz.age

# Restore to a specific directory
packer -d backup.tar.gz -o restored

# Explicitly delete the source archive and sidecars after successful extraction
packer -d backup.tar.gz --delete-after-unzip

# If the file name has no compression extension, force the format
packer -d backup.enc -c tar.gz
```

When an adjacent timestamp proof is found during extraction, Packer prints its
path and the verification command. Use `--verify-timestamp` before relying on
the archive. `--delete-after-unzip` is opt-in; when enabled, Packer advertises
that it will delete the input archive and adjacent timestamp sidecars only
after extraction succeeds.

## Development

There is a suite of tests:

```bash
ruby exe/packer --list
bash test/test_packer.sh
gem build packer-cli.gemspec
```

### Roadmap

- [ ] Consider publishing to a repository.

## Credits

Thanks goes to the developers of ruby, picocrypt, tar, ouch, and other tools this script takes advantage of for the heavy lifting.

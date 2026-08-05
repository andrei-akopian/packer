# Packer

A small, self-contained Ruby utility for creating and extracting compressed
and/or encrypted archives.  It uses only the Ruby standard library and the CLI
archiving tools that are already installed on your system.

## What it does

- **Compression** – packs a file or directory into one of several archive formats.
- **Compression levels** – choose between `none`, `min`, `some`, and `max`.
- **Provider selection** – you pick a *format* (e.g. `tar.gz`, `zip`, `7z`); the
  script picks the first installed *provider* that can create it.
- **Encryption** – optionally encrypt the archive with `age`, `gpg`, `openssl`,
  `kryptor`, or `picocrypt`.
- **Decryption / decompression** – `packer --decompress archive.tar.gz` or
  `packer -d archive.tar.gz.age` restores the original directory.
- **Before / after overview** – shows file count, total size, and archive size.

## Requirements

- Ruby (any recent version)
- One or more backend tools installed on your `PATH`:
  - **compression:** `tar`, `zip`/`unzip`, `7z`/`7za`, `ouch`, `atool`
  - **encryption:** `age`, `gpg`, `openssl`, `kryptor`, `picocrypt`
  - **info:** `tree`, `du`, `gdu`

Run `packer --list` to see which formats and providers are currently available.

## Usage

### Compression

```bash
# Default format and level (zip / balanced)
./packer.rb ~/Documents

# Choose format and level
./packer.rb -c tar.gz -l max ~/Documents

# Compress with a specific output name
./packer.rb -c zip -o backup ~/Documents

# Encrypt as well (plain archive is kept alongside the encrypted file)
./packer.rb -c tar.gz -e age -o backup ~/Documents
```

### Compression levels

| Level | Meaning                                 |
|-------|-----------------------------------------|
| none  | store / no compression                  |
| min   | fast, low compression                   |
| some  | balanced (default)                      |
| max   | best compression, usually slower        |

Not every provider supports every level.  If the first available provider cannot
honour a level, the script prints a warning, uses the provider's default, and
tells you which formats support the requested level.

### Encryption

```bash
./packer.rb -c zip -e age -o backup ~/Documents     # age passphrase
./packer.rb -c tar.gz -e gpg -o backup ~/Documents  # gpg symmetric
./packer.rb -c xz -e openssl -o backup ~/Documents  # openssl AES-256-CBC
```

The encrypted file is named `backup.tar.gz.age`, `backup.tar.gz.gpg`, etc., so the
compression format is self-describing.

### Decompression

```bash
# Plain archive
./packer.rb --decompress backup.tar.gz

# Encrypted archive (you will be prompted for the passphrase)
./packer.rb --decompress backup.tar.gz.age

# Restore to a specific directory
./packer.rb -d backup.tar.gz -o restored

# If the file name has no compression extension, force the format
./packer.rb -d backup.enc -c tar.gz
```

## Discovery

```bash
./packer.rb --list      # installed formats, providers, and levels
./packer.rb --help      # full usage and examples
```

## Error handling

The script validates requested formats and providers up front and prints a clear
error along with the installed alternatives.  For example, if you ask for a
format that is not installed, it lists the formats that are available.

## Testing

```bash
./test_packer.sh
```

The test suite exercises detection, compression, decompression, compression
levels, and encryption round-trips for the tools that are installed on the
current machine.

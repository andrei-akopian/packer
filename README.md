# Packer

A small, self-contained Ruby utility for creating, compressing, and encrypting archives on Unix systems. Only dependencies are Ruby standard library and relevant CLI utilities already pre-installed on your system. Encryption is via symmetric keys (passphrases) and handled by the encryption utility you select.

Intended usage is for creating at rest archives of files, to be stored in locations you distrust. For example cheap cloud storage providers.

Alternative CLI tools like [`ouch`](https://github.com/ouch-org/ouch), [`atool`](https://www.nongnu.org/atool/), [`picocrypt`](https://github.com/Picocrypt/CLI) focus on either compression and encryption. Packer combines them into a single utility. For encrypted drives see [VeraCrypt](https://veracrypt.io/en/Downloads.html), or stock OS disk encryption software. For GUI try [Keka](https://www.keka.io/en/).

> [!WARNING]
> This tool is LLM generated, and hasn't been thoroughly reviewed.

[Link (this) repository on Github](https://github.com/andrei-akopian/packer). Licensed under [MIT License](./LICENSE.md)

## Functionality

- Archive formats: (e.g. `tar.gz`, `zip`, `7z`), provided by `ouch`, `atool` or other tools already installed on your system.
  - Compression levels: `none`, `min`, `some`, and `max`. Different formats have different compression level systems, these defaults hide them under a single API.
- Encryption backends: `age`, `gpg`, `openssl`, `kryptor`, or `picocrypt`.
- Automatic decryption and unpacking: `packer --decompress archive.tar.gz`.
- Tools like `tree` or `du` auto print archive contents and its size. You can copy their output for record keeping.

## Requirements

- Ruby (any recent version)
- One or more backend tools installed on your `PATH`:
  - **compression:** `tar`, `zip`/`unzip`, `7z`/`7za`, `ouch`, `atool`
  - **encryption:** `age`, `gpg`, `openssl`, `kryptor`, `picocrypt`
  - **info:** `tree`, `du`, `gdu`

Run `packer --list` to see which formats and providers are currently available.

## Usage

> [!TIP]
> It is recommended to `mv packer.rb ~/.local/bin/packer` and `chmod +x ~/.local/bin/packer`.

When in doubt:

```bash
./packer.rb --list      # installed formats, providers, and levels
./packer.rb --help      # full usage and examples
```

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

## Development

There is a suite of tests:

```bash
bash test_packer.sh
```

### Roadmap

- [ ] Consider publishing to a repository.

## Credits

Thanks goes to the developers of ruby, picocrypt, tar, ouch, and other tools this script takes advantage of for the heavy lifting.

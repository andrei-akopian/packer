# frozen_string_literal: true

module Packer
  module_function

# Tool discovery
# ---------------------------------------------------------------------------

# @param cmd [String] executable name
# @return [String, nil] absolute path to the executable, or nil if not found
# @precondition PATH is a colon-separated list of directories
# @postcondition the returned path, if any, is an executable file
def find_tool(cmd)
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
    path = File.join(dir, cmd)
    return path if File.file?(path) && File.executable?(path)
  end
  nil
end

def esc(s)
  Shellwords.escape(s)
end

# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

LEVELS = %i[none min some max].freeze

# A provider that can create and/or extract a given archive format.
# @attr name [String] human-readable provider name
# @attr compress_tools [Array<String>] binaries required for compression
# @attr decompress_tools [Array<String>] binaries required for decompression
# @attr levels [Hash{Symbol => Array<String>, nil}] flag mapping for each level;
#       nil means the level is unsupported by this provider
# @attr compress [Proc] (out, parent_dir, base_name, flags) -> shell command
# @attr decompress [Proc] (archive, outdir) -> shell command
CompressProvider = Struct.new(:name, :compress_tools, :decompress_tools,
                              :levels, :compress, :decompress) do
  def tools_for(action)
    action == :compress ? compress_tools : decompress_tools
  end

  # @param action [:compress, :decompress]
  def available?(action)
    tools_for(action).all? { |t| Packer.find_tool(t) }
  end

  def supports_level?(level)
    levels.key?(level) && !levels[level].nil?
  end

  # @return [Array<String>, nil]
  def level_flags(level)
    supports_level?(level) ? levels[level] : nil
  end
end

# An archive format with an ordered list of providers.  Providers are tried in
# order; the first one that is installed and supports the requested level wins.
Format = Struct.new(:name, :ext, :providers) do
  def providers_for(action)
    providers.select { |p| p.available?(action) }
  end

  def available?(action = :compress)
    providers_for(action).any?
  end

  def pick_provider(action, level = nil)
    avail = providers_for(action)
    return nil if avail.empty?

    if action == :compress && level && level != :some
      exact = avail.find { |p| p.supports_level?(level) }
      return exact if exact
    end

    avail.first
  end
end

EncryptProvider = Struct.new(:name, :tools, :encrypt, :decrypt) do
  def available?
    tools.all? { |t| Packer.find_tool(t) }
  end
end

EncryptFormat = Struct.new(:name, :ext, :provider) do
  def available?
    provider.available?
  end
end

InfoBackend = Struct.new(:name, :tools, :command) do
  def available?
    tools.all? { |t| Packer.find_tool(t) }
  end
end

def cprov(name, compress_tools:, decompress_tools:, levels:, compress:, decompress:)
  CompressProvider.new(name, compress_tools, decompress_tools, levels, compress, decompress)
end

def eprov(name, tools:, encrypt:, decrypt:)
  EncryptProvider.new(name, tools, encrypt, decrypt)
end

# Shared tar-based compression builder.  Most tar formats use the same logic,
# differing only in the default flags and the decompression command.
def tar_compress_lambda(default_flags)
  lambda do |out, parent, base, flags|
    if flags && !flags.empty?
      "cd #{esc(parent)} && tar #{flags.map { |f| esc(f) }.join(' ')} -cf #{esc(out)} #{esc(base)}"
    else
      "cd #{esc(parent)} && tar #{default_flags} #{esc(out)} #{esc(base)}"
    end
  end
end

def tar_provider(name, default_flags, levels, decompress:)
  cprov(name,
        compress_tools: ["tar"],
        decompress_tools: ["tar"],
        levels: levels,
        compress: tar_compress_lambda(default_flags),
        decompress: decompress)
end

# ---------------------------------------------------------------------------
# Compression providers
# ---------------------------------------------------------------------------

OUCH = cprov(
  "ouch",
  compress_tools: ["ouch"],
  decompress_tools: ["ouch"],
  levels: { none: nil, min: ["--fast"], some: [], max: ["--slow"] },
  compress: lambda do |out, parent, base, flags|
    flag_str = flags && !flags.empty? ? flags.map { |f| esc(f) }.join(" ") : ""
    "cd #{esc(parent)} && ouch compress -y -q #{flag_str} #{esc(base)} #{esc(out)}"
  end,
  decompress: lambda do |archive, outdir|
    "ouch decompress -y -q -d #{esc(outdir)} #{esc(archive)}"
  end
)

ATOOL = cprov(
  "atool",
  compress_tools: ["apack"],
  decompress_tools: ["aunpack"],
  levels: {},
  compress: lambda do |out, parent, base, _flags|
    "cd #{esc(parent)} && apack #{esc(out)} #{esc(base)}"
  end,
  decompress: lambda do |archive, outdir|
    "aunpack -q -X #{esc(outdir)} #{esc(archive)}"
  end
)

ZIP = cprov(
  "zip",
  compress_tools: ["zip"],
  decompress_tools: ["unzip"],
  levels: { none: ["-0"], min: ["-1"], some: ["-6"], max: ["-9"] },
  compress: lambda do |out, parent, base, flags|
    "cd #{esc(parent)} && zip -r -q #{flags.map { |f| esc(f) }.join(' ')} #{esc(out)} #{esc(base)}"
  end,
  decompress: lambda do |archive, outdir|
    "unzip -q -d #{esc(outdir)} #{esc(archive)}"
  end
)

TAR = tar_provider(
  "tar",
  "-cf",
  { none: [], min: [], some: [], max: [] },
  decompress: ->(archive, outdir) { "tar -xf #{esc(archive)} -C #{esc(outdir)}" }
)

TAR_GZIP = tar_provider(
  "tar+gzip",
  "-czf",
  {
    min: ["--use-compress-program=gzip -1"],
    some: [],
    max: ["--use-compress-program=gzip -9"]
  },
  decompress: ->(archive, outdir) { "tar -xzf #{esc(archive)} -C #{esc(outdir)}" }
)

TAR_BZIP2 = tar_provider(
  "tar+bzip2",
  "-cjf",
  {
    min: ["--use-compress-program=bzip2 -1"],
    some: [],
    max: ["--use-compress-program=bzip2 -9"]
  },
  decompress: ->(archive, outdir) { "tar -xjf #{esc(archive)} -C #{esc(outdir)}" }
)

TAR_XZ = tar_provider(
  "tar+xz",
  "-cJf",
  {
    min: ["--use-compress-program=xz -0"],
    some: [],
    max: ["--use-compress-program=xz -9"]
  },
  decompress: ->(archive, outdir) { "tar -xJf #{esc(archive)} -C #{esc(outdir)}" }
)

TAR_ZSTD = cprov(
  "tar+zstd",
  compress_tools: ["tar", "zstd"],
  decompress_tools: ["tar", "zstd"],
  levels: {
    min: ["--use-compress-program=zstd -1"],
    some: ["--use-compress-program=zstd -3"],
    max: ["--use-compress-program=zstd -19"]
  },
  compress: lambda do |out, parent, base, flags|
    flag_str = flags ? flags.map { |f| esc(f) }.join(" ") : esc("--use-compress-program=zstd")
    "cd #{esc(parent)} && tar #{flag_str} -cf #{esc(out)} #{esc(base)}"
  end,
  decompress: lambda do |archive, outdir|
    "tar -I zstd -xf #{esc(archive)} -C #{esc(outdir)}"
  end
)

SEVEN_ZIP_TOOLS = %w[7z 7za 7zr].freeze
SEVEN_ZIP = cprov(
  "7z",
  compress_tools: SEVEN_ZIP_TOOLS,
  decompress_tools: SEVEN_ZIP_TOOLS,
  levels: { none: ["-mx0"], min: ["-mx1"], some: ["-mx5"], max: ["-mx9"] },
  compress: lambda do |out, parent, base, flags|
    bin = SEVEN_ZIP_TOOLS.map { |t| find_tool(t) }.compact.first
    "cd #{esc(parent)} && #{esc(bin)} a #{flags.map { |f| esc(f) }.join(' ')} -bso0 -bsp0 #{esc(out)} #{esc(base)}"
  end,
  decompress: lambda do |archive, outdir|
    bin = SEVEN_ZIP_TOOLS.map { |t| find_tool(t) }.compact.first
    "#{esc(bin)} x -o#{esc(outdir)} -bso0 -bsp0 #{esc(archive)}"
  end
)

COMPRESSION_FORMATS = {
  "tar"     => Format.new("tar",     ".tar",     [TAR, ATOOL]),
  "zip"     => Format.new("zip",     ".zip",     [ZIP, OUCH, ATOOL]),
  "tar.gz"  => Format.new("tar.gz",  ".tar.gz",  [TAR_GZIP, OUCH, ATOOL]),
  "tar.bz2" => Format.new("tar.bz2", ".tar.bz2", [TAR_BZIP2, OUCH, ATOOL]),
  "tar.xz"  => Format.new("tar.xz",  ".tar.xz",  [TAR_XZ, OUCH, ATOOL]),
  "tar.zst" => Format.new("tar.zst", ".tar.zst", [TAR_ZSTD, OUCH, ATOOL]),
  "7z"      => Format.new("7z",      ".7z",      [SEVEN_ZIP, OUCH, ATOOL])
}.freeze

COMPRESSION_ORDER = %w[zip tar.gz tar.bz2 tar.xz tar.zst 7z tar].freeze
NONE_PREFERRED_ORDER = %w[zip 7z tar].freeze

# ---------------------------------------------------------------------------
# Encryption providers
# ---------------------------------------------------------------------------

ENCRYPTION_FORMATS = {
  "age" => EncryptFormat.new(
    "age", ".age",
    eprov(
      "age",
      tools: ["age"],
      encrypt: lambda do |input, output|
        "age -p -o #{esc(output)} #{esc(input)}"
      end,
      decrypt: lambda do |input, output|
        "age -d -o #{esc(output)} #{esc(input)}"
      end
    )
  ),
  "gpg" => EncryptFormat.new(
    "gpg", ".gpg",
    eprov(
      "gpg",
      tools: ["gpg"],
      encrypt: lambda do |input, output|
        "gpg --symmetric --cipher-algo AES256 -o #{esc(output)} #{esc(input)}"
      end,
      decrypt: lambda do |input, output|
        "gpg --decrypt -o #{esc(output)} #{esc(input)}"
      end
    )
  ),
  "openssl" => EncryptFormat.new(
    "openssl", ".enc",
    eprov(
      "openssl",
      tools: ["openssl"],
      encrypt: lambda do |input, output|
        "openssl enc -aes-256-cbc -pbkdf2 -salt -in #{esc(input)} -out #{esc(output)}"
      end,
      decrypt: lambda do |input, output|
        "openssl enc -d -aes-256-cbc -pbkdf2 -in #{esc(input)} -out #{esc(output)}"
      end
    )
  ),
  "kryptor" => EncryptFormat.new(
    "kryptor", ".kryptor",
    eprov(
      "kryptor",
      tools: ["kryptor"],
      encrypt: lambda do |input, output|
        "kryptor encrypt #{esc(input)} -o #{esc(output)}"
      end,
      decrypt: lambda do |input, output|
        "kryptor decrypt #{esc(input)} -o #{esc(output)}"
      end
    )
  ),
  "picocrypt" => EncryptFormat.new(
    "picocrypt", ".pcv",
    eprov(
      "picocrypt",
      tools: ["picocrypt"],
      encrypt: lambda do |input, output|
        # Picocrypt writes the ciphertext next to the input with .pcv appended.
        parent = File.dirname(input)
        base = File.basename(input)
        "cd #{esc(parent)} && picocrypt #{esc(base)}"
      end,
      decrypt: lambda do |input, output|
        # Picocrypt writes the plaintext next to the .pcv file, which collides
        # with the original archive when we keep the plain archive alongside the
        # encrypted one.  Work in a temporary directory to avoid the collision.
        base = File.basename(input)
        expected_plain = base.sub(/\.pcv\z/, "")
        "tmpdir=$(mktemp -d) && trap 'rm -rf \"$tmpdir\"' EXIT && cp #{esc(input)} \"$tmpdir/\" && cd \"$tmpdir\" && picocrypt #{esc(base)} && mv #{esc(expected_plain)} #{esc(output)}"
      end
    )
  )
}.freeze

# ---------------------------------------------------------------------------
# Information backends
# ---------------------------------------------------------------------------

INFO_BACKENDS = {
  "tree" => InfoBackend.new("tree", ["tree"],
                            ->(target, bin) { Shellwords.join([bin, "-h", target]) }),
  "du"   => InfoBackend.new("du",   ["du"],
                            ->(target, bin) { Shellwords.join([bin, "-h", target]) }),
  "gdu"  => InfoBackend.new("gdu",  ["gdu"],
                            ->(target, bin) { Shellwords.join([bin, "-nh", target]) })
}.freeze

# ---------------------------------------------------------------------------
# Catalog helpers
# ---------------------------------------------------------------------------

def catalog(cat)
  case cat
  when :compress then COMPRESSION_FORMATS
  when :encrypt  then ENCRYPTION_FORMATS
  when :info     then INFO_BACKENDS
  else
    raise ArgumentError, "unknown category #{cat}"
  end
end

def installed_backends(cat)
  catalog(cat).select { |_, v| v.available? }.keys
end

def format_by_ext(path, cat)
  dict = cat.is_a?(Hash) ? cat : catalog(cat)
  dict.values.sort_by { |fmt| -fmt.ext.size }.find { |fmt| path.end_with?(fmt.ext) }
end

def default_compression_format(level)
  order = level == :none ? (NONE_PREFERRED_ORDER + COMPRESSION_ORDER).uniq : COMPRESSION_ORDER
  order.each do |name|
    fmt = COMPRESSION_FORMATS[name]
    next unless fmt

    provider = fmt.pick_provider(:compress, level)
    return fmt if provider
  end
  nil
end

def formats_supporting_level(level)
  COMPRESSION_FORMATS.select do |_, fmt|
    fmt.providers.any? { |p| p.supports_level?(level) }
  end.keys
end

# ---------------------------------------------------------------------------

end

#!/usr/bin/env ruby
# frozen_string_literal: true

# packer.rb - compress / encrypt / decompress utility using installed CLI tools.
#
# No external gems are required.  The script scans the PATH, asks the user for a
# compression *format* and an encryption *method*, then picks the first installed
# *provider* that can satisfy the request.  A separate decompression mode tries to
# unpack archives (and decrypt them first when the file extension says so) with the
# same provider catalog.
#
# Examples:
#   ./packer.rb -c tar.gz -l max ~/data
#   ./packer.rb -c zip -e age ~/data
#   ./packer.rb --decompress backup.tar.gz
#   ./packer.rb -d backup.tar.gz.age -o restored

require "shellwords"
require "fileutils"
require "tmpdir"

VERSION = "2.0.0"

# ---------------------------------------------------------------------------
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
    tools_for(action).all? { |t| find_tool(t) }
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
    tools.all? { |t| find_tool(t) }
  end
end

EncryptFormat = Struct.new(:name, :ext, :provider) do
  def available?
    provider.available?
  end
end

InfoBackend = Struct.new(:name, :tools, :command) do
  def available?
    tools.all? { |t| find_tool(t) }
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
        "tmpdir=$(mktemp -d) && cp #{esc(input)} \"$tmpdir/\" && cd \"$tmpdir\" && picocrypt #{esc(base)} && mv #{esc(expected_plain)} #{esc(output)} && rm -rf \"$tmpdir\""
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
# Argument parsing
# ---------------------------------------------------------------------------

def parse_args(argv)
  opts = {
    compress: nil,
    level: "some",
    encrypt: nil,
    info: nil,
    output: nil,
    decompress: nil,
    help: false,
    list: false,
    target: nil
  }
  key_map = { "c" => :compress, "l" => :level, "e" => :encrypt,
              "i" => :info,     "o" => :output }

  i = 0
  while i < argv.size
    arg = argv[i]
    case arg
    when "-h", "--help"
      opts[:help] = true
    when "-L", "--list"
      opts[:list] = true
    when "-d", "--decompress"
      val = argv[i += 1]
      unless val
        warn "Error: #{arg} requires an archive file"
        return { error: true }
      end
      opts[:decompress] = val
    when /^--(compress|level|encrypt|info|output)(?:=(.*))?$/
      key = Regexp.last_match(1).to_sym
      val = Regexp.last_match(2)
      val = argv[i += 1] if val.nil? || val.empty?
      unless val
        warn "Error: #{arg} requires a value"
        return { error: true }
      end
      opts[key] = val
    when /^-[cleio]$/
      key = key_map[arg[1]]
      val = argv[i += 1]
      unless val
        warn "Error: #{arg} requires a value"
        return { error: true }
      end
      opts[key] = val
    when "--"
      i += 1
      if i < argv.size && opts[:target].nil?
        opts[:target] = argv[i]
      end
      break
    when /^--/
      warn "Error: unknown option '#{arg}'.  Run with --help for usage."
      return { error: true }
    else
      if opts[:target]
        warn "Error: only one target/archive is allowed"
        return { error: true }
      end
      opts[:target] = arg
    end
    i += 1
  end

  opts
end

def parse_level(str)
  str.to_s.downcase.to_sym
end

# ---------------------------------------------------------------------------
# Help and listing
# ---------------------------------------------------------------------------

def banner
  "packer v#{VERSION} - compress / encrypt / decompress with installed CLI tools"
end

def hr(char = "=", n = 64)
  char * n
end

def detailed_help
  <<~TEXT
    #{banner}

    USAGE

      Compression:
        packer [options] <target>

      Decompression (optionally decrypts first by file extension):
        packer -d, --decompress <archive> [-o <dir>]

    OPTIONS

      -c, --compress FORMAT   Compression format (default: first installed)
      -l, --level LEVEL       Compression level: none, min, some, max (default: some)
      -e, --encrypt METHOD    Encryption method: age, gpg, openssl, kryptor, picocrypt
      -i, --info TOOL         Info backend: tree, du, gdu
      -o, --output PATH       Output archive (compression) or output directory (decompression)
      -d, --decompress FILE   Decompress / decrypt FILE
      -L, --list              List installed formats and providers
      -h, --help              Show this help

    COMPRESSION FORMATS

      #{COMPRESSION_FORMATS.keys.join(', ')}

    COMPRESSION LEVELS

      none  - store / no compression (zip, 7z, tar)
      min   - fast, low compression
      some  - balanced (default)
      max   - best compression, slower

      If a format cannot honour a level, the first installed provider is used
      and a warning is printed.  Use --list to see what each provider supports.

    EXAMPLES

      packer -c tar.gz -l max ~/documents
      packer -c zip -e age -o backup.zip ~/photos
      packer --decompress backup.tar.gz
      packer -d backup.tar.gz.age -o restored
  TEXT
end

def provider_status(provider, action)
  provider.available?(action) ? "" : " (missing)"
end

def level_list(provider)
  return "" if provider.levels.empty?

  provider.levels.select { |_, v| !v.nil? }.keys.map(&:to_s).join("/")
end

def print_list
  puts "Compression formats:"
  COMPRESSION_FORMATS.each do |name, fmt|
    avail = fmt.available?(:compress) ? "" : " (none installed)"
    puts "  #{name} (#{fmt.ext})#{avail}"
    fmt.providers.each do |p|
      lvls = level_list(p)
      lvls_str = lvls.empty? ? "" : " [#{lvls}]"
      puts "    - #{p.name}#{provider_status(p, :compress)}#{lvls_str}"
    end
  end
  puts
  puts "Encryption methods:"
  ENCRYPTION_FORMATS.each do |name, fmt|
    status = fmt.available? ? "" : " (missing)"
    puts "  #{name} (#{fmt.ext}) - #{fmt.provider.name}#{status}"
  end
  puts
  puts "Info backends:"
  INFO_BACKENDS.each do |name, backend|
    status = backend.available? ? "" : " (missing)"
    puts "  #{name}#{status}"
  end
end

# ---------------------------------------------------------------------------
# Size / listing helpers
# ---------------------------------------------------------------------------

def human_size(bytes)
  bytes = bytes.to_f
  return "0 B" if bytes.zero?

  units = %w[B KB MB GB TB PB]
  i = 0
  while bytes >= 1024 && i < units.size - 1
    bytes /= 1024
    i += 1
  end
  format("%6.1f %s", bytes, units[i])
end

def pct(size, total)
  return "0.0% of original" if total.to_f.zero?

  format("%.1f%% of original", 100.0 * size / total)
end

def collect_files(target)
  if File.directory?(target)
    Dir.glob(File.join(target, "**", "*"), File::FNM_DOTMATCH).select { |p| File.file?(p) }
  elsif File.file?(target)
    [target]
  else
    []
  end
end

def print_file_list(files, cap = 100)
  return if files.empty?

  files.each_with_index do |f, idx|
    if idx >= cap
      puts "  ... and #{files.size - cap} more file(s)"
      break
    end
    puts "  %8s  %s" % [human_size(File.size(f)), f]
  end
end

# ---------------------------------------------------------------------------
# Command execution
# ---------------------------------------------------------------------------

def run(cmd)
  system(cmd)
end

# ---------------------------------------------------------------------------
# Compression / encryption / decompression runners
# ---------------------------------------------------------------------------

def archive_path(target, format, user_output)
  if user_output
    path = File.expand_path(user_output)
    unless path.end_with?(format.ext)
      warn "Note: appending '#{format.ext}' to the output path to keep the archive format clear."
      path += format.ext
    end
    path
  else
    ts = Time.now.strftime("%Y%m%d-%H%M%S")
    File.join(Dir.pwd, "#{File.basename(target)}_#{ts}#{format.ext}")
  end
end

def ensure_outdir(path)
  dir = File.dirname(path)
  return true if File.directory?(dir)

  warn "Error: output directory does not exist: #{dir}"
  false
end

def run_compress(format, provider, out, target, level)
  parent = File.dirname(target)
  base = File.basename(target)
  flags = provider.level_flags(level)
  cmd = provider.compress.call(out, parent, base, flags)

  puts "\n== Compressing #{format.name} with #{provider.name} (level: #{level}) =="
  ok = run(cmd)
  unless ok
    warn "Error: compression command failed"
    File.delete(out) if File.exist?(out)
    return false
  end
  true
end

def run_encrypt(enc_fmt, archive, enc_out)
  cmd = enc_fmt.provider.encrypt.call(archive, enc_out)
  puts "\n== Encrypting with #{enc_fmt.name} (#{enc_fmt.provider.name}) =="
  puts "    (you will be prompted for a passphrase)"
  ok = run(cmd)
  unless ok
    warn "Error: encryption command failed"
    File.delete(enc_out) if File.exist?(enc_out)
    return false
  end
  true
end

def default_decompress_dir(input_path, comp_fmt)
  base = File.basename(input_path)
  ENCRYPTION_FORMATS.each_value do |fmt|
    base = base.sub(/#{Regexp.escape(fmt.ext)}\z/, "")
  end
  base = base.sub(/#{Regexp.escape(comp_fmt.ext)}\z/, "")
  base = "extracted" if base.empty?
  File.join(Dir.pwd, base)
end

def run_decompress(input, user_output_dir, force_format_name = nil)
  original_input = File.expand_path(input)
  unless File.exist?(original_input)
    warn "Error: archive not found: #{original_input}"
    return 1
  end

  decrypted_path = nil
  active_input = original_input

  enc_fmt = format_by_ext(original_input, ENCRYPTION_FORMATS)
  if enc_fmt
    unless enc_fmt.available?
      warn "Error: encryption method '#{enc_fmt.name}' is not installed."
      return 1
    end

    inner_path = original_input.sub(/#{Regexp.escape(enc_fmt.ext)}\z/, "")
    inner_fmt = force_format_name ? COMPRESSION_FORMATS[force_format_name] : format_by_ext(inner_path, COMPRESSION_FORMATS)

    unless inner_fmt
      warn "Error: cannot identify the archive format inside encrypted file #{original_input}"
      warn "       Expected an extension such as: #{COMPRESSION_FORMATS.values.map(&:ext).join(', ')}"
      warn "       Hint: name the encrypted file like backup.tar.gz.enc, or use -c <format>"
      return 1
    end

    decrypted_path = File.join(Dir.tmpdir,
                               "packer_decrypt_#{Process.pid}_#{Time.now.to_i}_#{File.basename(inner_path)}")
    puts "\n== Decrypting #{enc_fmt.name} with #{enc_fmt.provider.name} =="
    cmd = enc_fmt.provider.decrypt.call(original_input, decrypted_path)
    ok = run(cmd)
    unless ok
      warn "Error: decryption failed"
      File.delete(decrypted_path) if File.exist?(decrypted_path)
      return 1
    end
    active_input = decrypted_path
    comp_fmt = inner_fmt
  else
    comp_fmt = force_format_name ? COMPRESSION_FORMATS[force_format_name] : format_by_ext(active_input, COMPRESSION_FORMATS)
  end

  unless comp_fmt
    warn "Error: cannot identify archive format for: #{original_input}"
    warn "       Supported extensions: #{COMPRESSION_FORMATS.values.map(&:ext).join(', ')}"
    warn "       Hint: use -c <format> to force the format"
    File.delete(decrypted_path) if decrypted_path && File.exist?(decrypted_path)
    return 1
  end

  provider = comp_fmt.pick_provider(:decompress, nil)
  unless provider
    warn "Error: no installed tool can decompress #{comp_fmt.name} archives."
    warn "       Providers: #{comp_fmt.providers.map(&:name).join(', ')}"
    File.delete(decrypted_path) if decrypted_path && File.exist?(decrypted_path)
    return 1
  end

  output_dir = user_output_dir ? File.expand_path(user_output_dir)
                               : default_decompress_dir(original_input, comp_fmt)
  FileUtils.mkdir_p(output_dir)

  puts "\n== Decompressing #{comp_fmt.name} with #{provider.name} =="
  cmd = provider.decompress.call(active_input, output_dir)
  ok = run(cmd)
  if ok
    puts "Done. Extracted to: #{output_dir}"
  else
    warn "Error: decompression command failed"
  end

  File.delete(decrypted_path) if decrypted_path && File.exist?(decrypted_path)
  ok ? 0 : 1
end

# ---------------------------------------------------------------------------
# Before / After reporting
# ---------------------------------------------------------------------------

def print_before(target, files, total, info_name)
  puts hr
  puts "BEFORE"
  puts "  Target:      #{target}"
  puts "  File count:  #{files.size}"
  puts "  Total size:  #{human_size(total)}"

  if info_name
    backend = INFO_BACKENDS[info_name]
    if backend && backend.available?
      cmd = backend.command.call(target, find_tool(backend.tools.first))
      puts "  Listing via #{info_name}:"
      system(cmd)
    else
      warn "  Warning: info backend '#{info_name}' is not available"
      print_file_list(files)
    end
  else
    print_file_list(files)
  end
  puts hr
end

def print_after(archive, enc_out, total)
  puts hr
  puts "AFTER"
  if archive && File.exist?(archive)
    puts "  Archive:     #{archive}"
    puts "  Archive:     #{human_size(File.size(archive))}  (#{pct(File.size(archive), total)})"
  end
  if enc_out && File.exist?(enc_out)
    puts "  Encrypted:   #{enc_out}"
    puts "  Encrypted:   #{human_size(File.size(enc_out))}  (#{pct(File.size(enc_out), total)})"
  end
  puts hr
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(argv)
  opts = parse_args(argv)
  if opts[:error]
    puts detailed_help
    return 2
  end

  if opts[:help]
    puts detailed_help
    return 0
  end

  if opts[:list]
    puts banner
    print_list
    return 0
  end

  if opts[:decompress]
    return run_decompress(opts[:decompress], opts[:output], opts[:compress])
  end

  unless opts[:target]
    warn "Error: no target given.  Use --help for usage."
    return 2
  end

  target = File.expand_path(opts[:target])
  unless File.exist?(target)
    warn "Error: target does not exist: #{target}"
    return 1
  end

  level = parse_level(opts[:level])
  unless LEVELS.include?(level)
    warn "Error: unknown compression level '#{opts[:level]}'"
    warn "       Levels: #{LEVELS.join(', ')}"
    return 1
  end

  # Choose compression format: explicit, inferred from output extension, or default.
  comp_fmt = nil
  if opts[:compress]
    comp_fmt = COMPRESSION_FORMATS[opts[:compress]]
    unless comp_fmt
      warn "Error: unknown compression format '#{opts[:compress]}'"
      warn "       Known formats: #{COMPRESSION_FORMATS.keys.join(', ')}"
      warn "       Installed:     #{installed_backends(:compress).join(', ')}"
      return 1
    end
  elsif opts[:output]
    comp_fmt = format_by_ext(opts[:output], COMPRESSION_FORMATS)
  end
  comp_fmt ||= default_compression_format(level)

  unless comp_fmt
    warn "Error: no compression format is available."
    warn "       Install one of: #{COMPRESSION_FORMATS.values.flat_map { |f| f.providers.map(&:name) }.uniq.join(', ')}"
    return 1
  end

  provider = comp_fmt.pick_provider(:compress, level)
  unless provider
    warn "Error: no installed provider can create #{comp_fmt.name} archives."
    warn "       Providers: #{comp_fmt.providers.map(&:name).join(', ')}"
    return 1
  end

  if level != :some && !provider.supports_level?(level)
    warn "Warning: provider '#{provider.name}' does not support level '#{level}' for #{comp_fmt.name}."
    warn "         Using default compression.  Formats that support '#{level}': #{formats_supporting_level(level).join(', ')}"
  end

  archive = archive_path(target, comp_fmt, opts[:output])
  return 1 unless ensure_outdir(archive)

  files = collect_files(target)
  total = files.sum { |p| File.size(p) }

  info_name = opts[:info] || installed_backends(:info).first
  print_before(target, files, total, info_name)

  return 1 unless run_compress(comp_fmt, provider, archive, target, level)

  enc_out = nil
  if opts[:encrypt]
    enc_fmt = ENCRYPTION_FORMATS[opts[:encrypt]]
    unless enc_fmt
      warn "Error: unknown encryption method '#{opts[:encrypt]}'"
      warn "       Known methods: #{ENCRYPTION_FORMATS.keys.join(', ')}"
      warn "       Installed:     #{installed_backends(:encrypt).join(', ')}"
      return 1
    end
    unless enc_fmt.available?
      warn "Error: encryption method '#{opts[:encrypt]}' is not installed"
      warn "       Install: #{enc_fmt.provider.tools.join(', ')}"
      return 1
    end
    enc_out = archive + enc_fmt.ext
    return 1 unless run_encrypt(enc_fmt, archive, enc_out)
  end

  print_after(archive, enc_out, total)
  puts "Done."
  0
end

exit main(ARGV) if $PROGRAM_NAME == __FILE__

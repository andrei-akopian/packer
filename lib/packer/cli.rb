# frozen_string_literal: true

module Packer
  module_function

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
    timestamp: nil,
    tsa_url: nil,
    verify_timestamp: nil,
    delete_after_unzip: false,
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
    when "-t", "-T", "-V", "--timestamp", "--tsa-url", "--verify-timestamp"
      val = argv[i += 1]
      unless val && !val.start_with?("-")
        warn "Error: #{arg} requires a value"
        return { error: true }
      end
      key = {
        "-t" => :timestamp, "--timestamp" => :timestamp,
        "-T" => :tsa_url, "--tsa-url" => :tsa_url,
        "-V" => :verify_timestamp, "--verify-timestamp" => :verify_timestamp
      }.fetch(arg)
      opts[key] = val
    when "--delete-after-unzip"
      opts[:delete_after_unzip] = true
    when /^--(compress|level|encrypt|info|output|timestamp|tsa-url|verify-timestamp)(?:=(.*))?$/
      key = Regexp.last_match(1).to_sym
      key = { "tsa-url" => :tsa_url, "verify-timestamp" => :verify_timestamp }.fetch(key.to_s, key)
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
        remaining = argv[(i + 1)..]
        unless remaining && remaining.size == 1 && opts[:target].nil?
          warn "Error: '--' must be followed by exactly one target"
          return { error: true }
        end
        opts[:target] = remaining.first
        break
      when /^--/
        warn "Error: unknown option '#{arg}'.  Run with --help for usage."
        return { error: true }
      when /^-/
        warn "Error: unknown option '#{arg}'. Use '--' before a target beginning with '-'."
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
        packer -V, --verify-timestamp <archive>

    OPTIONS

      -c, --compress FORMAT   Compression format (default: first installed)
      -l, --level LEVEL       Compression level: none, min, some, max (default: some)
      -e, --encrypt METHOD    Encryption method: age, gpg, openssl, kryptor, picocrypt
      -t, --timestamp MODE    Detached proof: ots, rfc3161, or both
      -T, --tsa-url NAME|URL  RFC 3161 authority: digicert (default), sectigo, globalsign, or URL
      -V, --verify-timestamp FILE  Verify adjacent .ots and/or .tsr proofs
          --delete-after-unzip    Delete input archive and timestamp proofs after successful extraction
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
      packer -t both -c zip ~/photos
      packer -V backup.zip
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
  puts
  puts "Timestamping:"
  puts "  RFC 3161 (openssl + curl)#{find_tool('openssl') && find_tool('curl') ? '' : ' (missing tool)'}"
  puts "    authorities: #{TSA_CONFIG.fetch('authorities').keys.join(', ')}; custom endpoints via --tsa-url"
  puts "  OpenTimestamps (ots)#{find_tool('ots') ? '' : ' (missing)'}"
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
    if opts[:timestamp] || opts[:tsa_url] || opts[:encrypt] || opts[:verify_timestamp] ||
       opts[:target] || opts[:info]
      warn "Error: decompression cannot be combined with compression, encryption, timestamp creation, or a second target"
      return 2
    end
    return run_decompress(opts[:decompress], opts[:output], opts[:compress], opts[:delete_after_unzip])
  end

  if opts[:verify_timestamp]
    if opts[:decompress] || opts[:timestamp] || opts[:tsa_url] || opts[:delete_after_unzip] ||
       opts[:encrypt] || opts[:compress] || opts[:output] || opts[:target] || opts[:info]
      warn "Error: --verify-timestamp cannot be combined with other operations"
      return 2
    end
    return 0 if verify_timestamp(File.expand_path(opts[:verify_timestamp]))

    return 1
  end

  if opts[:delete_after_unzip]
    warn "Error: --delete-after-unzip can only be used with --decompress"
    return 2
  end

  timestamp_mode = opts[:timestamp]&.downcase
  if timestamp_mode && !%w[ots rfc3161 both].include?(timestamp_mode)
    warn "Error: unknown timestamp mode '#{opts[:timestamp]}'"
    warn "       Modes: ots, rfc3161, both"
    return 2
  end
  if opts[:tsa_url] && timestamp_mode && !%w[rfc3161 both].include?(timestamp_mode)
    warn "Error: --tsa-url requires --timestamp rfc3161 or --timestamp both"
    return 2
  end
  if opts[:tsa_url] && !timestamp_mode
    warn "Error: --tsa-url requires --timestamp rfc3161 or --timestamp both"
    return 2
  end
  tsa_url = timestamp_authority_url(opts[:tsa_url])
  if tsa_url && !tsa_url.match?(%r{\Ahttps?://}i)
    warn "Error: --tsa-url must use http:// or https://"
    return 2
  end

  unless opts[:target]
    warn "Error: no target given.  Use --help for usage."
    return 2
  end

  target = File.expand_path(opts[:target])
  unless File.file?(target) || File.directory?(target)
    warn "Error: target is not an existing regular file or directory: #{target}"
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

  enc_fmt = nil
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
  end
  enc_out = enc_fmt ? archive + enc_fmt.ext : nil
  unless validate_output_plan(target, archive, enc_out, timestamp_mode)
    return 1
  end

  files = collect_files(target)
  total = files.sum { |p| File.size(p) }

  if timestamp_mode
    puts "Timestamping adds detached proof sidecars only; Packer will not re-zip the package."
  end
  if opts[:encrypt]
    free = free_space(File.dirname(archive))
    estimate = (total * 2) + (1024 * 1024)
    if free && free < estimate
      warn "Warning: only #{human_size(free)} is free; compression plus keeping both the plain and encrypted archives may need roughly #{human_size(estimate)}."
    end
  end

  info_name = opts[:info] || installed_backends(:info).first
  print_before(target, files, total, info_name)

  return 1 unless run_compress(comp_fmt, provider, archive, target, level)

  if enc_fmt
    free = free_space(File.dirname(enc_out))
    required = File.size(archive) + (1024 * 1024)
    if free && free < required
      warn "Error: not enough free disk space to safely create the encrypted copy (#{human_size(free)} free; about #{human_size(required)} needed)."
      warn "       The plain archive is preserved at #{archive}"
      return 1
    end
    return 1 unless run_encrypt(enc_fmt, archive, enc_out)
  end

  timestamp_target = enc_out || archive
  timestamp_ok = true
  if timestamp_mode
    proofs = timestamp_proof_paths(timestamp_target)
    tsa_url ||= default_timestamp_authority_url
    if %w[ots both].include?(timestamp_mode)
      timestamp_ok = stamp_ots(timestamp_target, proofs[:ots]) && timestamp_ok
    end
    if %w[rfc3161 both].include?(timestamp_mode)
      rfc_ok = stamp_rfc3161(timestamp_target, proofs[:rfc3161], tsa_url)
      timestamp_ok = rfc_ok && timestamp_ok
    end
  end

  print_after(archive, enc_out, total)
  if timestamp_ok
    puts "Done."
    0
  else
    warn "Archive created, but one or more requested timestamp proofs were not obtained."
    1
  end
end

end

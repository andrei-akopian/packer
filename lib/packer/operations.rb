# frozen_string_literal: true

module Packer
  module_function

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

# Returns free bytes on the filesystem containing path, or nil if df is unavailable.
def free_space(path)
  output, status = Open3.capture2("df", "-Pk", path)
  return nil unless status.success?

  available_kb = Integer(output.lines.last.to_s.split[-3], exception: false)
  available_kb && available_kb * 1024
rescue Errno::ENOENT
  nil
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

# Reserve names before work starts so failures can never erase an older artifact.
def validate_output_plan(target, archive, encrypted_output, timestamp_mode)
  final_package = encrypted_output || archive
  outputs = [archive, encrypted_output].compact
  if timestamp_mode
    outputs.concat(timestamp_proof_paths(final_package).values.select do |proof|
      (timestamp_mode == "ots" && proof.end_with?(".ots")) ||
        (timestamp_mode == "rfc3161" && proof.end_with?(".tsr")) || timestamp_mode == "both"
    end)
  end

  collision = outputs.find { |path| File.exist?(path) || File.symlink?(path) }
  if collision
    warn "Error: output already exists: #{collision}"
    warn "       Choose another output path; existing files are not overwritten."
    return false
  end

  if File.directory?(target)
    source_root = File.realpath(target)
    outputs.each do |path|
      output_parent = File.realpath(File.dirname(path))
      source_prefix = source_root == File::SEPARATOR ? source_root : source_root + File::SEPARATOR
      if output_parent == source_root || output_parent.start_with?(source_prefix)
        warn "Error: output would be created inside the directory being archived: #{path}"
        warn "       Select an output directory outside #{source_root}."
        return false
      end
    end
  end
  true
rescue SystemCallError => e
  warn "Error: cannot validate output paths: #{e.message}"
  false
end

def run_compress(format, provider, out, target, level)
  parent = File.dirname(target)
  base = File.basename(target)
  base = "./#{base}" if base.start_with?("-")
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

def run_decompress(input, user_output_dir, force_format_name = nil, delete_after = false)
  original_input = File.expand_path(input)
  unless File.file?(original_input)
    warn "Error: archive not found or not a regular file: #{original_input}"
    return 1
  end

  decrypted_path = nil
  decrypted_dir = nil
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

    decrypted_dir = Dir.mktmpdir("packer-decrypt-")
    decrypted_path = File.join(decrypted_dir, "archive")
    puts "\n== Decrypting #{enc_fmt.name} with #{enc_fmt.provider.name} =="
    cmd = enc_fmt.provider.decrypt.call(original_input, decrypted_path)
    ok = run(cmd)
    unless ok
      warn "Error: decryption failed"
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
    return 1
  end

  provider = comp_fmt.pick_provider(:decompress, nil)
  unless provider
    warn "Error: no installed tool can decompress #{comp_fmt.name} archives."
    warn "       Providers: #{comp_fmt.providers.map(&:name).join(', ')}"
    return 1
  end

  output_dir = user_output_dir ? File.expand_path(user_output_dir)
                               : default_decompress_dir(original_input, comp_fmt)
  FileUtils.mkdir_p(output_dir)

  proof_files = timestamp_proof_paths(original_input).values.select { |path| File.file?(path) }
  if proof_files.any?
    puts "Timestamp proof sidecar(s) found: #{proof_files.join(', ')}"
    puts "  Verify before relying on the archive with: packer --verify-timestamp #{original_input}"
  end
  if delete_after
    puts "AUTODELETE after successful extraction is enabled: the input archive and its timestamp proof sidecars will be removed."
  end

  puts "\n== Decompressing #{comp_fmt.name} with #{provider.name} =="
  cmd = provider.decompress.call(active_input, output_dir)
  ok = run(cmd)
  if ok
    puts "Done. Extracted to: #{output_dir}"
    if delete_after
      ([original_input] + proof_files).each { |path| File.delete(path) if File.file?(path) }
      puts "  Deleted input archive and #{proof_files.size} timestamp proof sidecar(s)."
    end
  else
    warn "Error: decompression command failed"
  end

  ok ? 0 : 1
ensure
  FileUtils.remove_entry(decrypted_dir) if decrypted_dir && File.directory?(decrypted_dir)
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
  [archive, enc_out].compact.each do |package|
    timestamp_proof_paths(package).each_value do |proof|
      next unless File.file?(proof)

      puts "  Timestamp:   #{proof} (#{human_size(File.size(proof))})"
    end
  end
  puts hr
end

# ---------------------------------------------------------------------------

end

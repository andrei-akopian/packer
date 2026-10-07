# frozen_string_literal: true

module Packer
  module_function

  TSA_CONFIG_PATH = File.expand_path("../../config/timestamp_authorities.yml", __dir__).freeze
  TSA_CONFIG = YAML.safe_load(File.read(TSA_CONFIG_PATH), aliases: false).freeze

  def timestamp_proof_paths(path)
    { ots: "#{path}.ots", rfc3161: "#{path}.tsr" }
  end

  def timestamp_authority_url(name_or_url)
    return nil unless name_or_url

    TSA_CONFIG.fetch("authorities").each do |name, authority|
      return authority.fetch("url") if name.casecmp?(name_or_url)
    end
    name_or_url
  end

  def default_timestamp_authority_url
    default_name = TSA_CONFIG.fetch("default")
    TSA_CONFIG.fetch("authorities").fetch(default_name).fetch("url")
  end

  def timestamp_failure(message)
    warn "Warning: timestamping failed: #{message}"
    warn "         The archive is preserved, but it has no verified timestamp proof from this attempt."
    false
  end

  # Creates a detached OpenTimestamps proof. It normally begins as a pending
  # calendar attestation and becomes Bitcoin-chain verifiable after confirmation.
  def stamp_ots(path, proof_path)
    ots = find_tool("ots")
    return timestamp_failure("'ots' is not installed; install opentimestamps-client") unless ots
    return timestamp_failure("proof already exists: #{proof_path}") if File.exist?(proof_path)

    output, error, status = Open3.capture3(ots, "stamp", path)
    print output unless output.empty?
    warn error unless error.empty?
    unless status.success? && File.file?(proof_path) && File.size?(proof_path)
      File.delete(proof_path) if File.exist?(proof_path)
      return timestamp_failure("OpenTimestamps client did not produce a proof (network/calendar failure is possible)")
    end

    puts "  OpenTimestamps proof: #{proof_path} (calendar confirmation may still be pending)"
    true
  rescue StandardError => e
    File.delete(proof_path) if File.exist?(proof_path)
    timestamp_failure(e.message)
  end

  # RFC 3161 tokens are detached DER files and are verified before publication.
  def stamp_rfc3161(path, proof_path, tsa_url)
    openssl = find_tool("openssl")
    curl = find_tool("curl")
    return timestamp_failure("'openssl' is not installed") unless openssl
    return timestamp_failure("'curl' is not installed (needed for RFC 3161 HTTP transport)") unless curl
    return timestamp_failure("proof already exists: #{proof_path}") if File.exist?(proof_path)
    unless tsa_url.match?(%r{\Ahttps?://}i)
      return timestamp_failure("TSA URL must use http:// or https://")
    end

    ca_dir = OpenSSL::X509::DEFAULT_CERT_DIR
    ca_file = OpenSSL::X509::DEFAULT_CERT_FILE
    unless (ca_dir && File.directory?(ca_dir)) || (ca_file && File.file?(ca_file))
      return timestamp_failure("system CA certificates were not found; cannot verify the TSA response")
    end

    Dir.mktmpdir("packer-ts-") do |dir|
      request = File.join(dir, "request.tsq")
      response = File.join(dir, "response.tsr")
      _out, err, status = Open3.capture3(openssl, "ts", "-query", "-data", path,
                                         "-sha256", "-cert", "-out", request)
      return timestamp_failure("could not create RFC 3161 request: #{err.strip}") unless status.success?

      _out, err, status = Open3.capture3(curl, "--fail", "--silent", "--show-error",
                                        "--connect-timeout", "10", "--max-time", "45",
                                        "-H", "Content-Type: application/timestamp-query",
                                        "-H", "Accept: application/timestamp-reply",
                                        "--data-binary", "@#{request}", "--output", response,
                                        tsa_url)
      return timestamp_failure("TSA request failed: #{err.strip}") unless status.success? && File.size?(response)

      verify_args = [openssl, "ts", "-verify", "-data", path, "-in", response]
      verify_args += ca_dir && File.directory?(ca_dir) ? ["-CApath", ca_dir] : ["-CAfile", ca_file]
      _out, err, status = Open3.capture3(*verify_args)
      return timestamp_failure("TSA response did not verify: #{err.strip}") unless status.success?

      FileUtils.mv(response, proof_path)
    end

    puts "  RFC 3161 proof: #{proof_path} (verified against system trust store)"
    true
  rescue StandardError => e
    File.delete(proof_path) if File.exist?(proof_path)
    timestamp_failure(e.message)
  end

  def verify_timestamp(path)
    unless File.file?(path)
      warn "Error: archive not found: #{path}"
      return false
    end

    proofs = timestamp_proof_paths(path).select { |_, proof| File.file?(proof) }
    if proofs.empty?
      warn "Error: no adjacent timestamp proof found (expected #{timestamp_proof_paths(path).values.join(' or ')})"
      return false
    end

    ok = true
    proofs.each do |kind, proof|
      if kind == :ots
        ots = find_tool("ots")
        unless ots
          warn "Error: 'ots' is required to verify #{proof} (install opentimestamps-client)"
          ok = false
          next
        end
        output, error, status = Open3.capture3(ots, "verify", proof)
      else
        openssl = find_tool("openssl")
        unless openssl
          warn "Error: 'openssl' is required to verify #{proof}"
          ok = false
          next
        end
        ca_dir = OpenSSL::X509::DEFAULT_CERT_DIR
        ca_file = OpenSSL::X509::DEFAULT_CERT_FILE
        args = [openssl, "ts", "-verify", "-data", path, "-in", proof]
        args += ca_dir && File.directory?(ca_dir) ? ["-CApath", ca_dir] : ["-CAfile", ca_file]
        output, error, status = Open3.capture3(*args)
      end
      print output unless output.empty?
      warn error unless error.empty?
      pending = kind == :ots && output.match?(/pending confirmation/i)
      if pending
        puts "  OpenTimestamps proof: pending confirmation (not yet blockchain-verifiable)"
        ok &&= status.success?
      else
        puts "  #{kind == :ots ? 'OpenTimestamps' : 'RFC 3161'} proof: #{status.success? ? 'valid' : 'INVALID'}"
        ok &&= status.success?
      end
    end
    ok
  rescue StandardError => e
    warn "Error: timestamp verification failed: #{e.message}"
    false
  end
end

# frozen_string_literal: true

require "shellwords"
require "fileutils"
require "tmpdir"
require "open3"
require "openssl"
require "yaml"

module Packer
  module_function

  VERSION = "2.1.0"
end

require_relative "packer/catalog"
require_relative "packer/timestamps"
require_relative "packer/operations"
require_relative "packer/cli"

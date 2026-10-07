#!/usr/bin/env ruby
# frozen_string_literal: true

# Compatibility launcher for checkouts that used the original single-file CLI.
require_relative "lib/packer"

exit Packer.main(ARGV)

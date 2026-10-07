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
#
# Github: https://github.com/andrei-akopian/packer
# Compatibility launcher for checkouts that used the original single-file CLI.
require_relative "lib/packer"

exit Packer.main(ARGV)

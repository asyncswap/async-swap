#!/usr/bin/env ruby
require 'yaml'

file = ARGV[0]
path = ARGV[1]

exit 0 unless file && path

begin
  data = YAML.load_file(file)
rescue StandardError
  exit 0
end

value = path.split('.').reduce(data) do |memo, key|
  break nil unless memo.is_a?(Hash)
  memo[key]
end

case value
when nil
  exit 0
when TrueClass
  puts 'true'
when FalseClass
  puts 'false'
else
  puts value
end

#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'
require 'getoptlong'
require 'base64'
require 'httparty'
require 'json'
  
linode_host = 'https://api.linode.com'
linode_key = nil
bucket = nil
cluster = nil
config_file = '/etc/linode-os-cert.yml'
key_file = nil
crt_file = nil

opts = GetoptLong.new(
  [ '--api-key', '-K', GetoptLong::OPTIONAL_ARGUMENT ],
  [ '--bucket',  '-b', GetoptLong::REQUIRED_ARGUMENT ],
  [ '--cluster', '-r', GetoptLong::REQUIRED_ARGUMENT ],
  [ '--config',  '-C', GetoptLong::OPTIONAL_ARGUMENT ],
  [ '--key',     '-k', GetoptLong::OPTIONAL_ARGUMENT ],
  [ '--cert',    '-c', GetoptLong::OPTIONAL_ARGUMENT ]
)

opts.each do |o, arg|
  case o
  when '--api-key'
    linode_key = arg
  when '--bucket'
    bucket = arg
  when '--cluster'
    cluster = arg
  when '--config'
    config_file = arg
  when '--key'
    key_file = arg
  when '--cert'
    crt_file = arg
  end
end

# Check for Certbot hook env vars and use them to guess key_file and crt_file
if ENV.key?('RENEWED_LINEAGE')
  live_dir = ENV['RENEWED_LINEAGE']

  key_file  = "#{live_dir}/privkey.pem" if key_file.nil?
  crt_file = "#{live_dir}/fullchain.pem" if crt_file.nil?
end

if File.exists?(config_file)
  config = YAML.load(File.read(config_file))

  linode_key = config.dig('linode', 'api_key') if linode_key.nil?
  cluster = config.dig('linode', 'cluster') if cluster.nil?
end

fail "No private key specified" if key_file.nil?
fail "No certificate specified" if crt_file.nil?
fail "No API key specified" if linode_key.nil?
fail "No bucket specified" if bucket.nil?
fail "No cluster specified" if cluster.nil?

fail "The speficied private key, #{key_file}, does not exist" unless File.exists?(key_file)
fail "The specified certifictae, #{crt_file}, does not exist" unless File.exists?(crt_file)

api_resource = "#{linode_host}/v4/object-storage/buckets/#{cluster}/#{bucket}/ssl"
api_headers = { 'Authorization' => "Bearer #{linode_key}" }

# clear existing keys
resp_delete = HTTParty.delete(api_resource, headers: api_headers)

unless resp_delete.code == 200
  errors = JSON.parse(resp_delete.body)['errors']

  puts "DELETE #{api_resource} failed"
  errors.each do |err|
    puts "- #{err}"
  end

  fail "Unable to delete remote SSL config"
end

# upload new keys
resp_post = HTTParty.post(api_resource,
                          headers: api_headers.merge({
                            'Content-Type' => 'application/json'
                          }),
                          body: JSON.dump({
                            certificate: File.read(crt_file),
                            private_key: File.read(key_file)
                          }))

body_post = JSON.parse(resp_post.body)

case resp_post.code
when 200
  fail "SSL config submitted but API indicates that none is present" unless body_post['ssl']
else
  puts "POST #{api_resource} failed"
  body_post['errors'].each do |err|
    puts "- #{err['reason']}"
  end

  fail "Unable to install SSL config"
end

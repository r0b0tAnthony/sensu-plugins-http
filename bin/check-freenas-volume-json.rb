#!/usr/bin/env ruby
#
#   check-freenas-volume-json
#
# DESCRIPTION:
#   Takes either a URL or a combination of host/path/query/port/ssl, and checks
#   for valid JSON output in the response. Can also optionally validate simple
#   string key/value pairs.
#
# OUTPUT:
#   plain text
#
# PLATFORMS:
#   Linux
#
# DEPENDENCIES:
#   gem: sensu-plugin
#   gem: json
#
# USAGE:
#   #YELLOW
#
# NOTES:
#   Based on Check HTTP by Sonian Inc.
#
# LICENSE:
#   Copyright 2013 Matt Revell <nightowlmatt@gmail.com>
#   Released under the same terms as Sensu (the MIT license); see LICENSE
#   for details.
#

require 'sensu-plugin/check/cli'
require 'json'
require 'net/http'
require 'net/https'

#
# Check JSON
#
class CheckFreenasVolume < Sensu::Plugin::Check::CLI
  option :url,
    short: '-u URL'
  option :host,
    short: '-h HOST'
  option :path,
    short: '-p PATH'
  option :query,
    short: '-q QUERY'
  option :port,
    short: '-P PORT',
    proc: proc(&:to_i)
  option :method,
    short: '-m GET|POST'
  option :postbody,
    short: '-b /file/with/post/body'
  option :header,
    short: '-H HEADER',
    long: '--header HEADER'
  option :timeout,
    short: '-t SECS',
    proc: proc(&:to_i),
    default: 15
  option :whole_response,
    short: '-W',
    long: '--whole-response',
    boolean: true,
    default: false
  option :vol_name,
    short: '-v VOLUME',
    long: '--volume-name VOLUME'
  option :bwarn,
    short: '-w PERCENT',
    description: 'Warn if PERCENT or more of disk full',
    proc: proc(&:to_f),
    default: 85.0
  option :bcrit,
     short: '-c PERCENT',
     description: 'Critical if PERCENT or more of disk full',
     proc: proc(&:to_f),
     default: 95.0
  option :user,
    short: '-U',
    long: '--username USER'
  option :password,
    short: '-a',
    long: '--password PASS'

  def initialize
    super
    @crit_fs = []
    @warn_fs = []
  end

  def usage_summary
    (@crit_fs + @warn_fs).join(', ')
  end

  def run
    if config[:url]
      uri = URI.parse(config[:url])
      config[:host] = uri.host
      config[:path] = uri.path
      config[:query] = uri.query
      config[:port] = uri.port
      config[:ssl] = uri.scheme == 'https'
    else
      # #YELLOW
      unless config[:host] && config[:path]
        unknown 'No URL specified'
      end
      config[:port] ||= config[:ssl] ? 443 : 80
    end

    begin
      Timeout.timeout(config[:timeout]) do
        acquire_resource
      end
    rescue Timeout::Error
      critical 'Connection timed out'
    rescue => e
      critical "Connection error: #{e.message}"
    end

    critical usage_summary unless @crit_fs.empty?
    warning usage_summary unless @warn_fs.empty?
    ok "Volume #{config[:vol_name]} status is HEALTHY and disk usage is under #{config[:bwarn]}"
  end

  def get_volume(data, volume_name)
    data.each do | volume |
      if volume['vol_name'] == volume_name
        return volume
      end
    end
    raise "Could not find #{volume_name}"
  end

  def json_valid?(str)
    begin
      JSON.parse(str)
      return true
    rescue JSON::ParserError
      return false
    end
  end

  def acquire_resource
    http = Net::HTTP.new(config[:host], config[:port])

    req = if config[:method] == 'POST'
            Net::HTTP::Post.new([config[:path], config[:query]].compact.join('?'))
          else
            Net::HTTP::Get.new([config[:path], config[:query]].compact.join('?'))
          end
    if config[:postbody]
      post_body = IO.readlines(config[:postbody])
      req.body = post_body.join
    end

    unless config[:user].nil? && config[:password].nil?
      req.basic_auth config[:user], config[:password]
    end

    if config[:header]
      config[:header].split(',').each do |header|
        h, v = header.split(':', 2)
        req[h] = v.strip
      end
    end
    res = http.request(req)

    unless res.code =~ /^2/
      critical "http code: #{res.code}: body: #{res.body}" if config[:whole_response]
      critical res.code
    end
    critical 'invalid JSON from request' unless json_valid?(res.body)

    json = JSON.parse(res.body)

    volume = get_volume(json, config[:vol_name])

    if volume['status'] != 'HEALTHY'
      @crit_fs << "#{volume['vol_name']} status is #{volume['status']}"
    end
    used_pct = volume['used_pct'].chomp('%').to_f
    
    if used_pct >= config[:bcrit]
      @crit_fs << "#{volume['vol_name']} usage is #{volume['used_pct']}"
    elsif used_pct >= config[:bwarn]
      @warn_fs << "#{volume['vol_name']} usage is #{volume['used_pct']}"
    end
  end
end

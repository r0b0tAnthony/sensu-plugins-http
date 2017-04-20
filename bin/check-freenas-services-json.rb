#!/usr/bin/env ruby
#
#   check-freenas-services-json
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
class CheckFreenasServices< Sensu::Plugin::Check::CLI
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
  option :warnings,
    short: '-w',
    long: '--include-warnings',
    boolean: true,
    default: true
  option :criticals,
    short: '-c',
    long: '--include-criticals',
    boolean: true,
    default: true
  option :oks,
    short: '-o',
    long: '--include-oks',
    boolean: true,
    default: false
  option :user,
    short: '-U',
    long: '--username USER'
  option :password,
    short: '-a',
    long: '--password PASS'

  def initialize
    super
    @criticals  = 0
    @warnings   = 0
    @oks        = 0
  end

  def usage_summary
    "Critical: #{@criticals}, Warnings: #{@warnings}, OKs: #{@oks}"
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

    critical usage_summary unless @critical_services.empty?
    ok "#{config[:service].join(', ')} services are enabled"
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

    services = JSON.parse(res.body)
    found_services = []
    services.each do | service |
      if config[:service].include?(service['srv_service'])
        found_services << service['srv_service']
        if service['srv_enable'] != true
          @critical_services << "#{service['srv_service']} is not enabled"
        end
      end
    end

    (found_services - config[:service]).each do | service |
      @critical_services << "#{service} not found"
    end
  end
end

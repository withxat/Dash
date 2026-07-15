#!/usr/bin/env ruby

require "fileutils"
require "json"
require "net/http"
require "optparse"
require "uri"

options = {
  output: File.expand_path(
    "../../../packages/cloudflare-api/Sources/CloudflareAPI/Resources",
    __dir__
  )
}

OptionParser.new do |parser|
  parser.banner = "Usage: generate-cloudflare-scopes.rb [options]"
  parser.on("--scopes-file PATH", "Use a saved GET /oauth/scopes response") do |path|
    options[:scopes_file] = path
  end
  parser.on("--output PATH", "Write the generated scope catalog to PATH") do |path|
    options[:output] = path
  end
end.parse!

def fetch(uri, authorization:)
  request = Net::HTTP::Get.new(uri)
  request["Authorization"] = "Bearer #{authorization}"
  response = Net::HTTP.start(
    uri.hostname,
    uri.port,
    use_ssl: uri.scheme == "https"
  ) { |http| http.request(request) }
  abort("Scope catalog fetch failed with HTTP #{response.code}") unless response.is_a?(Net::HTTPSuccess)
  response.body
end

scope_payload =
  if options[:scopes_file]
    File.read(options[:scopes_file])
  else
    token = ENV["CLOUDFLARE_API_TOKEN"]
    abort("Set CLOUDFLARE_API_TOKEN or pass --scopes-file") if token.nil? || token.empty?
    fetch(
      URI("https://api.cloudflare.com/client/v4/oauth/scopes"),
      authorization: token
    )
  end

scope_response = JSON.parse(scope_payload)
abort("Cloudflare returned an unsuccessful scope response") unless scope_response["result"].is_a?(Array)

scopes =
  scope_response["result"].map do |scope|
    {
      "id" => scope.fetch("id"),
      "name" => scope.fetch("name"),
      "category" => scope["category"] || "other"
    }
  end.sort_by { |scope| [scope["category"], scope["name"], scope["id"]] }

FileUtils.mkdir_p(options[:output])
File.write(
  File.join(options[:output], "OAuthScopeCatalog.json"),
  JSON.pretty_generate(
    {
      "generatedAt" => Time.now.utc.strftime("%Y-%m-%d"),
      "scopes" => scopes
    }
  ) + "\n"
)

puts("Generated #{scopes.length} OAuth scopes.")

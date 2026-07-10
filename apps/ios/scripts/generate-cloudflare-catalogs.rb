#!/usr/bin/env ruby

require "fileutils"
require "json"
require "net/http"
require "optparse"
require "uri"
require "yaml"

options = {
  output: File.expand_path(
    "../../../packages/cloudflare-api/Sources/CloudflareAPI/Resources",
    __dir__
  )
}

OptionParser.new do |parser|
  parser.banner = "Usage: generate-cloudflare-catalogs.rb [options]"
  parser.on("--scopes-file PATH", "Use a saved GET /oauth/scopes response") do |path|
    options[:scopes_file] = path
  end
  parser.on("--openapi-file PATH", "Use a saved Cloudflare OpenAPI YAML document") do |path|
    options[:openapi_file] = path
  end
  parser.on("--output PATH", "Write generated catalogs to PATH") do |path|
    options[:output] = path
  end
end.parse!

def fetch(uri, authorization: nil)
  request = Net::HTTP::Get.new(uri)
  request["Authorization"] = "Bearer #{authorization}" if authorization
  response = Net::HTTP.start(
    uri.hostname,
    uri.port,
    use_ssl: uri.scheme == "https"
  ) { |http| http.request(request) }
  abort("Catalog fetch failed with HTTP #{response.code}") unless response.is_a?(Net::HTTPSuccess)
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

openapi_payload =
  if options[:openapi_file]
    File.read(options[:openapi_file])
  else
    fetch(
      URI(
        "https://raw.githubusercontent.com/cloudflare/api-schemas/main/openapi.yaml"
      )
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

document = YAML.safe_load(openapi_payload, permitted_classes: [Time], aliases: true)
methods = %w[get post put patch delete options head]
endpoints = []

document.fetch("paths", {}).each do |path, path_item|
  next unless path_item.is_a?(Hash)

  path_item.each do |method, operation|
    next unless methods.include?(method.to_s.downcase)
    next unless operation.is_a?(Hash)

    endpoints << {
      "id" => operation["operationId"] || "#{method}-#{path}",
      "method" => method.to_s.upcase,
      "path" => path,
      "summary" => operation["summary"] || operation["description"]&.lines&.first&.strip || path,
      "tags" => Array(operation["tags"]).map(&:to_s).sort,
      "hasRequestBody" => operation.key?("requestBody"),
      "pathParameters" => path.scan(/\{([^}]+)\}/).flatten
    }
  end
end
endpoints.sort_by! { |endpoint| [endpoint["tags"].first.to_s, endpoint["path"], endpoint["method"]] }

scope_suffixes = %w[
  read write admin edit run index evaluate send setup revoke metadata_read monitoring
]
coverage =
  scopes.map do |scope|
    stem = scope["id"].sub(/\.(#{scope_suffixes.join("|")})\z/, "")
    normalized_stem = stem.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
    tokens =
      normalized_stem.split("-").reject do |token|
        token.length < 2 || %w[account zone domain workers cloudflare].include?(token)
      end
    matches =
      endpoints.select do |endpoint|
        haystack =
          ([endpoint["id"], endpoint["path"]] + endpoint["tags"])
            .join(" ")
            .downcase
            .gsub(/[^a-z0-9]+/, "-")
        haystack.include?(normalized_stem) ||
          (!tokens.empty? && tokens.all? { |token| haystack.include?(token) })
      end
    {
      "scopeID" => scope["id"],
      "disposition" => matches.empty? ? "noPublicEndpoint" : "implemented",
      "reason" => matches.empty? ? "No matching operation in the current OpenAPI snapshot." : nil,
      "endpointCount" => matches.length,
      "endpointIDs" => matches.first(25).map { |endpoint| endpoint["id"] }
    }
  end

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
File.write(
  File.join(options[:output], "CloudflareEndpointCatalog.json"),
  JSON.pretty_generate(
    {
      "generatedAt" => Time.now.utc.strftime("%Y-%m-%d"),
      "source" => document.dig("info", "version"),
      "endpoints" => endpoints
    }
  ) + "\n"
)
File.write(
  File.join(options[:output], "OAuthScopeCoverage.json"),
  JSON.pretty_generate(
    {
      "generatedAt" => Time.now.utc.strftime("%Y-%m-%d"),
      "entries" => coverage
    }
  ) + "\n"
)

implemented = coverage.count { |entry| entry["disposition"] == "implemented" }
puts(
  "Generated #{scopes.length} OAuth scopes, #{endpoints.length} API endpoints, " \
  "and #{implemented} scope-to-endpoint mappings."
)

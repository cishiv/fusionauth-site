#!/usr/bin/env ruby

require 'json'
require 'net/http'
require 'uri'
require 'optparse'
require 'yaml'


# TODO
# support checking example JSON
# support warning for fields that exist in html but not in the json and vice versa


IGNORED_FIELD_REGEXPS = [
  /^(?!event).*\.tenantId/, # toplevel tenantId always ignored, except when checking events, as that is handled implicitly via API key locking or header if there is more than one tenant
  /^user\.salt/, # never send user.salt, only used by Import API
  /^user\.twoFactor\.recoveryCodes/, # only used by Import API
  /^application\.cleanSpeakConfiguration\.apiKey/, # this is not valid at the application level, only the integration level
  /^application\.cleanSpeakConfiguration\.url/, # this is not valid at the application level, only the integration level
  /^application\.jwtConfiguration\.refreshTokenRevocationPolicy\.onLoginPrevented/, # no UX elements for this
  /^application\.jwtConfiguration\.refreshTokenRevocationPolicy\.onPasswordChanged/, # no UX elements for this
  /^tenant\.jwtConfiguration\.enabled/, # jwts always configured on tenant
  /^user\.uniqueUsername/, # this is a derived, internal field
  /^entity\.parentId/, # not currently documenting until this is further built out
  /^theme\.templates\.emailSend/, # this is a derived, internal field
  /^theme\.templates\.registrationSend/, # deprecated, replaced with templates.registrationSent
  /^event\.info\.location\.displayString/, # this is a derived field
  /^event\.ipAddress/, # this is a deprecated field
]
# option handling
options = {}

# default options
options[:siteurl] = "https://fusionauth.io"
options[:clientlibdir] = "../../fusionauth-client-builder"

OptionParser.new do |opts|
  opts.banner = "Usage: check-apis-against-client-json.rb [options]"

  opts.on("-s", "--site SITEURL", "Provide an alternate site, like https://site-local.fusionauth.io, to run the check against. Default is https://fusionauth.io.") do |siteurl|
    options[:siteurl] = siteurl
  end

  opts.on("-p", "--file-prefix FILEPREFIX", "Provide a file prefix to run for, like 'AuditLog'. This runs the check for only one file, 'AuditLog.json' in the example. Exclusive with -f. Default is to check a standard set of files.") do |fileprefix|
    options[:fileprefix] = fileprefix
  end

  opts.on("-c", "--clientlibdir CLIENT_LIB_DIR", "Provide an alternate client library directory to run the check against. Default is ../../fusionauth-client-builder (peer to this fusionauth-site checkout).") do |clientlibdir|
    options[:clientlibdir] = clientlibdir
  end

  opts.on("-f", "--config-file CONFIG_FILE", "Provide a YAML config file to load. Right now config file can contain a list of files to check under the key 'files'. Each file name will be globbed and appended with '.json'. Exclusive with -p.") do |configfile|
    options[:configfile] = configfile
  end

# add in config file
# run in gh workflow

  opts.on("-v", "--verbose", "Run verbosely.") do |v|
    options[:verbose] = v
  end

  opts.on("-h", "--help", "Prints this help.") do
    puts opts
    exit(false)
  end
end.parse!

def is_event(type)
  return (type.end_with?("-event") or type.end_with?("Event"))
end

# some events don't have tenant Id
def handle_event_field_exceptions(ignore, type, full_field_name)
  unless is_event(type)
    return ignore # don't process anything that isn't an event
  end
  events_without_tenant_ids = ["auditLogCreateEvent", "eventLogCreateEvent"]
  if full_field_name == "event.tenantId" && events_without_tenant_ids.include?(type)
    return true # can safely ignore
  end

  return ignore
end

# what our dashed type is -> what the path is in the url
# no hash at end of url as of feb 2022
def make_api_path(type)
  base = "apis/"

  if is_event(type)
    base = "events-webhooks/events/"
    # convert audit-log-create-event to audit-log-create
    type = type.gsub("-event","")
    if type == "user-action"
      type = "user-actions"
    end
    if type == "user-login-id-duplicate-on-create"
      type = "user-login-id-duplicate-create"
    end
    if type == "user-login-id-duplicate-on-update"
      type = "user-login-id-duplicate-update"
    end
    return base + type
  end

  if type == "identity-provider-link"
    return base + "identity-providers/links"
  end

  if type == "generic-connector-configuration"
    return base + "connectors/generic"
  end

  if type == "family"
    return base + "families"
  end
  if type == "entity"
    return base + "entity-management/entities"
  end
  if type == "entity-type"
    return base + "entity-management/entity-types"
  end
  if type == "entity-grant"
    return base + "entity-management/grants"
  end
  if type == "ldap-connector-configuration"
    return base + "connectors/ldap"
  end
  if type == "email-template"
    return base + "emails"
  end
  return base + type + "s"
end

# what our type is -> what the variable is on the doc page
def make_on_page_field_name(type)
  if type == "formField"
    return "field"
  end
  if type == "genericConnectorConfiguration"
    return "connector"
  end
  if type == "entityGrant"
    return "grant"
  end
  if type == "ldapConnectorConfiguration"
    return "connector"
  end

  if is_event(type)
    return "event"
  end

  return type
end

def todash(camel_cased_word)
  camel_cased_word.to_s.gsub(/::/, '/').
  gsub(/([A-Z]+)([A-Z][a-z])/,'\1-\2').
  gsub(/([a-z\d])([A-Z])/,'\1-\2').
  downcase
end

def open_url(url)
  res = Net::HTTP.get_response(URI.parse(url))
  if res.code != "200"
    return nil
  end

  return res.body
end

def downcase(string) 
  # downcase all upper case until we see a lowercase, JWT, APIKey special cased
  dcs = "";
  if string[0..2] == "JWT"
    dcs = "jwt"+string[3..-1]
  elsif string[0..3] == "APIK"
    dcs = "apiK"+string[4..-1]
  elsif string[0..4] == "LDAPC"
    dcs = "ldapC"+string[5..-1]
  else 
    first_lc = string.index(/[a-z]/)
    if first_lc
      dcs = string[0..first_lc-1].downcase + string[first_lc..-1]
    else 
      dcs = string
    end
  end
  dcs
end


def process_file(fn, missing_fields, options, prefix = "", type = nil, page_content = nil)

  # these are leafs of the tree and aren't fields with possible subfields.
  known_types = ["ZoneId", "LocalDate", "char", "HTTPHeaders", "LocalizedStrings", "int", "URI", "Object", "String", "Map", "long", "ZonedDateTime", "List", "boolean", "UUID", "Set", "LocalizedIntegers", "double", "EventType", "SortedSet" ]

  # these are attributes that point to more complex objects at the leaf node, but aren't documented in the page. Instead, we point to the complex object doc page
  nested_attributes = ["grant.entity", "entity.type", "event.auditLog", "event.eventLog", "event.user", "event.email", "event.existing", "event.registration", "event.original", "event.method", "event.identityProviderLink", "event.group", "event.refreshToken"]

  # these are enums represented as strings in the API, but enums in java. We should still see them on the page
  enums = ["lambda.type", "lambda.engineType"]

  if options[:verbose]
    puts "opening: "+fn
  end

  f = File.open(fn)
  fs = f.read
  json = JSON.parse(fs)
  f.close
  
  if type 
    # type is passed in. sometimes the field name is not the same as the type applicationEmailConfiguration being an example, it is actually emailConfiguration 
    t = type
  else
    t = json["type"]
    t = downcase(t)
  end

  if prefix != "" 
    # add previous objects if present
    t = prefix+"."+t
  end

  if options[:verbose]
    puts "processing " + t
  end
  unless page_content
    # we are in leaf object, we don't need to pull the page content
    api_url = options[:siteurl] + "/docs/v1/tech/"+make_api_path(todash(t))
    if options[:verbose]
      puts "retrieving " + api_url
    end

    page_content = open_url(api_url)
    unless page_content
      puts "Could not retrieve: " + api_url

      exit(false)
    end
  end
  
  fields = json["fields"]
  extends = json["extends"]

  # if we extend a class, we need to add those fields to our existing fields
  extends && extends.length > 0 && extends.each do |ex|
    unless fields && fields.length > 0
      fields = {}
    end
    files = Dir.glob(options[:clientlibdir]+"/src/main/domain/io.fusionauth.domain.*"+ex["type"]+".json")
    file = files[0]
    ef = File.open(file)
    efs = ef.read
    ejson = JSON.parse(efs)
    ef.close
    fields = fields.merge(ejson["fields"])
    #puts fields
  end
  
  fields && fields.length > 0 && fields.each do |fi| 
    field_type = fi[1]["type"]
    field_name = fi[0].to_s
    
    full_field_name = make_on_page_field_name(t)+ "." + field_name

    if known_types.include? field_type
      # we are at a leaf. We should see if we have any fields missing
      if ! page_content.include? full_field_name 
        ignore = false
        # fields in this regexp ok to omit
        IGNORED_FIELD_REGEXPS.each do |re|
          ignore = re.match(full_field_name)
          if ignore
            break
          end
        end
        ignore = handle_event_field_exceptions(ignore, t,full_field_name)
        unless ignore
          missing_fields.append({original_examined_type: t, full_field_name: full_field_name, type: field_type})
        end
      end
    elsif enums.include? full_field_name or nested_attributes.include? full_field_name
      if options[:verbose]
        puts "not traversing #{full_field_name}, but checking if it is in the content of #{api_url}"
      end
      if ! page_content.include? full_field_name 
        missing_fields.append({full_field_name: full_field_name, type: field_type})
      end
      if full_field_name == "entity.type"
        # special case for entity.type.id
        if ! page_content.include? full_field_name + ".id"
          missing_fields.append({full_field_name: full_field_name + ".id"})
        end
      end
    else
      #p "need to look up other object for type " + field_type
      files = Dir.glob(options[:clientlibdir]+"/src/main/domain/io.fusionauth.domain.*"+field_type+".json")
      if options[:verbose] && files.length > 1
        puts "for field_type: "+ field_type+ ", found " + files.length.to_s + " files, picking closest one"
        puts files
      end
      if files.length == 1
        file = files[0]
      else
        ancestor_type = t.gsub(/^\..*/,'')
        if options[:verbose]
          puts "looking for matching inner class"
        end
        files.each do |mf|
          if mf.upcase.include?(ancestor_type.upcase)
            # inner class, use this one
            file = mf
            break
          end
        end
        unless file
          if options[:verbose]
            puts "no inner class found, looking for all other classes, but avoiding other inner classes"
          end
          # grab the one without the $ in name, no other inner classes should work
          files.each do |mf|
            unless mf.include?('$')
              file = mf
              break
            end
          end
        end
      end
      if file
        process_file(file, missing_fields, options, make_on_page_field_name(t), field_name, page_content)
      else
        puts "couldn't find file for "+field_type
      end
    end
  end
end

if options[:fileprefix]
  files = Dir.glob(options[:clientlibdir]+"/src/main/domain/*"+options[:fileprefix]+".json")
elsif options[:configfile]
  config = YAML.load(File.read(options[:configfile])) 
  files = []
  filenames = config["files"]
  filenames.each do |f|
    matching_files = Dir.glob(options[:clientlibdir]+"/src/main/domain/*"+f+".json")
    matching_files.each do |mf| 
      files.append(mf)
    end
  end
else
  # default files to check
  files = [
    options[:clientlibdir]+"/src/main/domain/io.fusionauth.domain.Group.json",
    options[:clientlibdir]+"/src/main/domain/io.fusionauth.domain.AuditLog.json",
    options[:clientlibdir]+"/src/main/domain/io.fusionauth.domain.UserAction.json",
    options[:clientlibdir]+"/src/main/domain/io.fusionauth.domain.Theme.json",
    options[:clientlibdir]+"/src/main/domain/io.fusionauth.domain.Key.json",
    options[:clientlibdir]+"/src/main/domain/io.fusionauth.domain.APIKey.json",
    options[:clientlibdir]+"/src/main/domain/io.fusionauth.domain.Webhook.json",
    options[:clientlibdir]+"/src/main/domain/io.fusionauth.domain.Lambda.json",
    options[:clientlibdir]+"/src/main/domain/io.fusionauth.domain.Application.json",
    options[:clientlibdir]+"/src/main/domain/io.fusionauth.domain.Tenant.json",
    options[:clientlibdir]+"/src/main/domain/io.fusionauth.domain.User.json",
  ]
end

if options[:verbose] 
  puts "Checking files: "
  puts files
end

missing_fields = []

files.each do |fn|
  process_file(fn, missing_fields, options)
end


if missing_fields.length > 0 
  if options[:verbose]
    puts "\n\n"
  end
  puts "MISSING FIELDS"
  puts missing_fields
  exit(false)
else
  exit(true)
end

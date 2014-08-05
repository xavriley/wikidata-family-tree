require 'json'
require 'rest_client'
require 'sinatra'
require 'rack/cache'
require 'dalli'

if memcache_servers = ENV["MEMCACHE_SERVERS"]
  use Rack::Cache,
    verbose: true,
    metastore:   "memcached://#{memcache_servers}",
    entitystore: "memcached://#{memcache_servers}"
end
use Rack::Deflater
set :static_cache_control, [:public, max_age: 60 * 60 * 24 * 365]

before do
  @max_nodes = 150
  @use_wiki_mobile = true
  @nodes = {}
  @edges = []
end

def extract_relations(person)
  output = {}
  output[:ids] = []
  output[:rels] = []

  person[:claims].each do |property, val|
    val.each do |v|
      next unless v["mainsnak"]["datavalue"]
      prop_id = property.gsub(/\D+/, '').to_i

      case prop_id
      when 26 # spouse of
        q2 = v["mainsnak"]["datavalue"]["value"]["numeric-id"].to_s
        output[:ids] << q2
        rel = {id: v["id"], source: person[:item_id], target: q2} 
        if person[:gender]
          rel.merge!(label: "#{person[:gender] == 'M' ? 'Husband' : 'Wife'} of")
        else
          rel.merge!(label: "Spouse of")
        end
        output[:rels] << rel

        # Double bonding spouse rels to give graph better weight
        rel = {id: "REV-#{v["id"]}", source: q2, target: person[:item_id]} 
        if person[:gender]
          rel.merge!(label: "#{person[:gender] == 'M' ? 'Wife' : 'Husband'} of")
        else
          rel.merge!(label: "Spouse of")
        end
        output[:rels] << rel
      when 40 # child of
        q2 = v["mainsnak"]["datavalue"]["value"]["numeric-id"].to_s
        output[:ids] << q2
        rel = {id: v["id"], source: person[:item_id], target: q2} 
        if person[:gender]
          rel.merge!(label: "#{person[:gender] == 'M' ? 'Father' : 'Mother'} of")
        else
          rel.merge!(label: "Parent of")
        end
        output[:rels] << rel
      when 22 # father of
        q2 = v["mainsnak"]["datavalue"]["value"]["numeric-id"].to_s
        output[:ids] << q2
        output[:rels] << {id: v["id"], source: q2, target: person[:item_id], label: "Father of"} 
      when 25 # mother of
        q2 = v["mainsnak"]["datavalue"]["value"]["numeric-id"].to_s
        output[:ids] << q2
        output[:rels] << {id: v["id"], source: q2, target: person[:item_id], label: "Mother of"} 
      end
    end
  end

  # Perform any cleanup here
  output[:rels].each {|x| x.merge!(type: 'arrow') }

  output
end

def parse_person(e)
  raw = e.values.first
  item_id = e.keys.first.gsub(/\D+/, '').to_s
  name = (raw["labels"] ? raw["labels"].values.map {|x| x["value"] }.first : item_id)
  descriptions = raw["descriptions"].values.map {|x| x["value"] }.first if raw["descriptions"]
  claims = raw["claims"]
  numeric_id = raw["lastrevid"]
  # Bit of a song and dance routine to get links to Wikipedia pages
  if raw["sitelinks"]
    if raw["sitelinks"]["enwiki"] # Prefer english wikipedia
      wikipedia_url = "https://en.#{ @use_wiki_mobile ? 'm.' : '' }wikipedia.org/wiki/#{URI.encode(raw["sitelinks"]["enwiki"]["title"].gsub(" ", "_"))}"
    else
      site, data = *raw["sitelinks"].first
      wikipedia_url = "https://#{site.gsub('wiki', '')}.#{ @use_wiki_mobile ? 'm.' : '' }wikipedia.org/wiki/#{URI.encode(data["title"].gsub(" ", "_"))}"
    end
  end
  wikidata_url = "https://tools.wmflabs.org/reasonator/?q=Q#{item_id}"

  output = {item_id: item_id, name: name, descriptions: descriptions, claims: claims, wikipedia_url: wikipedia_url, wikidata_url: wikidata_url}

  claims.each do |property, v|
    v = v.first
    next unless v["mainsnak"]["datavalue"]
    prop_id = property.gsub(/\D+/, '').to_i

    case prop_id
    when 21 # Sex
      q2 = v["mainsnak"]["datavalue"]["value"]["numeric-id"]
      if( q2 == 44148 || q2 == 6581097 ) 
        output.merge!(gender: 'M')
      elsif ( q2 == 43445 || q2 == 6581072 ) 
        output.merge!(gender: 'F')
      end
    end
  end

  output
end

def get_person(q_num)
  response = RestClient.get("http://www.wikidata.org/w/api.php?action=wbgetentities&ids=Q#{q_num}&languages=en&format=json").to_str
  JSON.parse(response)["entities"]
end

def node_colour_for_person(person)
  if person[:gender] == 'M'
    "rgb(125,125,255)"
  elsif person[:gender] == 'F'
    "rgb(255,125,125)"
  else
    "rgb(125,125,125)"
  end
end

def transform_wikidata_to_sigma_node(person)
  {
    id: person[:item_id].to_s,
    label: person[:name],
    size: 1,
    color: node_colour_for_person(person),
    x: (rand * 10).to_i,
    y: (rand * 10).to_i,
    wiki_url: "#{person[:wikipedia_url] || person[:wikidata_url]}"
  }
end

def lucky_search_for_term(term)
  response = RestClient.get("https://www.wikidata.org/w/api.php?action=wbsearchentities&search=#{term}&format=json&language=en&type=item&continue=0").to_str
  JSON.parse(response)["search"].first["id"].gsub(/\D+/, '')
rescue
  nil
end

get '/json/:id' do
  start = get_person(params[:id])
  start_person = parse_person(start)

  @nodes.merge!(start_person[:item_id] => start_person)
  start_rels = extract_relations(start_person)

  @edges += start_rels[:rels]
  start_rels[:ids].each {|id|
    @nodes[id] ||= nil
  }

  while(@nodes.length < @max_nodes && @nodes.any? {|k,v| v.nil? } ) do
    STDERR.puts "#{@nodes.length} people found"
    @nodes.select {|k,v| v.nil? }.each do |empty_person|
      id = empty_person.first # returns array of [1234, nil]
      p = get_person(id)
      p = parse_person(p)
      STDERR.puts "Fetched #{p[:name]}"

      @nodes.merge!(p[:item_id] => p)
      rels = extract_relations(p)

      @edges += rels[:rels]
      rels[:ids].each {|id|
        @nodes[id] ||= nil
      }
    end
  end

  edge_count_by_id = @edges.group_by {|x| x[:target] }.map {|k,v| {k => v.length } }.inject({}) {|v, acc| acc.merge v }
  sigma_nodes = @nodes.values.compact.map {|x| 
      transform_wikidata_to_sigma_node(x) 
    }.map {|x|
      x.merge!(size: edge_count_by_id.fetch(x[:id], 1))
    }

  sigma_edges = @edges.delete_if {|s| @nodes[s[:source]].nil? || @nodes[s[:target]].nil? }.uniq

  json_out = JSON.dump({
    nodes: sigma_nodes,
    edges: sigma_edges
  })
  
  cache_control :public, max_age: (1 * 86400) # one week
  content_type :json

  json_out
end

get '/about' do
  erb :about
end

get '/credits' do
  erb :credits
end

post '/search' do
  case params[:id].to_s
  when /\d+/
    @id = params[:id]
  when /^Q\d+/
    @id = params[:id].gsub(/\D+/, '')
  else
    @id = lucky_search_for_term(params[:id])
  end
  
  redirect "/family-tree/#{@id}" if @id
  @message = "Sorry, we couldn't find an entry for #{params[:id]}"
  erb :index
end

get '/family-tree/:id' do
  case params[:id].to_s
  when /\d+/
    @id = params[:id]
  when /^Q\d+/
    @id = params[:id].gsub(/\D+/, '')
  else
    @id = lucky_search_for_term(params[:id])
  end
  erb :index
end

get '/' do
  @id = 1339
  erb :index
end

# Deploy to Heroku

# Add a loading spinner with 30s timeout saying try again soon
# Why does Kezia Obama (Q15982183) not have a child of Auma Obama (Q773197)?
# Why does Elisabeth Bach not show? Q15735857
# Colour Gender and deity
# Background the fetching somehow?
# Look at custom edge render
# Show reasonator on double click
# allow cache invalidation and limit to be set by params
# Set x value to be proportional to Date of Birth
# Set y value to be proportional to Name alphabetical

require 'cadet'
require 'yaml'
require 'json'

db = Cadet::BatchInserter::Session.open("neo4j-community-2.0.1/data/graph.db",{
  "use_memory_mapped_buffers"                       => "true",
  "neostore.nodestore.db.mapped_memory"             => "2G",
  "neostore.relationshipstore.db.mapped_memory"     => "3G",
  "neostore.propertystore.db.mapped_memory"         => "2G",
  "neostore.propertystore.db.strings.mapped_memory" => "2G",
  "cache_type" => "none"
})

db.constraint :Legislator, :name
db.constraint :Legislator, :thomas_id
db.constraint :Bill,       :id
db.constraint :Gender,     :name
db.constraint :Religion,   :name
db.constraint :Party,      :name
db.constraint :State,      :name
db.constraint :Role,       :name
db.constraint :District,   :district
db.constraint :Subject,    :name
db.constraint :Committee,  :thomas_id

puts "loading committees"
YAML.load_file('data/congress-legislators/committee-membership-current.yaml').each do |committee_data|
  c = db.get_node :Committee, :thomas_id,  committee_data[0].to_s

  committee_members = c.outgoing(:member)
  committee_data[1].each do |leg|
    l = db.get_node(:Legislator, :thomas_id, leg["thomas"].to_i)
    committee_members << l
  end
end

puts "loading legislators"
YAML.load_file('data/congress-legislators/legislators-current.yaml').each do |leg|
    l = db.get_node :Legislator, :thomas_id,  leg["id"]["thomas"].to_i

    l[:gender] = leg["bio"]["gender"] if leg["bio"]["gender"]
    l.outgoing(:religion) << db.get_node(:Religion, :name, leg["bio"]["religion"]) if leg["bio"]["religion"]

    leg["terms"].each do |term|
      t = db.create_node_with(:Term, {:start => term["start"].gsub(/-/, '').to_i, :end => term["end"].gsub(/-/, '').to_i})

      t.outgoing(:party)      << db.get_node(:Party, :name, term["party"])
      t.outgoing(:represents) << db.get_node(:State, :name, term["state"])
      t.outgoing(:role)       << db.get_node(:Role,  :name, term["type"])

      l.outgoing(:term) << t
    end
end

puts "loading bills"
file_queue = Queue.new
data_queue = SizedQueue.new(16)
Thread.abort_on_exception = true

1.upto(8).map do
  Thread.new do
    while json_file = file_queue.pop rescue nil
      data_queue << JSON.parse(File.read(json_file))
    end
  end
end

Dir['data/congress-data/*/bills/*/*/*.json'].each { |f| file_queue.push f }

until file_queue.empty? && data_queue.empty?
  bill_data = data_queue.pop

  begin
    bill = db.create_node_with(:Bill, {
      id:             bill_data["bill_id"],
      official_title: bill_data["official_title"].to_s,
      summary:        (bill_data["summary"] && bill_data["summary"]["text"].to_s) || ""
     }, :id)

    bill.outgoing(:congress) << db.get_node(:Congress, :number,       bill_data["congress"].to_i)

    if sponsor = bill_data["sponsor"]
      bill.outgoing(:sponsor) <<  db.get_node(:Legislator, :thomas_id,  sponsor["thomas_id"].to_i)
    end

    cosponsors = bill.outgoing(:cosponsor)
    bill_data["cosponsors"].each do |cosponsor|
       cosponsors << db.get_node(:Legislator, :thomas_id, cosponsor["thomas_id"].to_i)
    end

    subjects = bill.outgoing(:subject)
    bill_data["subjects"].each do |subject|
      subjects << db.get_node(:Subject, :name, subject)
    end
  rescue Exception => e
    puts bill_data
  end
end

db.close

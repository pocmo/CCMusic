#!/usr/bin/ruby

require 'rubygems'
require 'parseconfig'
require 'mongo'
require 'rfeedparser'
require 'digest/sha1'
require 'term/ansicolor'
require 'id3lib'
require 'ftools'
require 'iconv'
require 'optparse'

class String
  include Term::ANSIColor
end

puts "CCMusic 0.1".yellow
puts "Copyright (C) 2010 Sebastian Kaspari".yellow
puts

config = ParseConfig.new './ccmusic.conf'

host     = config.get_value('mongodb')['host'];
port     = config.get_value('mongodb')['port'];
database = config.get_value('mongodb')['database'];

temp_file       = config.get_value('filesystem')["temp_file"]
download_folder = config.get_value('filesystem')["download_folder"]

db    = Mongo::Connection.new(host, port).db(database);
feeds = db.collection("feeds")
files = db.collection("files")

# Default options
options = {
  :ignore_broken => false
}

optparse = OptionParser.new do |opts|
  opts.banner = "Usage: ccmusic.rb [options]"

  opts.on("-a", "--add-feed FEED", "Add feed to database") do |feed|
    feeds.insert({"url" => feed})
    puts "Added feed #{feed}"
    exit
  end

  opts.on("-r", "--remove-feed FEED", "Remove feed from database") do |feed|
    feeds.remove({"url" => feed})
    puts "Removed feed #{feed}"
    exit
  end

  opts.on("-l", "--list-feeds", "List existing feeds") do
    feeds.find().each { |feed|
      print feed["_id"].to_s.green
      puts " #{feed["url"]}"
    }
    exit
  end

  opts.on("-i", "--ignore ID", "Ignore this download id") do |id|
    files.insert({"hash" => id})
    puts "Now ignoring download #{id}"
    exit
  end

  opts.on("", "--ignore-broken-files", "Ignore the id of broken files") do |id|
    options[:ignore_broken] = true
  end

  opts.on("-h", "--help", "Display this screen") do
    puts opts
    exit
  end
end

optparse.parse!

count = feeds.count()
puts "#{count} feed(s) to consider"
puts

i = 1
songs = []

feeds.find().each { |feed|
  puts "#{i}/#{count} - #{feed["url"]}".blue
  i += 1

  FeedParser.parse(feed["url"]).entries.each { |entry|
    !entry.enclosures.nil? && entry.enclosures.each { |enclosure|
      url = enclosure.href
      hash = Digest::SHA1.hexdigest(url)

      if files.find_one("hash" => hash)
        puts "#{hash}".red
      else
        puts "#{hash}".green

        File.exists?(temp_file) && File.delete(temp_file)
        system "curl --connect-timeout 10 \"#{url}\" > #{temp_file}"

        tag = ID3Lib::Tag.new(temp_file)
        
        if tag.artist.nil? || tag.title.nil? || tag.artist.empty? || tag.title.empty?
          if options[:ignore_broken]
            puts "Broken File. Ignoring. (#{hash})".red
            files.insert({"hash" => hash})
          else
            puts "Broken ID3 Tags (#{hash})".red
          end
          puts
          next
        end

        ic = Iconv.new('UTF-8//IGNORE', 'UTF-8')
        artist = ic.iconv(tag.artist + ' ')[0..-2]
        title  = ic.iconv(tag.title + ' ')[0..-2]

        artist.gsub!('/', ' ')
        title.gsub!('/', ' ')

        puts "#{artist} - #{title}".yellow

        tag.album = config.get_value("tags")["album"]
        tag.update!

        folder = "#{download_folder}/#{artist}"
        file   = "#{artist} - #{title}"
        file.slice! 0..200
        file += ".mp3"
        
        if !File.exists? folder
          File.makedirs folder
        end

        new_file = "#{folder}/#{file}"
        File.copy temp_file, new_file
        puts

        files.insert({
          "hash"      => hash,
          "file"      => new_file,
          "timestamp" => Time.new.to_s,
          "artist"    => artist,
          "album"     => title
        })

        songs.push("#{artist} - #{title}")
      end
    }
  }

  puts
}

puts "Downloaded #{songs.length > 0 ? songs.length.to_s.green : songs.length.to_s.red} new song(s)"
songs.each { |song| puts "  #{song}".yellow }
puts

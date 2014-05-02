#!/usr/bin/env ruby
# coding: utf-8

## mw2jekyll.rb --- MediaWiki database -> Jekyll Git repository

# Author::    David Jones (mailto: david@djones.eu)
# Copyright:: Copyright (C) 2014 David Jones
# License::   GNU GPLv3+
# Version::   0.0.0.alpha

# This script is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.

# This script is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this script.  If not, see <http://www.gnu.org/licenses/>.

## Commentary:

# This script initializes a bare repository.  To initialize into a
# normal repository, use /path/to/repo/.git

# The script will prompt you to install any missing required gems,
# however you must install pandoc <http://johnmacfarlane.net/pandoc/>
# manually.

## Code:

# Require our external gems or prompt the user to install them.
missing = %w( rugged mysql2 trollop pandoc-ruby ).select do |gem|
  begin
    require gem
    false
  rescue LoadError
    gem
  end
end
unless missing.empty?
  abort <<-MSG
#{ $PROGRAM_NAME } requires gem#{ 's' unless missing.one? } #{ missing.join ', ' }.
Install #{ missing.one? ? 'it' : 'them' } with `gem install #{ missing.join ' ' }`\
 and run this script again.
  MSG
end

# Utility to get the version number from the first N lines of this file.
def get_version(n = 12, regexp = /version:\W+([\w.-]+)/i)
  open __FILE__ do |f|
    f.each_line do |line|
      regexp.match(line) { |m| return m[1] }
      return unless f.lineno < n
    end
  end
end

# Parse command line options and create help message.
opts = Trollop.options do
  banner "A MediaWiki MySQL database to Jekyll Git repository conversion tool.

Usage: #{ $PROGRAM_NAME } [option]… <database> <repository>

Database options:"
  opt :db_user, 'MySQL user', default: 'root', short: 'u'
  opt :db_host, 'MySQL host', default: 'localhost', short: 'H'
  opt :db_password, 'Database password', type: :string, short: 'p'
  banner '
Repository options:'
  opt :repo_force, 'Overwrite an existing repository', short: 'f'
  banner'
General options:'
  version get_version || '[development]'
end

# Get the database name from ARGV.
Trollop.die 'source database required' if ARGV.empty?
opts[:db_name] = ARGV.shift

# Interpret the full repository path from ARGV.
Trollop.die 'target repository required' if ARGV.empty?
opts[:repo_path] = File.expand_path ARGV.shift

# Check there wasn't anything else on ARGV.
Trollop.die "too many options to ‘#{ cmd }’" unless ARGV.empty?

# Read in the database password if omitted (and we're on a tty.)
if opts[:db_password].nil? && STDIN.tty?
  require 'io/console'

  print "Password for MySQL user '#{ opts[:db_user] }'@'#{ opts[:db_host] }': "
  begin
    opts[:db_password] = STDIN.noecho(&:gets).chomp
  rescue NoMethodError
    # User killed the operation, bail out.
    abort 'Aborted.'
  end
  puts
end

# Connect to the database.
begin
  client = Mysql2::Client.new(host:     opts[:db_host],
                              username: opts[:db_user],
                              password: opts[:db_password],
                              database: opts[:db_name])
rescue Mysql2::Error => e
  abort "Error: #{ e.message }"
end
puts 'Connected to database.'

# Initialize the repository.  Lots of error checking omitted here!
unless File.directory? opts[:repo_path]
  require 'fileutils'

  FileUtils.mkdir_p opts[:repo_path]
  puts "Created directory at #{ opts[:repo_path].inspect }."
end

repo = Rugged::Repository.init_at opts[:repo_path], :bare
puts "Initialized repository at #{ repo.path.inspect }."

# Make sure we're not overwriting an existing repository.
unless repo.empty? || opts[:repo_force]
  abort "Error: #{ repo.path.inspect } is not an empty repository."
end

# Get the neccessany information from the database.
query = <<SQL.strip.gsub(/\s+/, ' ')
  select
    `user`.`user_email`         as `author_email`,
    `user`.`user_real_name`     as `author_name`,

    unix_timestamp(`revision`.`rev_timestamp`)
                                as `unix_time`,

    `page`.`page_title`         as `title`,
    `text`.`old_text`           as `blob`,
    `revision`.`rev_comment`    as `message`,

    `revision`.`rev_minor_edit` as `minor?`,
    !`revision`.`rev_parent_id` as `create?`,
    `revision`.`rev_deleted`    as `destroy?`
  from `text`
    inner join `revision` on `revision`.`rev_text_id` = `text`.`old_id`
    inner join `page`     on `page`.`page_id` = `revision`.`rev_page`
    inner join `user`     on `user`.`user_id` = `revision`.`rev_user`
  order by `revision`.`rev_id`
SQL

# Commit each row of the query to the repo.
result = client.query query, symbolize_keys: true, cast_booleans: true
abort 'Error: no results returned!' unless result.any?

index = Rugged::Index.new
# Convenience monkey patches.
class Object
  # Test for nil or empty.
  def blank?() nil? || empty? end
end

class String
  # Change "A String/Title, like this!" to "a-string-title-like-this".
  def sluggify() downcase.tr_s('^a-z0-9', '-').chomp('-') end

  # Change "A_title__like_this" to "A title like this".
  def unsnake() tr_s('_', ' ').strip end

  # Change "|some|wiki|guff|A title" to "A title".
  def deguff() rpartition('|').pop end

  # Change "Category:page" to "page"
  def catstrip() rpartition(':').pop end

  # Test for all-blank string.
  def blank?() strip.empty? end
end

print 'Populating repository'
result.each do |row|
  blob = <<-YAML
---
title: #{row[:title]}
---
  YAML
  blob << PandocRuby.convert(row[:blob], from: :mediawiki, to: :markdown)

  oid = repo.write blob, :blob

  # Make sure path is legal.
  path = row[:title].tr('/', '-') << '.markdown'

  index.add path: path, oid: oid, mode: 0100644

  author = {
    email: row[:author_email],
    name:  row[:author_name],
    time:  Time.at(row[:unix_time])
  }

  options = {
    tree:       index.write_tree(repo),
    author:     author,
    message:    row[:message],
    committer:  author,
    parents:    repo.empty? ? [] : [repo.head.target].compact,
    update_ref: 'HEAD'
  }

  commit = Rugged::Commit.create(repo, options)
  print '.'
end

# And we're done!
puts 'done!'
client.close

#!/usr/bin/env ruby
# coding: utf-8

## mw2jekyll.rb --- MediaWiki MySQL database to Jekyll Git repository

COPYRIGHT = <<END
Copyright (C) 2014 David Jones <david at djones.eu>

This script is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the
Free Software Foundation, either version 3 of the License, or (at your
option) any later version.

This script is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with this script.  If not, see <http://www.gnu.org/licenses/>.
END

USAGE = <<END
A MediaWiki MySQL database to Jekyll Git repository conversion tool.

Usage: #{$PROGRAM_NAME} [option]… <database> <repository>
END

COMMENTARY = <<END
This script will extract the textual revision history in MediaWiki
markup from a MediaWiki MySQL database, and use it to build a Jekyll
git repository, converting the markup to HTML as it goes.

You must have the `mysqld` daemon running for this to work.  This
script requires a few Ruby gems; you will be asked to install any that
are not found on your system.
END

VERSION = '0.0.0.beta'

## Utilities:

# Require external gems or instruct on how to install them.
def require_gems(*gems)
  # Collect gems that raise `LoadError` into `missing`.
  missing = gems.select do |gem|
    begin
      require gem
    rescue LoadError
      gem
    else
      false
    end
  end

  unless missing.empty?
    abort <<-MSG
#{$PROGRAM_NAME} requires #{missing.join ', '}.
Install #{missing.one? ? 'it' : 'them'} with\
 `gem install #{missing.join ' '}` and try again.
    MSG
  end
end

# Convenience monkey patches.
class String
  # Change "A String/Title, like this!" to "a-string-title-like-this".
  def sluggify() downcase.tr_s('^a-z0-9', '-').chomp('-') end

  # Change "A_title__like_this" to "A title like this".
  def unsnake() tr_s('_', ' ').strip end

  # Change "Category:page" to "page"
  def catstrip() rpartition(':').pop end

  # Test for all-blank string.
  def blank?() strip.empty? end
end

## Code:

require 'fileutils'
require_gems 'rugged', 'mysql2', 'trollop', 'wikicloth'

# Parse command line options and create help message.
opts = Trollop.options do
  banner USAGE
  banner '
Database options:'
  opt :db_user, 'MySQL user', default: 'root', short: 'u'
  opt :db_host, 'MySQL host', default: 'localhost', short: 'H'
  opt :db_password, 'Database password (default: ask)', type: :string, short: 'p'
  opt :db_limit, 'Number of records (default: all)', type: :int, short: 'n'
  banner '
Repository options:'
  opt :repo_force, 'Overwrite an existing repository', short: 'f'
  banner'
General options:'
  version VERSION
end

# Get the database name from ARGV.
Trollop.die 'source database required' if ARGV.empty?
opts[:db_name] = ARGV.shift

# Interpret the full repository path from ARGV.
Trollop.die 'target repository required' if ARGV.empty?
opts[:repo_path] = File.expand_path ARGV.shift

# Check there wasn't anything else on ARGV.
Trollop.die "too many arguments specified" unless ARGV.empty?

# Read in the database password if omitted (and we're on a tty.)
if opts[:db_password].nil? && STDIN.tty?
  require 'io/console'

  print "Password for MySQL user '#{opts[:db_user]}'@'#{opts[:db_host]}': "
  begin
    input = STDIN.noecho &:gets
  rescue Interrupt
    abort
  else
    opts[:db_password] = input.chomp
  end
  puts
end

# Get the neccessany information from the database.
db_opts = {
  host:     opts[:db_host],
  username: opts[:db_user],
  password: opts[:db_password],
  database: opts[:db_name]
}
begin
  client = Mysql2::Client.new(db_opts)
rescue Mysql2::Error => e
  abort "Error: #{e.message}"
else
  puts 'Connected to database.'
end

query = <<SQL
select
  `user`.`user_email`         as `author_email`,
  `user`.`user_real_name`     as `author_name`,

  unix_timestamp(`revision`.`rev_timestamp`)
                              as `unix_time`,

  `page`.`page_title`         as `title`,
  `text`.`old_text`           as `content`,
  `revision`.`rev_comment`    as `message`,

  `revision`.`rev_minor_edit` as `minor?`
from `text`
  inner join `revision` on `revision`.`rev_text_id` = `text`.`old_id`
  inner join `page`     on `page`.`page_id` = `revision`.`rev_page`
  inner join `user`     on `user`.`user_id` = `revision`.`rev_user`
order by `unix_time`
#{"limit #{opts[:db_limit]}" if opts[:db_limit]}
SQL

result = client.query query, symbolize_keys: true, cast_booleans: true
client.close

unless result.any?
  abort "Error: nothing in #{db_opts[:database].inspect} matched query:
#{query}"
end

# Check for existance of destination repo.
if File.directory? opts[:repo_path]
  if opts[:repo_force]
    warn "Warning: overwriting directory #{opts[:repo_path].inspect}."
    FileUtils.rm_rf opts[:repo_path]
  else
    abort "Error: destination #{opts[:repo_path].inspect} exists."
  end
end

repo = Rugged::Repository.init_at opts[:repo_path], :bare
puts "Initialized repository at #{repo.path.inspect}."

# Add a template to the first commit.
blob = <<EOS
<!DOCTYPE html>
<meta charset="utf-8">
<title>{{ page.title }}</title>
<body>
{{ content }}
</body>
EOS
repo.index.add(path: '_layouts/default.html',
               oid:  repo.write(blob, :blob),
               mode: 0100644)

# Add a symlink from site root to the main page (added next.)
repo.index.add(path: 'index.html',
               oid:  repo.write('mainpage.html', :blob),
               mode: 0120000)

# Patch WikiCloth handlers.
module WikiCloth
  class WikiLinkHandler
    def url_for(page)
      # Used in <a href="#{url_for(page)}">...</a>
      "#{page.catstrip.sluggify}.html"
    end
  end
end

print 'Populating repository'
result.each do |row|
  title = row[:title].unsnake
  path  = row[:title].sluggify << '.html'

  # Override whatever encoding the database thinks our content is in.
  markup = row[:content].force_encoding 'utf-8'

  html = WikiCloth::Parser.new(data: markup).to_html.squeeze("\n")
  blob = <<-EOS
---
layout: default
title: #{title}
---

#{html}

<!-- MediaWiki markup -->
<!--
#{row[:content]}
-->
    EOS
  repo.index.add(path: path,
                 oid:  repo.write(blob, :blob),
                 mode: 0100644)

  # Try to construct a reasonable commit message.
  message = row[:message]
  if message.blank?
    message = row[:minor?] ? 'Minor edit' : "Modified #{path}"
  end

  author = {
    email: row[:author_email],
    name:  row[:author_name],
    time:  Time.at(row[:unix_time])
  }

  options = {
    tree:       repo.index.write_tree(repo),
    author:     author,
    message:    message,
    committer:  author,
    parents:    repo.empty? ? [] : [repo.head.target].compact,
    update_ref: 'HEAD'
  }

  Rugged::Commit.create(repo, options)

  # Print a progress marker.
  print '.'
end

puts 'done!'

## mw2jekyll.rb ends here

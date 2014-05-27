# mw2jekyll

A MediaWiki MySQL database to Jekyll Git repository conversion tool.

This script will extract the textual revision history in MediaWiki markup from a MediaWiki MySQL database, and use it to build a Jekyll git repository, converting the markup to HTML as it goes.

Each commit is timestamped and authored appropriately, so it looks like you've been using Jekyll all along!

You must have the `mysqld` daemon running for this to work.  This script requires a few Ruby gems; you will be asked to install any that are not found on your system.

## Example

To convert a MySQL database `mwdb` to a bare Jekyll repository at /path/to/repo.git, assuming this script is in your path as `mw2jekyll`, simply run

    $ mw2jekyll mwdb /path/to/repo.git

This will ask for the MySQL user `'root'@'localhost'`'s password on the command line.  Depending on markup complexity and number of revisions, the operation can take a while.

To overwrite your repository at a later time, pass the `-f` flag to force removal like so:

    $ mw2jekyll -f mwdb /path/to/repo.git

You can pass a few database options explicitly:

    $ mw2jekyll -u mysqluser -H some_host -p "some password" mwdb /path/to/repo.git

Once you have a bare repository, you can clone from it and run Jekyll in the project root:

    $ gem install jekyll  # if you don't have it already
    $ git clone /path/to/repo.git jekyll-project
    $ (cd jekyll-project && jekyll serve)

Jekyll will serve to [localhost:4000](http://localhost:4000) (try [localhost:4000/welcome.html](http://localhost:4000/welcome.html) for the welcome page.)

## Usage notes

Try `mw2jekyll.rb --help` to see all available options.

The script will prompt you to install any required gems.

## Copying

This program is Copyright (C) 2014 David Jones.

This program comes with ABSOLUTELY NO WARRANTY.  You may redistribute copies of this program under the terms of the GNU General Public License.  For more information about these matters, see the file named COPYING.

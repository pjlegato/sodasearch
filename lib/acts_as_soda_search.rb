#
# SodaSearch full text indexing module for Ruby on Rails
# Copyright (C) 2006 Networked Knowledge Systems, Inc.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
#
#
# 1.0 by Paul Legato (plegato@nks.net), July 2006
#

require 'stemmer'

module NKS
  module Acts #:nodoc:
    module SodaSearch #:nodoc:

      # if SLOW_ADD is set to false, SodaSearch will use Postgres' COPY command, which is much, much faster
      # than doing a bunch of INSERTS, but not part of the ANSI SQL standard.
      # If set to true, it uses a cross-database ANSI SQL compliant way via ActiveRecord that is much slower.
      #
      # On my laptop, SLOW_ADD = true does around 200 terms per second, while SLOW_ADD = false does about 1000 tps.
      SLOW_ADD = false
      
      MINIMUM_WORD_LENGTH = 3
      STOPWORDS = %w( I a about an and are as at be by com con de en el for from how in is it la not
                      of on or that the this to was what when where who will with und the www)
      
      def self.included(base)
        base.extend ClassMethods
      end

      module ClassMethods

      #
      # Call this method in an ActiveRecord class to make it SodaSearchable.
      #
      # Requires two arguments: the first is the ActiveRecord Class that will hold the indices. The second is 
      # the AR class that will hold the terms. (Maybe we can auto-generate these in v2.)
      #
      # These classes/tables *MUST* implement the spec outlined in the SodaSearch README file. A RuntimeError is thrown
      # if they don't have the proper column names.
      #
      def acts_as_soda_search(indices_class, terms_class)
        logger.info ("* acts_as_soda_search initializing for #{self.name}. indices_class: #{indices_class.inspect}. terms_class: #{terms_class.inspect}")


        # Make sure the classes do what we need them to
        if [ indices_class, terms_class ].any? { |x|
            x.nil? || !x.is_a?(Class) || !x.ancestors.include?(ActiveRecord::Base)              
          } 
          raise RuntimeError.new("ERROR: acts_as_soda_search requires two arguments: indices_class and terms_class, both of which must be classes.")
          return
        elsif
          begin
            cols = indices_class.columns_hash.keys
            !(cols.include?('term_id') && cols.include?('position') && cols.include?('user_id') && 
              cols.include?('indexee_id') && cols.include?('public'))
          end ||
              begin
                cols = terms_class.columns_hash.keys
                !cols.include?('term')
              end
          raise RuntimeError.new("acts_as_soda_search ERROR: you didn't implement all required attributes in your indices_class and/or in your terms_class (see README)")
          return
        end
        
        # we save a symbol rather than the Class object so that the class can be reloaded while we run.
        self.const_set :Soda_indices_class, indices_class.name.to_sym
        self.const_set :Soda_terms_class, terms_class.name.to_sym

        include NKS::Acts::SodaSearch::InstanceMethods
        extend NKS::Acts::SodaSearch::SingletonMethods
      end

      #### Utility methods: statistics
      def count_stored_terms
        count = soda_terms_class.count
        info("counted #{count} terms in #{soda_terms_class.table_name}")
        count
      end


      def count_index_entries
        count = soda_indices_class.count
        info("counted #{count} indices in #{soda_indices_class.table_name}")
        count
      end

      # See notes on acts_as_soda_search method.
      def soda_indices_class
        eval self.const_get(:Soda_indices_class).to_s
      end
      # See notes on acts_as_soda_search method.
      def soda_terms_class 
        eval self.const_get(:Soda_terms_class).to_s
      end

      # Do a basic search, get an Array of ids of this class, in descending order of relevance.
      # Right now, we AND all the terms together and provide no other options.
      #
      # The search algorithm can have all kinds of tweaks and enhancements done to it later.
      #
      # The result is an Array of Arrays, sorted in descending order of relevance. Each subarray is of the form [ database_id, "numeric relevance"].
      # The optional user_id will filter the results on the user_id column of the indices table.
      #
      # N.B. user_id is not sanitized in any way before insertion into the database query.
      #
      def search(query, user_id = nil, do_stemming=true)
        # Split terms string on whitespace, convert to Array of term ID numbers for those that are in the terms table.
        term_ids = Array.new
        query.split(/\s+/).each {|term|
          term.downcase! if do_stemming
          t = self.soda_terms_class.find(:first, :conditions => ["term = ?", (do_stemming ? term.stem : term)])
          term_ids.push(t.id) unless t.nil?
        } unless query.nil? || query.empty?
        
        if term_ids.empty?  # don't bother the database
          []
        else
          # Count term_ids in the index table. Return an ordered Array of indexee_ids according to how many terms they have.
          soda_indices_class.connection.execute(<<END
SELECT indexee_id, sum(count) FROM (SELECT indexee_id, COUNT(indexee_id), term_id FROM #{#{soda_indices_class.table_name}} where term_id in
(#{term_ids.join(',')}) #{ user_id.nil? ? '' : "AND user_id = '" + user_id + "' " }
GROUP BY indexee_id , term_id) as foo group by foo.indexee_id
HAVING COUNT(term_id) = #{term_ids.size}
ORDER BY sum DESC;
END
                                              ).result # the HAVING implements the AND by excluding rows with not all the terms
        end

      end # search
      

      #
      # Do some kind of reindexing on instances of this class.
      #
      # Types:
      # ------
      # :all - Erase the index and terms tables for this class. Reindex all records.
      #        This can take a long time.
      # :unindexed - Reindex only those instances of self which are not referenced in the index table at all.
      #
      def reindex(type)
        info(" ** #{self.name}.reindex(#{type.to_s}) called. This may take a while..")
        start = Time.now.to_i
        reindexed = 0

        case type
        when :all
          
          soda_indices_class.delete_all()
          soda_terms_class.delete_all()
          
          self.find(:all).each {|item|
            item.autoindex()
            reindexed += 1
          }

        when :unindexed
          self.find(:all, 
                    :joins => "LEFT OUTER JOIN #{self.soda_indices_class.table_name} ON #{self.soda_indices_class.table_name}.indexee_id = #{self.table_name}.id",
                    :conditions => "#{self.table_name}.id not in (select distinct indexee_id from #{self.soda_indices_class.table_name})",
                    :select => "#{self.table_name}.id"
                    ).each {|item|

            # doesn't work. it doesn't like loading the whole object with :joins, for some reason.
            # item.autoindex()

            self.find(item.id).autoindex()
            reindexed += 1
          }
          
        else
          error(" * Unknown type argument #{type.to_s}. Aborting..")
          raise ArgumentError.new("didn't specify a valid argument for reindex()")
        end

        endTime = Time.now.to_i
        info(if reindexed == 0
               "reindex() done in #{endTime - start} seconds. No items found to reindex."
             else
               "reindex(#{type.to_s}): reindexed #{reindexed} objects in #{endTime - start} seconds.\n" + 
                 "   #{(endTime - start) / reindexed} seconds per object, #{reindexed / (endTime - start)} objects per second."
             end)

      end # reindex


      def count_unused_terms
        count = soda_terms_class.count_by_sql(<<END
SELECT COUNT(#{soda_terms_class.table_name}.id) FROM #{soda_terms_class.table_name} WHERE id NOT IN
 (SELECT DISTINCT term_id from #{soda_indices_class.table_name})
END
                                           )
        info("counted #{count} unused terms.")
        count
      end

      def purge_unused_terms
        start = Time.now.to_i
        count = soda_terms_class.delete_all("#{soda_terms_class.table_name}.id NOT IN (SELECT DISTINCT term_id from #{soda_indices_class.table_name})")
        info ("purged #{count} unused search terms.\npurge_unused_terms done in #{Time.now.to_i - start} seconds.")
        count
      end


      # This clears out the index and terms tables.
      def purge_all
        start = Time.now.to_i
        ActiveRecord::Base.transaction {
          indices_deleted = soda_indices_class.delete_all
          terms_deleted = soda_terms_class.delete_all
          info("purge_all - deleted #{terms_deleted} terms and #{indices_deleted} indices")
        }
        info("purge_all done in #{Time.now.to_i - start} seconds.")
      end

protected
      def info(msg)
        logger.info("* acts_as_soda_search (for #{name}): #{msg}")
      end
      def debug(msg)
        logger.debug("* acts_as_soda_search (for #{name}): #{msg}")
      end
      def error(msg)
        logger.error("* ERROR: acts_as_soda_search (for #{name}): #{msg}")
      end

    end # ClassMethods

      module SingletonMethods
      end

      module InstanceMethods

        # Abstract method. Implement this in your inheriting class to provide the index()
        # method with whatever it needs to know to re-index the object.
        def autoindex
          raise NotImplementedError.new("* SodaSearch: You must implement autoindex() in your inheriting class.")
        end
       

        #
        # Causes the instance to index something and add it to the database, defined by what_to_index.
        #
        # Use with clear_old = false to add new data to an existing
        # index. There is no need to re-index an entire huge object
        # just because a paragraph of text is postpended to the end
        # entire object (which would take a while); just call index
        # with the new data in what_to_index.
        #
        # Use with clear_old = true to purge all references to the
        # self object in the indices, and then add the stuff in
        # what_to_index to the database.
        #
        # ***** CAUTION: Use clear_old = true only when the site is running in single-user mode, to avoid race conditions.
        #       TODO: look into row locking
        #
        # What_to_index is an array of strings and/or procs that return either strings or other procs.
        # The code as it stands can eval 2 levels of nested procs. Someday we'll make it recursive and Lispy
        # so you can have infinitely nested procs. That'd be Cool (tm).
        #
        # We use procs sometimes instead of actual text because the
        # actual text can be huge when aggregated. With the procs, we can
        # only pull the text of one segment into memory at any
        # given time.
        #
        # Downcases and stems the terms if do_stemming = true (the default scenario).
        #
        #
        # * See doc/Indexer-Readme.txt for an explanation of subsource_url.
        #
        #
        def index(what_to_index, subsource_url = nil, clear_old = false, do_stemming = true)
          info("#{clear_old ? 're' : ''}indexing #{self.id}...")
          warn("** clear_old is set to TRUE. Don't do this in multiuser mode, to avoid race conditions.") if clear_old

          start_time = Time.new.to_f

          position = 0

          ActiveRecord::Base.transaction {
            # first, delete any old references to this object in the index table, if we are told to
            self.class.soda_indices_class.delete_all("indexee_id = '#{id}'") if clear_old
          
            #
            # make arrays to hold the terms and ids we find if doing a fast (bulk) add.
            # (See comments above on SLOW_ADD. These are only actually used when SLOW_ADD = false.)
            # Hash is no good because order is important.
            #
            # term_ids entries are normally string UUIDs. They may
            # also be :nonexistent where there is no entry currently
            # in the database for that term, or they may be :unknown
            # to indicate that we haven't yet checked to see whether
            # that term exists.
            #
            # nonexistent_term_ids and unknown_term_ids are Arrays
            # of int indices into term_ids that point to
            # :nonexistent and :unknown entries. These are used for
            # performance reasons, to avoid having to re-scan the
            # entire (long) term_ids array to find them.
            #
            # These get processed once per what_to_index item right now, to not eat up huge
            # amounts of memory and still acheive a reasonable throughput by minimizing DB hits.
            #
            terms = Array.new
            term_ids = Array.new
            nonexistent_term_ids = Array.new

            what_to_index.each{ |item|
              #debug "item is #{item.inspect}, self is #{self.inspect}"


              #
              # queue is the list of stuff to process within the current what_to_index item.
              # Each what_to_index item may have any number of strings or procs.
              #
              # if it's a string, use that.
              # if it's a lambda, call it and use that.
              #
              queue = if item.is_a?(String)
                        [ item ]
                      else
                        item.call(self)
                      end
              
              #
              # Now we have an array of strings and procs. Scan and
              # add to index, calling proc if necessary to get a
              # string.
              #

              #debug "queue is #{queue.inspect}"

              queue.each { |x|
                scanner = StringScanner.new(x.is_a?(String) ? x : x.call())
                while !scanner.eos?
                  
                  # find next word
                  word = scanner.scan(/[0-9a-zA-Z']+/)
                  
                  unless word.nil? ||  word.size < MINIMUM_WORD_LENGTH || STOPWORDS.include?(word)
                    if do_stemming
                      word.downcase!
                      word = word.stem
                    end

                    ### add word to the index.
                    
                    if SLOW_ADD # (see comments above for SLOW_ADD)
                      #
                      # slow, inefficient way. Requires 2 DB hits for each item, 1 to see if it's already a term, and 1 to
                      # add the index.
                      # This does just under 200 terms per second on my MacBook with autocommit off, so it takes a while to index large datasets.
                      #

                      # see if the term is in the db already
                      term = (self.class.soda_terms_class.find_by_term(word) || self.class.soda_terms_class.create(:term => word))
                      term_id = term.id
                      
                      # add to index
                      self.class.soda_indices_class.create(:term_id => term_id,
                                                           :position => position,
                                                           :user_id => self.user_id,
                                                           :indexee_id => self.id,
                                                           :subsource_url => subsource_url)
                    else 
                      terms.push(word)
                      term_ids.push(:unknown)
                    end # if SLOW_ADD
                    
                    position += 1

                  end # while
                  
                  # skip to next word
                  word = scanner.skip(/[^0-9a-zA-Z']+/)      
                end # while
                
              } # queue.each
              
            } # what_to_index.each

            # process the accumulated bulk-add list in fast mode.
            if not SLOW_ADD
              unique_terms = terms.uniq
              debug("   Fast-adding  #{terms.size} terms (#{unique_terms.size} unique.)")
              #debug("items: #{terms.inspect}")

              # 1) Add any terms that do not already exist in the database. 
              #    We do this by COPYing them into a temporary table, then INSERTing
              #    into the real table where the record does not exist there.
              
              self.class.soda_indices_class.connection.execute <<END
             CREATE TEMPORARY TABLE soda_terms_loader( LIKE #{self.class.soda_terms_class.table_name} INCLUDING DEFAULTS) ON COMMIT DROP;
END
              # execute() doesn't like COPYs... so we have to go raw.
              self.class.soda_indices_class.connection.raw_connection.exec("COPY soda_terms_loader (term) FROM STDIN;")
              unique_terms.each{|term|
                self.class.soda_indices_class.connection.raw_connection.putline(term + "\n")
              }
              self.class.soda_indices_class.connection.raw_connection.putline("\\.\n")
              self.class.soda_indices_class.connection.raw_connection.endcopy

              #debug("  * found " + self.class.soda_terms_class.connection.execute('SELECT COUNT(*) FROM soda_terms_loader').result.inspect +
              #      " items in soda_terms_loader temporary table")
              
              self.class.soda_indices_class.connection.execute <<END
             INSERT INTO #{self.class.soda_terms_class.table_name} (SELECT * FROM soda_terms_loader as newdata
                    WHERE NOT EXISTS ( SELECT * FROM #{self.class.soda_terms_class.table_name} as real
                                       WHERE real.term = newdata.term
                                     )
             );
             DROP TABLE soda_terms_loader;
END
              # All terms are now in the database.
              # We need to get their IDs.
              # Select the term and ID into a hash as key/val.
              #debug(" -- Getting term ids ...")
              term_object_cache = self.class.soda_terms_class.find(:all, :conditions => ["term IN (?)", unique_terms ])
              #debug("   Got #{term_object_cache.size} term objects back from database.")

              terms_hash = Hash.new
              term_object_cache.each {|item|
                terms_hash[item.term] = item.id
              }

              
              # Now add the indices for each term with a COPY.
              #debug(" Starting index COPY of #{terms.size} terms..")
              self.class.soda_indices_class.connection.raw_connection.exec("COPY #{self.class.soda_indices_class.table_name} (term_id, position, user_id, indexee_id, subsource_url) FROM STDIN;")
              endStub = "#{self.user_id}\t#{self.id}\t#{subsource_url.nil? ? "NULL" : subsource_url}\n"

              terms.each_with_index{|currentTerm, pos|
                #debug(pos) if pos % 1000 == 0
                self.class.soda_indices_class.connection.raw_connection.putline(terms_hash[currentTerm].to_s +
                                                                                "\t#{pos.to_s}\t" + endStub)
              }
              self.class.soda_indices_class.connection.raw_connection.putline("\\.\n")
              self.class.soda_indices_class.connection.raw_connection.endcopy
              debug(" * Done fast-adding indices. Found " + self.indexes_count().inspect + " terms for self.id")
            end # if not SLOW_ADD



          } # transaction

          ## Clean up the database and delete any unreferenced terms, if we have deleted any indices.
          self.class.purge_unused_terms if clear_old

          end_time = Time.new.to_f
          info(if end_time == start_time
                 "#{clear_old ? 're' : ''}indexed #{position} terms in 0 seconds - infinity terms per second."
               else
                 "#{clear_old ? 're' : ''}indexed #{position} terms in #{end_time - start_time} seconds - #{position / (end_time - start_time)} terms per second."
               end)

          
          # return how many words we added
          position
        end # index

        # Returns the number of terms that have been added to the index for this object.
        def indexes_count
          self.class.soda_terms_class.connection.execute("select count(*) from #{self.class.soda_indices_class.table_name} " +
                                                         "WHERE indexee_id = '#{self.id}'").result.first.first.to_i
        end # indexes_count


        # This removes all index data for the current object with subsource = subsource_url.
        def erase_subsource(subsource_url)
          self.class.soda_indices_class.delete_all(["indexee_id = '#{self.id}' AND subsource_url = ?", subsource_url])
        end
        
protected
      def info(msg)
        logger.info("* acts_as_soda_search (for #{self.class.name}): #{msg}")
      end
      def warn(msg)
        logger.warn("* WARNING: acts_as_soda_search (for #{self.class.name}): #{msg}")
      end
      def debug(msg)
        logger.debug("* acts_as_soda_search (for #{self.class.name}): #{msg}")
      end
      def error(msg)
        logger.error("* ERROR: acts_as_soda_search (for #{self.class.name}): #{msg}")
      end

      end # instanceMethods
      
    end
  end
end



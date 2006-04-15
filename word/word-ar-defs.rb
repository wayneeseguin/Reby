if __FILE__ =~ /word-ar-defs.rb/
    require 'rubygems'
    require_gem 'activerecord', '<= 1.13.2'
    if $reby != nil
        $reby.log "ActiveRecord <= 1.13.2"
    end
else
    require 'active_record'
    if $reby != nil
        $reby.log "ActiveRecord > 1.13.2"
    end
end

class Word < ActiveRecord::Base
    NOT_PRACTICE = false
    PRACTICE = true
    
    def Word::random( practice = NOT_PRACTICE )
        retval = nil
        
        if practice
            w = Word.find_by_sql( " \
                SELECT * \
                FROM word_frequency \
                WHERE times_used > 0 \
                ORDER BY random() \
                limit 1 \
            " )
        else
            w = Word.find_by_sql( " \
                SELECT * \
                FROM word_frequency \
                ORDER BY times_used, random() \
                limit 1 \
            " )
        end
        
        if w != nil and not w.empty?
            retval = Word.find( w[ 0 ].id )
        end
        return retval
    end
    
    def mixed
        return word.split(//).sort_by{rand}.join
    end
end

class BattleWord < ActiveRecord::Base
    def BattleWord::random
        retval = nil
        
        w = BattleWord.find( :first )
        
        if w != nil
            retval = Word.find( w.word_id )
        end
        
        return retval
    end
end
class PracticeWord < ActiveRecord::Base
    def PracticeWord::random
        retval = nil
        
        w = PracticeWord.find( :first, :order => 'random()' )
        
        if w != nil
            retval = Word.find( w.word_id )
        end
        
        return retval
    end
end

class Battle < ActiveRecord::Base
    has_many :games
    belongs_to :starter, :foreign_key => 'starter', :class_name => 'Player'
end
class Game < ActiveRecord::Base
    has_many :participations
    belongs_to :battle
end

class Player < ActiveRecord::Base
    EQUALITY_MARGIN = 0.1  # +/- around 0.5 success rate
    MAX_POINT_ADJUSTMENT = 2.0
    
    has_many :participations
    belongs_to :title_set
    has_many :equipment
    
    def games_played( days = nil )
        num_games = nil
        days = days.to_i
        if days < 1
            days = 365 * 50
        end
        p = Participation.find_by_sql [
            " \
                select count(*) as num_games \
                from participations, games \
                where participations.player_id = ? \
                    AND participations.game_id = games.id \
                    AND games.end_time > NOW() - '? days'::INTERVAL \
            ",
            id,
            days
        ]
        if not p.empty?
            num_games = p[ 0 ][ 'num_games' ].to_i
        end
        return num_games
    end
    
    # Battle Points
    def bp( days = nil )
        points = nil
        
        days = days.to_i
        rows = nil
        if days > 0
            rows = Participation.find_by_sql [
                " \
                    select sum( participations.points_awarded ) as bp \
                    from participations, games \
                    where player_id = ? \
                        AND participations.game_id = games.id \
                        AND games.end_time > NOW() - '? days'::INTERVAL \
                ",
                id,
                days
            ]
        else
            rows = Participation.find_by_sql [
                " \
                    select sum( points_awarded ) as bp \
                    from participations \
                    where player_id = ? \
                ",
                id
            ]
        end

        if not rows.nil? and not rows.empty?
            points = rows[ 0 ].bp.to_i
        end
        
        return points
    end
    
    def title
        retval = nil
        t = Title.find_by_sql [
            " \
                select titles.text \
                from titles \
                where \
                    title_level_id <= ? \
                    and title_set_id = ? \
                order by title_level_id desc \
                limit 1 \
                ",
            level,
            title_set_id
        ]
        if not t.nil? and not t.empty?
            retval = t[ 0 ].text
        end
        return retval
    end
    
    def level
        retval = nil
        t = TitleLevel.find_by_sql [
            " \
                select id, points \
                from title_levels \
                where \
                    points <= ? \
                order by points desc \
                limit 1",
            bp
        ]
        if not t.nil?
            retval = t[ 0 ].id
        end
        return retval
    end
    
    # Returns true if the amount was successfully debited from the player's money.
    # Returns false if the player has insufficient funds.
    def debit( amount )
        debitted = false
        if money >= amount
            update_attribute( :money, money - amount )
            debitted = true
        end
        return debitted
    end
    
    def credit( amount )
        update_attribute( :money, money + amount )
    end
    
    def icon
        if level < 10
            the_icon = title_set.icons[ 0 ]
        else
            the_icon = title_set.icons[ 1 ]
        end
        
        return the_icon
    end
    
    def time_of_last_battle
        p = Game.find(
            :first,
            :include => [ :participations ],
            :conditions => [
                "participations.player_id = ? AND participations.game_id = games.id AND games.end_time IS NOT NULL",
                id
            ],
            :order => 'games.end_time DESC'
        )
        if p != nil
            return p.end_time
        else
            return nil
        end
    end
    def time_of_last_victory
        p = Game.find(
            :first,
            :include => [ :participations ],
            :conditions => [
                "participations.player_id = ? AND \
                 participations.game_id = games.id AND \
                 participations.points_awarded IS NOT NULL AND \
                 games.end_time IS NOT NULL",
                id
            ],
            :order => 'games.end_time DESC'
        )
        if p != nil
            return p.end_time
        else
            return nil
        end
    end
    
    def under_limit?( item )
        num_owned = Equipment.count( [
            "item_id = ? AND player_id = ?",
            item.id,
            id
        ] )
        return( num_owned < item.ownership_limit )
    end
    
    def success_rate( opponents = [] )
        if not (
            opponents.respond_to? :length and
            opponents.respond_to? :collect
        ) 
            opponents = [ opponents ]
        end
        if opponents.nil?
            return nil
        end
        if opponents.empty?
            begin
                sql = " \
                        SELECT ( ( \
                            SELECT COUNT(game_id) FROM participations WHERE player_id = ? AND points_awarded IS NOT NULL \
                        )::FLOAT / ( \
                            SELECT COUNT(game_id) FROM participations WHERE player_id = ? \
                        )::FLOAT ) AS success_rate \
                    "
                rows = Participation.find_by_sql [ sql, id, id ]
                if rows and rows[ 0 ]
                    return rows[ 0 ][ 'success_rate' ].to_f
                end
            rescue PGError => e
                # ignore
                $stderr.puts e.message
                $stderr.puts e.backtrace.join( "\t\n" )
            end
        end
        if not opponents.include?( self )
            opponents << self
        end
        rate = nil
        opponent_value_string = Array.new( opponents.length, '?' ).join( ', ' )
        oids = opponents.collect { |o| o.id }
        sql = <<-EOS
            select count(*) AS num_battles from (
                select
                    p.game_id,
                    bool_and( p.player_id in (#{opponents.collect { |o| o.id }.join( ', ' )}) ) 
                        AS includes_all_players
                from
                    num_participants n,
                    participations p
                where
                    p.game_id = n.game_id
                    and n.num_participants = #{opponents.length}
                group by
                p.game_id
            ) AS x where includes_all_players = true
        EOS
        sql2 = <<-EOS
            select count(*) AS won_battles from (
                select game_id from (
                    select
                        p.game_id,
                        bool_and( p.player_id in (#{opponents.collect { |o| o.id }.join( ', ' )}) ) 
                        AS includes_all_players
                    from
                        num_participants n,
                        participations p
                    where
                        p.game_id = n.game_id
                        and n.num_participants = #{opponents.length}
                    group by
                        p.game_id
                ) AS x where includes_all_players = true
                INTERSECT
                select game_id
                from participations
                where player_id = #{id}
                    and points_awarded is not null
            ) AS y
        EOS
        
        begin
            result = Participation.find_by_sql( sql )[ 0 ]
            result2 = Participation.find_by_sql( sql2 )[ 0 ]
            if result and result2
                total_battles = result[ 'num_battles' ].to_i
                won_battles = result2[ 'won_battles' ].to_i
                if total_battles > 0
                    rate = won_battles.to_f / total_battles.to_f
                else
                    rate = nil
                end
            end
        rescue Exception => e
            $stderr.puts e.message
            $stderr.puts e.backtrace.join( "\t\n" )
            # ignore
        end
        return rate
    end
    
    def point_adjustment( opponents )
        sr = success_rate( opponents )
        
        return 1.0 if sr.nil?
        
        n = opponents.length
        even_rate = 1.0 / n
        
        delta = ( sr - even_rate ).abs
        if sr > even_rate
            rate_gap = ( 1.0 - even_rate )
            factor = ( rate_gap - delta ) / rate_gap
        else
            rate_gap = even_rate
            factor = MAX_POINT_ADJUSTMENT - ( rate_gap - delta ) * ( MAX_POINT_ADJUSTMENT - 1.0 ) / rate_gap
        end
        
        return factor
    end
    
    def notable_opponents
        easiest = nil
        easiest_rate = -1.0
        toughest = nil
        toughest_rate = 1.1
        equal = nil
        equal_margin = 1.0
        
        Player.find( :all ).each do |player|
            next if player == self
            
            r = success_rate( player )
            
            if r != nil
                if r > easiest_rate
                    easiest = player
                    easiest_rate = r
                end
                if r < toughest_rate
                    toughest = player
                    toughest_rate = r
                end
                margin = ( r - 0.5 ).abs
                if ( margin <= EQUALITY_MARGIN ) and ( margin < equal_margin )
                    equal = player
                    equal_margin = margin
                end
            end
        end
        
        return {
            :easiest => easiest,
            :easiest_rate => easiest_rate,
            :equal => equal,
            :equal_margin => equal_margin,
            :toughest => toughest,
            :toughest_rate => toughest_rate,
        }
    end
    
    def num_words_contributed
        return Word.count( [ "suggester = ?", id ] )
    end
    
    def odds
        r = success_rate
        if success_rate != nil
            return 2.0 - r.to_f
        else
            return nil
        end
    end
    
    def odds_string( space = ' ' )
        return nil if odds.nil?
        first_left = left = 1
        first_right = right = odds
        i = 2
        while left < 100 and ( right - right.to_i ).abs > 0.1
            left = first_left * i
            right = first_right * i
            i += 1
        end
        return "#{left}#{space}:#{space}#{right.to_i}"
    end
    
    def equipped_item( item )
        return equipment.find(
            :first,
            :conditions => [
                "item_id = ? AND equipped",
                item.id
            ]
        )
    end
end

class Participation < ActiveRecord::Base
    belongs_to :game
    
    def player
        return Player.find( player_id )
    end
end

class Channel < ActiveRecord::Base
end

class Title < ActiveRecord::Base
    belongs_to :title_level
end

class TitleSet < ActiveRecord::Base
    has_many :titles, :order => 'title_level_id'
    has_many :players
    
    def icons
        retval = []
        file_prefix = name.downcase.gsub( / /, '-' )
        retval << file_prefix + "1"
        retval << file_prefix + "2"
    end
end

class TitleLevel < ActiveRecord::Base
    has_many :titles
end

class Item < ActiveRecord::Base
end

class Equipment < ActiveRecord::Base
    belongs_to :player
    belongs_to :item
    
    def name
        item.name
    end
end

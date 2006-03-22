require 'active_record'

class Word < ActiveRecord::Base
    def Word::random
        return Word.find(
            :first,
            :order => 'RANDOM()',
            :limit => 1
        )
    end
    
    def mixed
        return word.split(//).sort_by{rand}.join
    end
end

class Game < ActiveRecord::Base
    has_many :participations
end

class Player < ActiveRecord::Base
    BASE_RATING = 2000
    MAX_WINS_PER_HOUR = 6
    
    has_many :participations
    
    def games_played
        return Participation.count( "player_id = #{id}" )
    end
    
    def rating
        points = BASE_RATING
        
        g = Participation.find_by_sql [
            " \
                select sum( points_awarded ) as rating \
                from participations \
                where player_id = ? \
            ",
            id
        ]
        if not g.nil? and not g.empty?
            points += g[ 0 ].rating.to_i
        end
        
        return points
    end
    
    def save_rating_records
        r = rating
        if r > highest_rating
            highest_rating = r
        end
        if r < lowest_rating
            lowest_rating = r
        end
        save
    end
    
    def title
        retval = nil
        t = Title.find_by_sql [
            " \
                select titles.text \
                from titles \
                where \
                    title_level_id = ? \
                    and title_set_id = ?",
            level,
            title_set_id
        ]
        if not t.nil?
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
            rating
        ]
        if not t.nil?
            retval = t[ 0 ].id
        end
        return retval
    end
    
    def winning_too_much?
        count = Game.count( [ "warmup_winner = ? AND start_time > NOW() - '1 hour'::INTERVAL", id ] )
        return( count >= MAX_WINS_PER_HOUR )
    end
end

class Participation < ActiveRecord::Base
    belongs_to :game
end

class Channel < ActiveRecord::Base
end

class Title < ActiveRecord::Base
end

class TitleSet < ActiveRecord::Base
end

class TitleLevel < ActiveRecord::Base
end
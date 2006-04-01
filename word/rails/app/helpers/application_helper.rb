# Methods added to this helper will be available to all templates in the application.
module ApplicationHelper
    def datetime_format
        "%Y-%m-%d %H:%M:%S"
    end
    
    def time_diff( from_time, to_time = Time.now )
        if to_time.nil? or from_time.nil?
            nil
        else
            ( to_time - from_time ).seconds_to_interval_string
        end
    end
    
    def time_ago( from_time, to_time = Time.now )
        s = time_diff( from_time, to_time )
        if s.nil?
            s = "never"
        else
            s << " ago"
        end
        return s
    end
end

class Fixnum
    def seconds_to_interval_string
        seconds = self
        
        minutes = 0
        hours = 0
        days = 0
        
        if seconds > 59
            minutes = seconds / 60
            seconds = seconds % 60
            if minutes > 59
                hours = minutes / 60
                minutes = minutes % 60
                if hours > 23
                    days = hours / 24
                    hours = hours % 24
                end
            end
        end
    
        msg_array = Array.new
        if days > 0
            msg_array << "#{days} day#{days > 1 ? 's' : ''}"
        end
        if hours > 0
            msg_array << "#{hours} hour#{hours > 1 ? 's' : ''}"
        end
        if minutes > 0
            msg_array << "#{minutes} minute#{minutes > 1 ? 's' : ''}"
        end
        if seconds > 0
            msg_array << "#{seconds} second#{seconds > 1 ? 's' : ''}"
        end
        
        return msg_array.join( ", " )
    end
end

class Float
    def seconds_to_interval_string
        return self.to_i.seconds_to_interval_string
    end
end
